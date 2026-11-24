-- ============================================================
-- ICT371 - Q7: Water Meter Readings and Billing
-- Tariff: first 10 units @ K5, units above 10 @ K8. Zero = 0.
-- ============================================================

DROP VIEW IF EXISTS v_overdue_bills;
DROP TABLE IF EXISTS receivable_snapshot;
DROP TABLE IF EXISTS bills;
DROP TABLE IF EXISTS readings;
DROP TABLE IF EXISTS customers CASCADE;
DROP FUNCTION IF EXISTS fn_water_charge(NUMERIC);
DROP FUNCTION IF EXISTS pr_generate_bill(INT, DATE);
DROP FUNCTION IF EXISTS pr_refresh_receivables();

-- ------------------------------------------------------------
-- (a) Tables
-- ------------------------------------------------------------
CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
);

CREATE TABLE readings (
    reading_id       SERIAL PRIMARY KEY,
    customer_id      INT NOT NULL REFERENCES customers(customer_id) ON DELETE RESTRICT,
    reading_month    DATE NOT NULL CHECK (reading_month = DATE_TRUNC('month', reading_month)::DATE),
    previous_reading NUMERIC(10,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading  NUMERIC(10,2) NOT NULL CHECK (current_reading >= 0),
    UNIQUE (customer_id, reading_month)
);

CREATE TABLE bills (
    bill_id     SERIAL PRIMARY KEY,
    reading_id  INT NOT NULL UNIQUE REFERENCES readings(reading_id) ON DELETE RESTRICT,
    charge      NUMERIC(10,2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (amount_paid >= 0),
    due_on      DATE NOT NULL,
    CHECK (amount_paid <= charge)
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due     NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (total_due >= 0)
);

-- ------------------------------------------------------------
-- (b) Function: fn_water_charge 
-- First 10 @5, rest @8. Exact 2 decimals. Reject NULL / negative.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(10,2) AS $$
DECLARE
    v_charge NUMERIC(10,2);
BEGIN
    IF p_units IS NULL THEN
        RAISE EXCEPTION 'Units cannot be NULL';
    END IF;
    IF p_units < 0 THEN
        RAISE EXCEPTION 'Consumption cannot be negative, got %', p_units;
    END IF;

    IF p_units <= 10 THEN
        v_charge := p_units * 5.00;
    ELSE
        v_charge := (10 * 5.00) + ((p_units - 10) * 8.00);
    END IF;

    RETURN ROUND(v_charge, 2);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- ------------------------------------------------------------
-- (c) Procedure: pr_generate_bill 
-- Derive consumption, call function, insert bill with amount_paid 0
-- Reject unknown reading / reading that already has a bill
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INT, p_due_on DATE)
AS $$
DECLARE
    v_units  NUMERIC(10,2);
    v_charge NUMERIC(10,2);
BEGIN
    IF p_reading_id IS NULL OR p_due_on IS NULL THEN
        RAISE EXCEPTION 'Reading ID and due_on cannot be NULL';
    END IF;

    SELECT (current_reading - previous_reading) INTO v_units
    FROM readings WHERE reading_id = p_reading_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading_id: %', p_reading_id;
    END IF;

    -- Trigger on readings guarantees current >= previous, so v_units >= 0
    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
    END IF;

    v_charge := fn_water_charge(v_units);

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, v_charge, 0, p_due_on);
END;
$$ LANGUAGE plpgsql;

-- ------------------------------------------------------------
-- (d) Trigger: BEFORE INSERT OR UPDATE on readings 
-- Reject current_reading < previous_reading, incl. direct SQL.
-- Rejected row is NOT stored (exception rolls back).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_readings_validate()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'current_reading % cannot be below previous_reading % for customer %',
            NEW.current_reading, NEW.previous_reading, NEW.customer_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_readings_validate ON readings;
CREATE TRIGGER trg_readings_validate
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW EXECUTE FUNCTION trg_readings_validate();

-- ------------------------------------------------------------
-- (e) View: v_overdue_bills 
-- due_on < CURRENT_DATE AND not fully paid
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name AS customer_name, b.due_on,
       (b.charge - b.amount_paid) AS outstanding_amount,
       b.bill_id, b.charge, b.amount_paid
FROM bills b
JOIN readings r ON r.reading_id = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;

-- ------------------------------------------------------------
-- (f) Index 
-- Date-based searches for overdue bills
-- ------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_bills_due_on_unpaid
ON bills (due_on)
WHERE amount_paid < charge;

-- Alternative composite: ON bills (due_on, amount_paid)
-- Partial index is smaller - only stores unpaid bills, exactly what overdue queries need.

-- Matching unpaid-bill query + EXPLAIN:
-- EXPLAIN ANALYZE
-- SELECT * FROM bills
-- WHERE due_on < CURRENT_DATE AND amount_paid < charge;

-- Justification: due_on first for date range / < CURRENT_DATE filter,
-- partial condition amount_paid < charge skips fully paid bills entirely.

-- ------------------------------------------------------------
-- (g) Scheduled Job: pr_refresh_receivables
-- Store TODAY's total unpaid balances. Replace same date on rerun.
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
AS $$
BEGIN
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT CURRENT_DATE,
           COALESCE(SUM(charge - amount_paid), 0)
    FROM bills WHERE amount_paid < charge
    ON CONFLICT (snapshot_date) DO UPDATE
    SET total_due = EXCLUDED.total_due;
END;
$$ LANGUAGE plpgsql;

-- Schedule daily at 00:30 (requires pg_cron)
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- SELECT cron.schedule('q7-refresh-receivables', '30 0 * * *',
--   $$ CALL pr_refresh_receivables(); $$);

-- ------------------------------------------------------------
-- Seed Data: 3 customers, 6 readings
-- Covering zero, exactly 10, above 10 units
-- ------------------------------------------------------------
INSERT INTO customers (full_name) VALUES
('Chanda Mwila'), ('Grace Phiri'), ('Kelvin Banda');

-- Trigger is already installed, so invalid readings would fail here too
INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
(1, '2026-10-01', 100.00, 100.00), -- 0 units -> K0
(1, '2026-11-01', 100.00, 110.00), -- 10 units -> K50 (10*5)
(2, '2026-10-01', 50.00, 65.00),  -- 15 units -> 50 + 5*8 = K90
(2, '2026-11-01', 65.00, 70.00),  -- 5 units -> K25
(3, '2026-10-01', 200.00, 212.00), -- 12 units -> 50 + 2*8 = K66
(3, '2026-11-01', 212.00, 212.00); -- 0 units -> K0

-- Generate bills via procedure (one per reading)
-- Use past due dates for some to show overdue view
CALL pr_generate_bill(1, '2026-11-10'); -- 0.00, fully? amount_paid 0 = charge, so NOT overdue
CALL pr_generate_bill(2, '2026-12-10'); -- 50.00, not yet due if today < Dec 10
CALL pr_generate_bill(3, '2026-11-05'); -- 90.00, overdue if today > Nov 5
CALL pr_generate_bill(4, '2026-11-20'); -- 25.00
CALL pr_generate_bill(5, '2026-11-15'); -- 66.00
CALL pr_generate_bill(6, '2026-12-01'); -- 0.00

-- Example partial payment (to show outstanding = charge - paid)
-- UPDATE bills SET amount_paid = 30.00 WHERE bill_id = 3;

-- ------------------------------------------------------------
-- Verification
-- ------------------------------------------------------------
-- SELECT fn_water_charge(0);  -- 0.00
-- SELECT fn_water_charge(10); -- 50.00
-- SELECT fn_water_charge(15); -- 90.00
-- SELECT * FROM readings;
-- SELECT * FROM bills;
-- SELECT * FROM v_overdue_bills;
-- CALL pr_refresh_receivables();
-- SELECT * FROM receivable_snapshot;
-- -- Must fail - current < previous (trigger, direct SQL):
-- -- INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
-- -- VALUES (1, '2026-12-01', 110.00, 100.00);
-- -- Must fail - duplicate bill:
-- -- CALL pr_generate_bill(1, '2026-12-10');
-- -- Must fail - unknown reading:
-- -- CALL pr_generate_bill(999, '2026-12-10');
