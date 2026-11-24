-- ============================================================
-- ICT371 - Q1: Pharmacy Stock and Daily Sales
-- PostgreSQL
-- ============================================================

DROP SCHEMA IF EXISTS ict371_q01 CASCADE;
CREATE SCHEMA ict371_q01;
SET search_path TO ict371_q01, public;

CREATE TABLE medicines (
    medicine_id SERIAL PRIMARY KEY,
    medicine_name VARCHAR(100) NOT NULL UNIQUE,
    unit_price NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty INTEGER NOT NULL CHECK (stock_qty >= 0)
);
CREATE TABLE sales (
    sale_id SERIAL PRIMARY KEY,
    medicine_id INT NOT NULL REFERENCES medicines(medicine_id),
    quantity INT NOT NULL CHECK (quantity > 0),
    unit_price NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    sale_value NUMERIC(12,2) NOT NULL CHECK (sale_value >= 0),
    sold_on DATE NOT NULL
);
CREATE TABLE stock_audit (
    audit_id SERIAL PRIMARY KEY,
    medicine_id INT NOT NULL REFERENCES medicines(medicine_id),
    old_qty INT NOT NULL CHECK (old_qty >= 0),
    new_qty INT NOT NULL CHECK (new_qty >= 0),
    changed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE daily_sales (
    sale_date DATE PRIMARY KEY,
    total_quantity BIGINT NOT NULL DEFAULT 0 CHECK (total_quantity >= 0),
    total_amount NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (total_amount >= 0)
);

CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INT, p_quantity INT)
RETURNS NUMERIC(12,2) LANGUAGE plpgsql STABLE AS $$
DECLARE v_price NUMERIC(10,2);
BEGIN
    IF p_medicine_id IS NULL OR p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Medicine ID and a positive quantity are required';
    END IF;
    SELECT unit_price INTO v_price FROM medicines WHERE medicine_id = p_medicine_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown medicine ID: %', p_medicine_id; END IF;
    RETURN ROUND(v_price * p_quantity, 2);
END;
$$;

CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INT, p_quantity INT, p_sold_on DATE
) LANGUAGE plpgsql AS $$
DECLARE v_price NUMERIC(10,2); v_stock INT;
BEGIN
    IF p_medicine_id IS NULL OR p_quantity IS NULL OR p_sold_on IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Medicine, positive quantity and sale date are required';
    END IF;
    SELECT unit_price, stock_qty INTO v_price, v_stock
    FROM medicines WHERE medicine_id = p_medicine_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown medicine ID: %', p_medicine_id; END IF;
    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock: available %, requested %', v_stock, p_quantity;
    END IF;
    INSERT INTO sales(medicine_id, quantity, unit_price, sale_value, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, ROUND(v_price*p_quantity,2), p_sold_on);
    UPDATE medicines SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id;
END;
$$;

CREATE OR REPLACE FUNCTION trg_medicines_stock_audit()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.stock_qty IS DISTINCT FROM NEW.stock_qty THEN
        INSERT INTO stock_audit(medicine_id, old_qty, new_qty)
        VALUES (NEW.medicine_id, OLD.stock_qty, NEW.stock_qty);
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER medicines_stock_audit
AFTER UPDATE OF stock_qty ON medicines
FOR EACH ROW EXECUTE FUNCTION trg_medicines_stock_audit();

CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_id, medicine_name, stock_qty
FROM medicines WHERE stock_qty < 10;

CREATE INDEX idx_sales_medicine_date ON sales(medicine_id, sold_on);

CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_day IS NULL THEN RAISE EXCEPTION 'Sale date cannot be NULL'; END IF;
    INSERT INTO daily_sales(sale_date,total_quantity,total_amount)
    SELECT p_day, COALESCE(SUM(quantity),0), COALESCE(SUM(sale_value),0)
    FROM sales WHERE sold_on=p_day
    ON CONFLICT(sale_date) DO UPDATE
    SET total_quantity=EXCLUDED.total_quantity, total_amount=EXCLUDED.total_amount;
END;
$$;

INSERT INTO medicines(medicine_name,unit_price,stock_qty) VALUES
('Paracetamol',5.00,100),('Amoxicillin',12.50,50),('ORS',3.00,15);

CALL pr_record_sale((SELECT medicine_id FROM medicines WHERE medicine_name='Paracetamol'),5,'2026-11-20');
CALL pr_record_sale((SELECT medicine_id FROM medicines WHERE medicine_name='Amoxicillin'),2,'2026-11-20');
CALL pr_record_sale((SELECT medicine_id FROM medicines WHERE medicine_name='ORS'),6,'2026-11-20');
CALL pr_record_sale((SELECT medicine_id FROM medicines WHERE medicine_name='Paracetamol'),3,'2026-11-21');
CALL pr_record_sale((SELECT medicine_id FROM medicines WHERE medicine_name='Amoxicillin'),4,'2026-11-21');
CALL pr_record_sale((SELECT medicine_id FROM medicines WHERE medicine_name='ORS'),2,'2026-11-21');
CALL pr_refresh_sales('2026-11-20');
CALL pr_refresh_sales('2026-11-21');

EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM sales WHERE medicine_id=1
AND sold_on BETWEEN DATE '2026-11-01' AND DATE '2026-11-30';
