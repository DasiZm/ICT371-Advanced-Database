-- ============================================================
-- Q9. FARMER COOPERATIVE MAIZE DELIVERIES
-- ============================================================
DROP SCHEMA IF EXISTS ict371_q09 CASCADE;
CREATE SCHEMA ict371_q09;
SET search_path TO ict371_q09, public;

CREATE TABLE farmers(
 farmer_id SERIAL PRIMARY KEY,farmer_number VARCHAR(20) NOT NULL UNIQUE,
 full_name VARCHAR(100) NOT NULL
);
CREATE TABLE deliveries(
 delivery_id SERIAL PRIMARY KEY,farmer_id INT NOT NULL REFERENCES farmers(farmer_id) ON DELETE RESTRICT,
 grade VARCHAR(5) NOT NULL CHECK(grade IN('A','B','C')),
 weight_kg NUMERIC(10,2) NOT NULL CHECK(weight_kg>0),
 unit_rate NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK(unit_rate>=0),
 total_value NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK(total_value>=0),
 delivered_on DATE NOT NULL,is_paid BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE TABLE daily_purchases(
 purchase_date DATE PRIMARY KEY,total_weight NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK(total_weight>=0),
 total_value NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK(total_value>=0)
);

CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade TEXT)
RETURNS NUMERIC(10,2) LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE v_rate NUMERIC(10,2);
BEGIN
 IF p_grade IS NULL THEN RAISE EXCEPTION 'Grade cannot be NULL'; END IF;
 v_rate:=CASE UPPER(TRIM(p_grade)) WHEN 'A' THEN 5.00 WHEN 'B' THEN 4.00 WHEN 'C' THEN 3.00 ELSE NULL END;
 IF v_rate IS NULL THEN RAISE EXCEPTION 'Unsupported grade: % (allowed A, B, C)',p_grade; END IF;
 RETURN v_rate;
END;
$$;

CREATE OR REPLACE FUNCTION trg_deliveries_pricing()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.weight_kg IS NULL OR NEW.weight_kg<=0 THEN RAISE EXCEPTION 'Weight must be positive'; END IF;
 NEW.grade:=UPPER(TRIM(NEW.grade));
 NEW.unit_rate:=fn_maize_rate(NEW.grade);
 NEW.total_value:=ROUND(NEW.weight_kg*NEW.unit_rate,2);
 RETURN NEW;
END;
$$;
CREATE TRIGGER deliveries_pricing BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW EXECUTE FUNCTION trg_deliveries_pricing();

CREATE OR REPLACE PROCEDURE pr_receive_delivery(
 p_farmer_id INT,p_grade TEXT,p_weight NUMERIC,p_date DATE
) LANGUAGE plpgsql AS $$
BEGIN
 IF p_farmer_id IS NULL OR p_grade IS NULL OR p_weight IS NULL OR p_date IS NULL OR p_weight<=0 THEN
   RAISE EXCEPTION 'Farmer, grade, positive weight and date are required';
 END IF;
 PERFORM 1 FROM farmers WHERE farmer_id=p_farmer_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown farmer ID: %',p_farmer_id; END IF;
 PERFORM fn_maize_rate(p_grade);
 INSERT INTO deliveries(farmer_id,grade,weight_kg,delivered_on,is_paid)
 VALUES(p_farmer_id,UPPER(TRIM(p_grade)),p_weight,p_date,FALSE);
END;
$$;

CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number,f.full_name,COALESCE(SUM(d.total_value),0) AS amount_due
FROM farmers f LEFT JOIN deliveries d ON d.farmer_id=f.farmer_id AND d.is_paid=FALSE
GROUP BY f.farmer_id,f.farmer_number,f.full_name;

CREATE INDEX idx_deliveries_farmer_date ON deliveries(farmer_id,delivered_on);

CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
 IF p_day IS NULL THEN RAISE EXCEPTION 'Purchase date cannot be NULL'; END IF;
 INSERT INTO daily_purchases(purchase_date,total_weight,total_value)
 SELECT p_day,COALESCE(SUM(weight_kg),0),COALESCE(SUM(total_value),0)
 FROM deliveries WHERE delivered_on=p_day
 ON CONFLICT(purchase_date) DO UPDATE SET
 total_weight=EXCLUDED.total_weight,total_value=EXCLUDED.total_value;
END;
$$;

INSERT INTO farmers(farmer_number,full_name) VALUES
('F-001','Chanda Mwila'),('F-002','Grace Phiri'),('F-003','Kelvin Banda');
CALL pr_receive_delivery((SELECT farmer_id FROM farmers WHERE farmer_number='F-001'),'A',100,'2026-11-20');
CALL pr_receive_delivery((SELECT farmer_id FROM farmers WHERE farmer_number='F-001'),'B',50,'2026-11-20');
CALL pr_receive_delivery((SELECT farmer_id FROM farmers WHERE farmer_number='F-002'),'C',80,'2026-11-20');
CALL pr_receive_delivery((SELECT farmer_id FROM farmers WHERE farmer_number='F-002'),'A',20,'2026-11-21');
CALL pr_receive_delivery((SELECT farmer_id FROM farmers WHERE farmer_number='F-003'),'B',60,'2026-11-21');
CALL pr_receive_delivery((SELECT farmer_id FROM farmers WHERE farmer_number='F-003'),'C',40,'2026-11-22');
UPDATE deliveries SET is_paid=TRUE
WHERE delivery_id IN (
 SELECT delivery_id FROM deliveries WHERE farmer_id=(SELECT farmer_id FROM farmers WHERE farmer_number='F-001')
 ORDER BY delivery_id LIMIT 1
);
UPDATE deliveries SET is_paid=TRUE
WHERE delivery_id=(SELECT delivery_id FROM deliveries
 WHERE farmer_id=(SELECT farmer_id FROM farmers WHERE farmer_number='F-002')
 ORDER BY delivery_id DESC LIMIT 1);
CALL pr_refresh_purchases('2026-11-20');
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM deliveries WHERE farmer_id=1
AND delivered_on BETWEEN DATE '2026-11-01' AND DATE '2026-11-30';
