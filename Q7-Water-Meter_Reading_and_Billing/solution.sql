-- ============================================================
-- Q7. WATER METER READINGS AND BILLING
-- ============================================================
DROP SCHEMA IF EXISTS ict371_q07 CASCADE;
CREATE SCHEMA ict371_q07;
SET search_path TO ict371_q07, public;

CREATE TABLE customers(customer_id SERIAL PRIMARY KEY,customer_number VARCHAR(20) UNIQUE NOT NULL,full_name VARCHAR(100) NOT NULL);
CREATE TABLE readings(
 reading_id SERIAL PRIMARY KEY,customer_id INT NOT NULL REFERENCES customers(customer_id),
 reading_month DATE NOT NULL CHECK(EXTRACT(DAY FROM reading_month)=1),
 previous_reading NUMERIC(12,2) NOT NULL CHECK(previous_reading>=0),
 current_reading NUMERIC(12,2) NOT NULL CHECK(current_reading>=0),
 UNIQUE(customer_id,reading_month),
 CHECK(current_reading>=previous_reading)
);
CREATE TABLE bills(
 bill_id SERIAL PRIMARY KEY,reading_id INT NOT NULL UNIQUE REFERENCES readings(reading_id),
 due_on DATE NOT NULL,charge NUMERIC(12,2) NOT NULL CHECK(charge>=0),
 amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK(amount_paid>=0 AND amount_paid<=charge)
);
CREATE TABLE receivable_snapshot(
 snapshot_date DATE PRIMARY KEY,total_outstanding NUMERIC(14,2) NOT NULL CHECK(total_outstanding>=0)
);

CREATE OR REPLACE FUNCTION fn_water_charge(p_consumption NUMERIC)
RETURNS NUMERIC(12,2) LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
 IF p_consumption IS NULL OR p_consumption<0 THEN RAISE EXCEPTION 'Consumption must be non-negative'; END IF;
 RETURN ROUND(LEAST(p_consumption,10)*5+GREATEST(p_consumption-10,0)*8,2);
END;
$$;

CREATE OR REPLACE FUNCTION trg_readings_validate()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.previous_reading IS NULL OR NEW.current_reading IS NULL
    OR NEW.previous_reading<0 OR NEW.current_reading<NEW.previous_reading THEN
   RAISE EXCEPTION 'Current meter reading must be at least the previous reading';
 END IF;
 RETURN NEW;
END;
$$;
CREATE TRIGGER readings_validate BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW EXECUTE FUNCTION trg_readings_validate();

CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INT,p_due_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_previous NUMERIC(12,2);v_current NUMERIC(12,2);
BEGIN
 IF p_reading_id IS NULL OR p_due_on IS NULL THEN RAISE EXCEPTION 'Reading ID and due date are required'; END IF;
 SELECT previous_reading,current_reading INTO v_previous,v_current
 FROM readings WHERE reading_id=p_reading_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown reading ID: %',p_reading_id; END IF;
 IF EXISTS(SELECT 1 FROM bills WHERE reading_id=p_reading_id) THEN RAISE EXCEPTION 'Reading % already billed',p_reading_id; END IF;
 INSERT INTO bills(reading_id,due_on,charge,amount_paid)
 VALUES(p_reading_id,p_due_on,fn_water_charge(v_current-v_previous),0);
END;
$$;

CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.customer_number,c.full_name,b.bill_id,b.due_on,b.charge,
       b.amount_paid,b.charge-b.amount_paid AS outstanding
FROM bills b JOIN readings r ON r.reading_id=b.reading_id
JOIN customers c ON c.customer_id=r.customer_id
WHERE b.due_on<CURRENT_DATE AND b.amount_paid<b.charge;

CREATE INDEX idx_bills_unpaid_due ON bills(due_on) WHERE amount_paid<charge;

CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql AS $$
BEGIN
 INSERT INTO receivable_snapshot(snapshot_date,total_outstanding)
 SELECT CURRENT_DATE,COALESCE(SUM(charge-amount_paid),0)
 FROM bills WHERE amount_paid<charge
 ON CONFLICT(snapshot_date) DO UPDATE
 SET total_outstanding=EXCLUDED.total_outstanding;
END;
$$;

INSERT INTO customers(customer_number,full_name) VALUES
('W001','Chanda Mwila'),('W002','Grace Phiri'),('W003','Kelvin Banda');
INSERT INTO readings(customer_id,reading_month,previous_reading,current_reading) VALUES
(1,'2026-10-01',100,100),(1,'2026-11-01',100,110),
(2,'2026-10-01',200,215),(2,'2026-11-01',215,220),
(3,'2026-10-01',300,312),(3,'2026-11-01',312,312);
CALL pr_generate_bill(1,CURRENT_DATE+10);
CALL pr_generate_bill(2,CURRENT_DATE+10);
CALL pr_generate_bill(3,DATE '2026-11-05');
CALL pr_generate_bill(4,DATE '2026-11-20');
CALL pr_generate_bill(5,DATE '2026-11-15');
CALL pr_generate_bill(6,CURRENT_DATE+10);
UPDATE bills SET amount_paid=30 WHERE reading_id=3;
CALL pr_refresh_receivables();
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM bills WHERE due_on<CURRENT_DATE AND amount_paid<charge;
