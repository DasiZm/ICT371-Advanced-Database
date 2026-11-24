-- ============================================================
-- Q6. MONTHLY PAYROLL PROCESSING
-- ============================================================
DROP SCHEMA IF EXISTS ict371_q06 CASCADE;
CREATE SCHEMA ict371_q06;
SET search_path TO ict371_q06, public;

CREATE TABLE employees(
 employee_id SERIAL PRIMARY KEY,full_name VARCHAR(100) NOT NULL,
 basic_salary NUMERIC(12,2) NOT NULL CHECK(basic_salary>=0),
 allowance NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK(allowance>=0),
 deduction NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK(deduction>=0),
 active BOOLEAN NOT NULL DEFAULT TRUE
);
CREATE TABLE payroll(
 payroll_id SERIAL PRIMARY KEY,employee_id INT NOT NULL REFERENCES employees(employee_id),
 pay_month DATE NOT NULL CHECK(EXTRACT(DAY FROM pay_month)=1),
 gross_pay NUMERIC(12,2) NOT NULL CHECK(gross_pay>=0),
 net_pay NUMERIC(12,2) NOT NULL CHECK(net_pay>=0),
 UNIQUE(employee_id,pay_month)
);
CREATE TABLE salary_audit(
 audit_id SERIAL PRIMARY KEY,employee_id INT NOT NULL REFERENCES employees(employee_id),
 old_salary NUMERIC(12,2) NOT NULL,new_salary NUMERIC(12,2) NOT NULL,
 changed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE OR REPLACE FUNCTION fn_gross_pay(p_employee_id INT)
RETURNS NUMERIC(12,2) LANGUAGE plpgsql STABLE AS $$
DECLARE v_basic NUMERIC(12,2);v_allow NUMERIC(12,2);
BEGIN
 SELECT basic_salary,allowance INTO v_basic,v_allow FROM employees WHERE employee_id=p_employee_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown employee ID: %',p_employee_id; END IF;
 RETURN v_basic+v_allow;
END;
$$;
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INT)
RETURNS NUMERIC(12,2) LANGUAGE plpgsql STABLE AS $$
DECLARE v_gross NUMERIC(12,2);v_deduction NUMERIC(12,2);
BEGIN
 SELECT basic_salary+allowance,deduction INTO v_gross,v_deduction
 FROM employees WHERE employee_id=p_employee_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown employee ID: %',p_employee_id; END IF;
 IF v_gross-v_deduction<0 THEN RAISE EXCEPTION 'Net pay cannot be negative for employee %',p_employee_id; END IF;
 RETURN v_gross-v_deduction;
END;
$$;

CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql AS $$
DECLARE r RECORD;v_gross NUMERIC(12,2);v_net NUMERIC(12,2);
BEGIN
 IF p_month IS NULL OR EXTRACT(DAY FROM p_month)<>1 THEN RAISE EXCEPTION 'Pay month must be the first day of a month'; END IF;
 FOR r IN SELECT employee_id FROM employees WHERE active ORDER BY employee_id LOOP
   v_gross:=fn_gross_pay(r.employee_id);
   v_net:=fn_net_pay(r.employee_id);
   INSERT INTO payroll(employee_id,pay_month,gross_pay,net_pay)
   VALUES(r.employee_id,p_month,v_gross,v_net)
   ON CONFLICT(employee_id,pay_month) DO NOTHING;
 END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION trg_employees_salary_audit()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
 IF OLD.basic_salary IS DISTINCT FROM NEW.basic_salary THEN
   INSERT INTO salary_audit(employee_id,old_salary,new_salary)
   VALUES(NEW.employee_id,OLD.basic_salary,NEW.basic_salary);
 END IF;
 RETURN NEW;
END;
$$;
CREATE TRIGGER employees_salary_audit AFTER UPDATE OF basic_salary ON employees
FOR EACH ROW EXECUTE FUNCTION trg_employees_salary_audit();

CREATE OR REPLACE VIEW v_payroll_report AS
SELECT p.payroll_id,e.employee_id,e.full_name,p.pay_month,p.gross_pay,p.net_pay,e.active
FROM payroll p JOIN employees e ON e.employee_id=p.employee_id;

CREATE INDEX idx_payroll_month ON payroll(pay_month);

INSERT INTO employees(full_name,basic_salary,allowance,deduction,active) VALUES
('Chanda',8000,1500,500,TRUE),('Grace',6000,1500,300,TRUE),
('Kelvin',5000,800,200,TRUE),('Mutinta',9000,2000,1000,FALSE);
CALL pr_process_payroll(DATE '2026-10-01');
CALL pr_process_payroll(DATE '2026-11-01');
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM payroll WHERE pay_month=DATE '2026-11-01';
