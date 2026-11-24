-- ============================================================
-- ICT371 - Q2: University Fee Payments
-- PostgreSQL - Credit balances NOT allowed
-- ============================================================

DROP SCHEMA IF EXISTS ict371_q02 CASCADE;
CREATE SCHEMA ict371_q02;
SET search_path TO ict371_q02, public;

CREATE TABLE students (
    student_id SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name VARCHAR(100) NOT NULL,
    fee_due NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);
CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INT NOT NULL REFERENCES students(student_id),
    amount NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on DATE NOT NULL
);
CREATE TABLE payment_audit (
    audit_id SERIAL PRIMARY KEY,
    payment_id INT NOT NULL REFERENCES payments(payment_id),
    student_id INT NOT NULL REFERENCES students(student_id),
    amount NUMERIC(12,2) NOT NULL,
    recorded_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count BIGINT NOT NULL CHECK(payment_count>=0),
    total_amount NUMERIC(14,2) NOT NULL CHECK(total_amount>=0)
);

CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INT)
RETURNS NUMERIC(12,2) LANGUAGE plpgsql STABLE AS $$
DECLARE v_due NUMERIC(12,2); v_paid NUMERIC(12,2);
BEGIN
    IF p_student_id IS NULL THEN RAISE EXCEPTION 'Student ID cannot be NULL'; END IF;
    SELECT fee_due INTO v_due FROM students WHERE student_id=p_student_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown student ID: %',p_student_id; END IF;
    SELECT COALESCE(SUM(amount),0) INTO v_paid FROM payments WHERE student_id=p_student_id;
    RETURN v_due-v_paid;
END;
$$;

CREATE OR REPLACE PROCEDURE pr_receive_payment(p_student_id INT,p_amount NUMERIC,p_paid_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_balance NUMERIC(12,2);
BEGIN
    IF p_student_id IS NULL OR p_amount IS NULL OR p_paid_on IS NULL OR p_amount<=0 THEN
        RAISE EXCEPTION 'Student, positive payment amount and payment date are required';
    END IF;
    PERFORM 1 FROM students WHERE student_id=p_student_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown student ID: %',p_student_id; END IF;
    v_balance:=fn_fee_balance(p_student_id);
    IF p_amount>v_balance THEN
        RAISE EXCEPTION 'Payment % exceeds outstanding balance %',p_amount,v_balance;
    END IF;
    INSERT INTO payments(student_id,amount,paid_on) VALUES(p_student_id,p_amount,p_paid_on);
END;
$$;

CREATE OR REPLACE FUNCTION trg_payment_audit()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO payment_audit(payment_id,student_id,amount)
    VALUES(NEW.payment_id,NEW.student_id,NEW.amount);
    RETURN NEW;
END;
$$;
CREATE TRIGGER payments_audit AFTER INSERT ON payments
FOR EACH ROW EXECUTE FUNCTION trg_payment_audit();

CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number,s.full_name,s.fee_due,
       s.fee_due-COALESCE(SUM(p.amount),0) AS balance
FROM students s LEFT JOIN payments p ON p.student_id=s.student_id
GROUP BY s.student_id,s.student_number,s.full_name,s.fee_due
HAVING s.fee_due-COALESCE(SUM(p.amount),0)>0;

CREATE INDEX idx_payments_student_date ON payments(student_id,paid_on);

CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_day IS NULL THEN RAISE EXCEPTION 'Date cannot be NULL'; END IF;
    INSERT INTO daily_collections(collection_date,payment_count,total_amount)
    SELECT p_day,COUNT(*),COALESCE(SUM(amount),0)
    FROM payments WHERE paid_on=p_day
    ON CONFLICT(collection_date) DO UPDATE
    SET payment_count=EXCLUDED.payment_count,total_amount=EXCLUDED.total_amount;
END;
$$;

INSERT INTO students(student_number,full_name,fee_due) VALUES
('STU-001','Chanda Mwila',5000),('STU-002','Grace Phiri',3500),('STU-003','Kelvin Banda',4200);
CALL pr_receive_payment((SELECT student_id FROM students WHERE student_number='STU-001'),1000,'2026-11-20');
CALL pr_receive_payment((SELECT student_id FROM students WHERE student_number='STU-001'),1000,'2026-11-21');
CALL pr_receive_payment((SELECT student_id FROM students WHERE student_number='STU-001'),1000,'2026-11-22');
CALL pr_receive_payment((SELECT student_id FROM students WHERE student_number='STU-002'),500,'2026-11-20');
CALL pr_receive_payment((SELECT student_id FROM students WHERE student_number='STU-002'),500,'2026-11-21');
CALL pr_receive_payment((SELECT student_id FROM students WHERE student_number='STU-002'),500,'2026-11-22');
CALL pr_refresh_collections('2026-11-20');
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM payments WHERE student_id=1
AND paid_on BETWEEN DATE '2026-11-01' AND DATE '2026-11-30';
