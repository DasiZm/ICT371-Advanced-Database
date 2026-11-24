-- ============================================================
-- ICT371 - Q9: Farmer Cooperative Maize Deliveries
-- Prices: A = K5/kg, B = K4/kg, C = K3/kg
-- Values calculated consistently, even for direct SQL inserts
-- ============================================================

DROP VIEW IF EXISTS v_farmer_amount_due;
DROP TABLE IF EXISTS daily_purchases;
DROP TABLE IF EXISTS deliveries;
DROP TABLE IF EXISTS farmers CASCADE;
DROP FUNCTION IF EXISTS fn_maize_rate(TEXT);
DROP FUNCTION IF EXISTS pr_receive_delivery(INT, TEXT, NUMERIC, DATE);
DROP FUNCTION IF EXISTS pr_refresh_purchases(DATE);

-- ------------------------------------------------------------
-- (a) Tables
-- Numeric weight + money fields
-- ------------------------------------------------------------
CREATE TABLE farmers (
    farmer_id     SERIAL PRIMARY KEY,
    farmer_number VARCHAR(20) NOT NULL UNIQUE,
    full_name     VARCHAR(100) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id   SERIAL PRIMARY KEY,
    farmer_id     INT NOT NULL REFERENCES farmers(farmer_id) ON DELETE RESTRICT,
    grade         VARCHAR(5) NOT NULL CHECK (grade IN ('A','B','C')),
    weight_kg     NUMERIC(10,2) NOT NULL CHECK (weight_kg > 0),
    unit_rate     NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (unit_rate >= 0),
    total_value   NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (total_value >= 0),
    delivered_on  DATE NOT NULL,
    is_paid       BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight  NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (total_weight >= 0),
    total_value   NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (total_value >= 0)
);

-- ------------------------------------------------------------
-- (b) Function: fn_maize_rate
-- A=5, B=4, C=3. Reject NULL / unsupported grade.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade TEXT)
RETURNS NUMERIC(10,2) AS $$
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade cannot be NULL';
    END IF;

    RETURN CASE UPPER(TRIM(p_grade))
        WHEN 'A' THEN 5.00
        WHEN 'B' THEN 4.00
        WHEN 'C' THEN 3.00
        ELSE NULL
    END;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Need explicit check for unsupported - CASE returns NULL, catch it:
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade TEXT)
RETURNS NUMERIC(10,2) AS $$
DECLARE v_rate NUMERIC(10,2);
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade cannot be NULL';
    END IF;

    v_rate := CASE UPPER(TRIM(p_grade))
        WHEN 'A' THEN 5.00
        WHEN 'B' THEN 4.00
        WHEN 'C' THEN 3.00
        ELSE NULL
    END;

    IF v_rate IS NULL THEN
        RAISE EXCEPTION 'Unsupported grade: % (allowed: A, B, C)', p_grade;
    END IF;

    RETURN v_rate;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- ------------------------------------------------------------
-- (c) Procedure: pr_receive_delivery
-- Reject unknown farmer / invalid inputs. Insert basic fields, is_paid FALSE.
-- Trigger supplies unit_rate + total_value.
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_receive_delivery(p_farmer_id INT, p_grade TEXT, p_weight NUMERIC, p_date DATE)
AS $$
BEGIN
    IF p_farmer_id IS NULL OR p_grade IS NULL OR p_weight IS NULL OR p_date IS NULL THEN
        RAISE EXCEPTION 'Farmer, grade, weight and date cannot be NULL';
    END IF;

    PERFORM 1 FROM farmers WHERE farmer_id = p_farmer_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown farmer_id: %', p_farmer_id;
    END IF;

    -- Validate grade + weight early - trigger will also enforce
    PERFORM fn_maize_rate(p_grade);
    IF p_weight <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive, got %', p_weight;
    END IF;

    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, UPPER(TRIM(p_grade)), p_weight, p_date, FALSE);
    -- unit_rate / total_value filled by trigger
END;
$$ LANGUAGE plpgsql;

-- ------------------------------------------------------------
-- (d) Trigger: BEFORE INSERT OR UPDATE
-- Reject non-positive weight, call fn_maize_rate, set NEW.unit_rate + NEW.total_value
-- Direct SQL follows same rule - cannot bypass
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_deliveries_pricing()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive, got %', NEW.weight_kg;
    END IF;

    NEW.unit_rate := fn_maize_rate(NEW.grade);
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_deliveries_pricing ON deliveries;
CREATE TRIGGER trg_deliveries_pricing
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW EXECUTE FUNCTION trg_deliveries_pricing();

-- ------------------------------------------------------------
-- (e) View: v_farmer_amount_due
-- Every farmer, even with no unpaid deliveries -> 0
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number, f.full_name,
       COALESCE(SUM(d.total_value), 0) AS amount_due
FROM farmers f
LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id AND d.is_paid = FALSE
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

-- ------------------------------------------------------------
-- (f) Index
-- Farmer's deliveries between two dates
-- ------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_deliveries_farmer_date
ON deliveries (farmer_id, delivered_on);

-- Matching query + EXPLAIN:
-- EXPLAIN ANALYZE
-- SELECT * FROM deliveries
-- WHERE farmer_id = 1 AND delivered_on BETWEEN '2026-11-01' AND '2026-11-30';

-- Justification: farmer_id first for equality, delivered_on second for range.
-- Lets Postgres seek to that farmer then scan only dates in range.

-- ------------------------------------------------------------
-- (g) Scheduled Job: pr_refresh_purchases
-- Store that date's purchased weight + value. Replace on rerun.
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day cannot be NULL';
    END IF;

    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    SELECT p_day,
           COALESCE(SUM(weight_kg), 0),
           COALESCE(SUM(total_value), 0)
    FROM deliveries WHERE delivered_on = p_day
    ON CONFLICT (purchase_date) DO UPDATE
    SET total_weight = EXCLUDED.total_weight,
        total_value = EXCLUDED.total_value;
END;
$$ LANGUAGE plpgsql;

-- Schedule daily at 01:30 for previous day (requires pg_cron)
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- SELECT cron.schedule('q9-refresh-purchases', '30 1 * * *',
--   $$ CALL pr_refresh_purchases(CURRENT_DATE - 1); $$);

-- ------------------------------------------------------------
-- Seed Data: 3 farmers, 6 deliveries - all grades + both payment states
-- Load AFTER trigger installed, so pricing is automatic
-- ------------------------------------------------------------
INSERT INTO farmers (farmer_number, full_name) VALUES
('F-001', 'Chanda Mwila'),
('F-002', 'Grace Phiri'),
('F-003', 'Kelvin Banda');

-- Via procedure (is_paid defaults FALSE, trigger sets rate/value)
CALL pr_receive_delivery(1, 'A', 100.00, '2026-11-20'); -- 100*5 = 500
CALL pr_receive_delivery(1, 'B', 50.00, '2026-11-20');  -- 50*4 = 200
CALL pr_receive_delivery(2, 'C', 80.00, '2026-11-20');  -- 80*3 = 240
CALL pr_receive_delivery(2, 'A', 20.00, '2026-11-21');  -- 20*5 = 100
CALL pr_receive_delivery(3, 'B', 60.00, '2026-11-21');  -- 60*4 = 240
CALL pr_receive_delivery(3, 'C', 40.00, '2026-11-22');  -- 40*3 = 120

-- Mix payment states: mark some as paid
UPDATE deliveries SET is_paid = TRUE WHERE delivery_id IN (1, 4);

-- Direct SQL must also follow same pricing rule (trigger test):
-- INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
-- VALUES (1, 'A', 10.00, '2026-11-22', FALSE); -- trigger sets 5.00 / 50.00 even though not supplied

-- ------------------------------------------------------------
-- Verification
-- ------------------------------------------------------------
-- SELECT fn_maize_rate('A'); -- 5.00
-- SELECT fn_maize_rate('B'); -- 4.00
-- SELECT fn_maize_rate('C'); -- 3.00
-- SELECT * FROM deliveries ORDER BY delivery_id;
-- SELECT * FROM v_farmer_amount_due;
-- -- F-001: unpaid = 200 (delivery 2), F-002: unpaid = 240, F-003: unpaid = 360
-- CALL pr_refresh_purchases('2026-11-20');
-- SELECT * FROM daily_purchases; -- 2026-11-20: weight 230, value 940
-- CALL pr_refresh_purchases('2026-11-20'); -- rerun must REPLACE, not double
-- -- Must fail:
-- -- SELECT fn_maize_rate('D');
-- -- CALL pr_receive_delivery(999, 'A', 10, '2026-11-22');
-- -- CALL pr_receive_delivery(1, 'A', -5, '2026-11-22');
-- -- INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on) VALUES (1, 'A', 0, '2026-11-22');
