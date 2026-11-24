-- ============================================================
-- ICT371 - Q6: Monthly Payroll Processing
-- gross = basic + allowance, net = gross - deduction
-- Re-processing a month leaves existing rows UNCHANGED
-- ============================================================

DROP VIEW IF EXISTS v_payroll_report;
DROP TABLE IF EXISTS salary_audit;
DROP TABLE IF EXISTS payroll;
DROP TABLE IF EXISTS employees CASCADE;
DROP FUNCTION IF EXISTS fn_net_pay(INT);
DROP FUNCTION IF EXISTS pr_process_payroll(DATE);

-- ------------------------------------------------------------
-- (a) Tables 
-- ------------------------------------------------------------
CREATE TABLE employees (
    employee_id  SERIAL PRIMARY KEY,
    full_name    VARCHAR(100) NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance    NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (allowance >= 0),
    deduction    NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (deduction >= 0),
    active       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id  SERIAL PRIMARY KEY,
    employee_id INT NOT NULL REFERENCES employees(employee_id) ON DELETE RESTRICT,
    pay_month   DATE NOT NULL CHECK (pay_month = DATE_TRUNC('month', pay_month)::DATE),
    gross_pay   NUMERIC(12,2) NOT NULL CHECK (gross_pay >= 0),
    net_pay     NUMERIC(12,2) NOT NULL CHECK (net_pay >= 0),
    UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
    audit_id   SERIAL PRIMARY KEY,
    employee_id INT NOT NULL REFERENCES employees(employee_id),
    old_salary NUMERIC(12,2) NOT NULL,
    new_salary NUMERIC(12,2) NOT NULL,
    changed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ------------------------------------------------------------
-- (b) Function: fn_net_pay 
-- net = (basic + allowance) - deduction. Reject unknown / negative net.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INT)
RETURNS NUMERIC(12,2) AS $$
DECLARE
    v_basic NUMERIC(12,2);
    v_allow NUMERIC(12,2);
    v_deduct NUMERIC(12,2);
    v_net NUMERIC(12,2);
BEGIN
    IF p_employee_id IS NULL THEN
        RAISE EXCEPTION 'Employee ID cannot be NULL';
    END IF;

    SELECT basic_salary, allowance, deduction
    INTO v_basic, v_allow, v_deduct
    FROM employees WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee_id: %', p_employee_id;
    END IF;

    v_net := ROUND((v_basic + v_allow) - v_deduct, 2);

    IF v_net < 0 THEN
        RAISE EXCEPTION 'Negative net pay % for employee % (basic %, allowance %, deduction %)',
            v_net, p_employee_id, v_basic, v_allow, v_deduct;
    END IF;

    RETURN v_net;
END;
$$ LANGUAGE plpgsql STABLE;

-- Helper for gross (used by procedure, keeps logic in one place)
CREATE OR REPLACE FUNCTION fn_gross_pay(p_employee_id INT)
RETURNS NUMERIC(12,2) AS $$
DECLARE v_gross NUMERIC(12,2);
BEGIN
    SELECT basic_salary + allowance INTO v_gross
    FROM employees WHERE employee_id = p_employee_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown employee_id: %', p_employee_id; END IF;
    RETURN ROUND(v_gross, 2);
END;
$$ LANGUAGE plpgsql STABLE;

-- ------------------------------------------------------------
-- (c) Procedure: pr_process_payroll 
-- FOR loop over ACTIVE employees only.
-- Require month-start date. Insert missing only, leave existing unchanged.
-- Invalid employee calculation FAILS WHOLE CALL (exception = rollback).
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
AS $$
DECLARE
    r RECORD;
    v_gross NUMERIC(12,2);
    v_net NUMERIC(12,2);
BEGIN
    IF p_month IS NULL THEN
        RAISE EXCEPTION 'p_month cannot be NULL';
    END IF;
    IF p_month <> DATE_TRUNC('month', p_month)::DATE THEN
        RAISE EXCEPTION 'p_month must be first date of month, got %', p_month;
    END IF;

    FOR r IN SELECT employee_id FROM employees WHERE active = TRUE ORDER BY employee_id
    LOOP
        -- fn_net_pay raises if negative -> whole procedure rolls back, no partial payroll
        v_net := fn_net_pay(r.employee_id);
        v_gross := fn_gross_pay(r.employee_id);

        -- ON CONFLICT DO NOTHING = leave existing row unchanged on re-run
        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (r.employee_id, p_month, v_gross, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- ------------------------------------------------------------
-- (d) Trigger: AFTER UPDATE on employees 
-- Log ACTUAL basic_salary change only
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_employees_salary_audit()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.basic_salary IS DISTINCT FROM NEW.basic_salary THEN
        INSERT INTO salary_audit (employee_id, old_salary, new_salary, changed_at)
        VALUES (NEW.employee_id, OLD.basic_salary, NEW.basic_salary, NOW());
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_employees_salary_audit ON employees;
CREATE TRIGGER trg_employees_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW EXECUTE FUNCTION trg_employees_salary_audit();

-- ------------------------------------------------------------
-- (e) View: v_payroll_report 
-- Join names to pay_month, gross, net.
-- INCLUDES historical rows for employees who later become inactive.
-- (No WHERE active = TRUE filter - that would hide history)
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.employee_id, e.full_name, e.active AS currently_active,
       p.pay_month, p.gross_pay, p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;

-- ------------------------------------------------------------
-- (f) Index 
-- Report filtered by pay_month across all employees.
-- AVOID duplicating existing UQ (employee_id, pay_month)
-- ------------------------------------------------------------
-- Existing UQ is (employee_id, pay_month) - leading column is employee_id,
-- so it CANNOT efficiently answer "WHERE pay_month = ?" for all employees.
-- It would need a full scan / skip-scan.
-- New index leads with pay_month:
CREATE INDEX IF NOT EXISTS idx_payroll_pay_month
ON payroll (pay_month);

-- Covering version (even better, mention in README):
-- CREATE INDEX idx_payroll_pay_month_covering
-- ON payroll (pay_month, employee_id) INCLUDE (gross_pay, net_pay);

-- Matching query + EXPLAIN:
-- EXPLAIN ANALYZE
-- SELECT * FROM v_payroll_report WHERE pay_month = '2026-10-01';

-- Justification: pay_month first lets Postgres seek directly to that month's
-- rows for all employees. NOT a duplicate: order is reversed vs UQ index.

-- ------------------------------------------------------------
-- (g) Scheduled Job 
-- 02:00 on 1st of each month, for previous month's 1st date
-- ------------------------------------------------------------
-- Requires pg_cron:
-- CREATE EXTENSION IF NOT EXISTS pg_cron;

-- On 1st of month, CURRENT_DATE is e.g. 2026-12-01.
-- Previous month 1st = DATE_TRUNC('month', CURRENT_DATE - INTERVAL '1 month')
-- e.g. 2026-11-01. This expression is evaluated at run time, not fixed.
-- SELECT cron.schedule('q6-monthly-payroll', '0 2 1 * *',
--   $$ CALL pr_process_payroll(DATE_TRUNC('month', CURRENT_DATE - INTERVAL '1 month')::DATE); $$);

-- How to INSPECT job + run history (for marking screenshots):
-- -- List jobs:
-- -- SELECT jobid, jobname, schedule, command, active FROM cron.job;
-- -- Run history:
-- -- SELECT jobid, runid, job_pid, status, return_message, start_time, end_time
-- -- FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;
-- -- Unschedule if needed:
-- -- SELECT cron.unschedule('q6-monthly-payroll');

-- ------------------------------------------------------------
-- Seed Data: active + inactive employees, 2+ payroll months
-- ------------------------------------------------------------
INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
('Chanda Mwila', 8000.00, 1500.00, 500.00, TRUE),   -- gross 9500, net 9000
('Grace Phiri',  6500.00, 1000.00, 300.00, TRUE),   -- gross 7500, net 7200
('Kelvin Banda', 5000.00, 800.00, 200.00, TRUE),    -- gross 5800, net 5600
('Mutinta Zulu', 9000.00, 2000.00, 1000.00, FALSE); -- inactive, should NOT get new payroll

-- Process two months via procedure
CALL pr_process_payroll('2026-10-01');
CALL pr_process_payroll('2026-11-01');

-- Re-run must NOT change / duplicate:
-- CALL pr_process_payroll('2026-10-01');

-- Example: employee later becomes inactive, but history stays in view
-- UPDATE employees SET active = FALSE WHERE employee_id = 3;

-- Example: salary change triggers audit
-- UPDATE employees SET basic_salary = 8500.00 WHERE employee_id = 1; -- logs audit
-- UPDATE employees SET allowance = 1600.00 WHERE employee_id = 1; -- NO audit (salary unchanged)

-- ------------------------------------------------------------
-- Verification
-- ------------------------------------------------------------
-- SELECT fn_net_pay(1); -- 9000.00
-- SELECT * FROM payroll ORDER BY pay_month, employee_id;
-- SELECT * FROM v_payroll_report ORDER BY pay_month, employee_id;
-- SELECT * FROM salary_audit;
-- -- Must fail - not month-start:
-- -- CALL pr_process_payroll('2026-11-15');
-- -- Must fail - unknown:
-- -- SELECT fn_net_pay(999);
