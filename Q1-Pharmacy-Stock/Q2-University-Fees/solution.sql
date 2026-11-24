-- ============================================================
-- ICT371 - Q2: University Fee Payments
-- PostgreSQL - Credit balances NOT allowed
-- ============================================================

DROP VIEW IF EXISTS v_fee_balances;
DROP TABLE IF EXISTS daily_collections;
DROP TABLE IF EXISTS payment_audit;
DROP TABLE IF EXISTS payments;
DROP TABLE IF EXISTS students CASCADE;
DROP FUNCTION IF EXISTS fn_fee_balance(INT);
DROP FUNCTION IF EXISTS pr_receive_payment(INT, NUMERIC, DATE);
DROP FUNCTION IF EXISTS pr_refresh_collections(DATE);

-- ------------------------------------------------------------
-- (a) Tables
-- ------------------------------------------------------------
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL,
    fee_due        NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INT NOT NULL REFERENCES students(student_id) ON DELETE RESTRICT,
    amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on    DATE NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE payment_audit (
    audit_id   SERIAL PRIMARY KEY,
    payment_id INT NOT NULL REFERENCES payments(payment_id),
    student_id INT NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL,
    logged_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count   INT NOT NULL DEFAULT 0 CHECK (payment_count >= 0),
    total_amount    NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (total_amount >= 0)
);

-- ------------------------------------------------------------
-- (b) Function: fn_fee_balance
-- fee_due - total payments. Full fee if no payments. Reject unknown student.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INT)
RETURNS NUMERIC(12,2) AS $$
DECLARE
    v_fee_due NUMERIC(12,2);
    v_paid    NUMERIC(12,2);
BEGIN
    IF p_student_id IS NULL THEN
        RAISE EXCEPTION 'Student ID cannot be NULL';
    END IF;

    SELECT fee_due INTO v_fee_due FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    SELECT COALESCE(SUM(amount), 0) INTO v_paid FROM payments WHERE student_id = p_student_id;

    RETURN ROUND(v_fee_due - v_paid, 2);
END;
$$ LANGUAGE plpgsql STABLE;

-- ------------------------------------------------------------
-- (c) Procedure: pr_receive_payment
-- Reject NULL/zero/negative and amount > outstanding balance.
-- Insert valid payment WITHOUT changing fee_due.
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_receive_payment(p_student_id INT, p_amount NUMERIC, p_paid_on DATE)
AS $$
DECLARE
    v_balance NUMERIC(12,2);
BEGIN
    IF p_student_id IS NULL OR p_amount IS NULL OR p_paid_on IS NULL THEN
        RAISE EXCEPTION 'Student, amount and paid_on cannot be NULL';
    END IF;
    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'Amount must be positive, got %', p_amount;
    END IF;

    -- Lock student row to prevent concurrent overpayment
    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    v_balance := fn_fee_balance(p_student_id);

    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment % exceeds outstanding balance % for student %',
            p_amount, v_balance, p_student_id;
    END IF;

    -- Trigger will write audit row, procedure must NOT do it
    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, p_paid_on);
END;
$$ LANGUAGE plpgsql;

-- ------------------------------------------------------------
-- (d) Trigger: AFTER INSERT on payments -> payment_audit
-- Procedure must NOT insert audit itself
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_payments_audit()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, NOW());
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_payments_audit ON payments;
CREATE TRIGGER trg_payments_audit
AFTER INSERT ON payments
FOR EACH ROW EXECUTE FUNCTION trg_payments_audit();

-- ------------------------------------------------------------
-- (e) View: v_fee_balances
-- Only students who still owe. Fully settled excluded.
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number, s.full_name, fn_fee_balance(s.student_id) AS outstanding_balance
FROM students s
WHERE fn_fee_balance(s.student_id) > 0;

-- ------------------------------------------------------------
-- (f) Index
-- For payments filtered by student_id and paid_on date range
-- ------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_payments_student_paid_on
ON payments (student_id, paid_on);

-- Matching query + EXPLAIN:
-- EXPLAIN ANALYZE
-- SELECT * FROM payments
-- WHERE student_id = 1 AND paid_on BETWEEN '2026-01-01' AND '2026-01-31';

-- Justification (for README):
-- Composite B-tree (student_id, paid_on). student_id first for equality,
-- paid_on second for range scan. Avoids full scan of payments table.

-- ------------------------------------------------------------
-- (g) Scheduled Job: pr_refresh_collections
-- Store count + total for that date. Replace on rerun.
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day cannot be NULL';
    END IF;

    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    SELECT p_day,
           COUNT(*),
           COALESCE(SUM(amount), 0)
    FROM payments WHERE paid_on = p_day
    ON CONFLICT (collection_date) DO UPDATE
    SET payment_count = EXCLUDED.payment_count,
        total_amount = EXCLUDED.total_amount;
END;
$$ LANGUAGE plpgsql;

-- Schedule daily at 01:00 for previous day (requires pg_cron)
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- SELECT cron.schedule('q2-refresh-collections', '0 1 * * *',
--   $$ CALL pr_refresh_collections(CURRENT_DATE - 1); $$);

-- ------------------------------------------------------------
-- Seed Data: 3 students, 6+ payments, 1 student initially with no payments
-- ------------------------------------------------------------
INSERT INTO students (student_number, full_name, fee_due) VALUES
('2026-001', 'Chanda Mwila', 5000.00),
('2026-002', 'Grace Phiri', 3500.00),
('2026-003', 'Kelvin Banda', 4200.00)
ON CONFLICT (student_number) DO NOTHING;

-- Chanda: 2 payments, still owes 5000 - 3000 = 2000
CALL pr_receive_payment(1, 2000.00, '2026-11-20');
CALL pr_receive_payment(1, 1000.00, '2026-11-21');
-- Grace: 2 payments, still owes 3500 - 1500 = 2000
CALL pr_receive_payment(2, 1000.00, '2026-11-20');
CALL pr_receive_payment(2, 500.00, '2026-11-21');
-- Kelvin: initially no payments, then 2 payments added to prove fn works
-- For marking: comment out below 2 lines if you want to show "no payments" state first
CALL pr_receive_payment(3, 1200.00, '2026-11-20');
CALL pr_receive_payment(3, 800.00, '2026-11-21');

-- ------------------------------------------------------------
-- Verification
-- ------------------------------------------------------------
-- SELECT * FROM students;
-- SELECT * FROM payments ORDER BY payment_id;
-- SELECT * FROM payment_audit ORDER BY audit_id; -- auto-created by trigger
-- SELECT fn_fee_balance(1); -- 2000.00
-- SELECT fn_fee_balance(3); -- 2200.00
-- SELECT * FROM v_fee_balances;
-- CALL pr_refresh_collections('2026-11-20');
-- SELECT * FROM daily_collections;
-- -- Must fail - overpayment / credit balance not allowed:
-- -- CALL pr_receive_payment(1, 99999, '2026-11-22');
-- -- Must fail - zero / negative:
-- -- CALL pr_receive_payment(1, 0, '2026-11-22');
-- -- Must fail - unknown student:
-- -- SELECT fn_fee_balance(999);
