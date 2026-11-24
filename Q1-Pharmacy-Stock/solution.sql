-- ============================================================
-- ICT371 - Q1: Pharmacy Stock and Daily Sales
-- PostgreSQL
-- ============================================================

-- Clean rerun
DROP VIEW IF EXISTS v_low_stock;
DROP TABLE IF EXISTS daily_sales;
DROP TABLE IF EXISTS stock_audit;
DROP TABLE IF EXISTS sales;
DROP TABLE IF EXISTS medicines CASCADE;
DROP FUNCTION IF EXISTS fn_sale_value(INT, INT);
DROP FUNCTION IF EXISTS pr_record_sale(INT, INT, DATE);
DROP FUNCTION IF EXISTS pr_refresh_sales(DATE);

-- ------------------------------------------------------------
-- (a) Tables and Constraints
-- ------------------------------------------------------------

CREATE TABLE medicines (
    medicine_id   SERIAL PRIMARY KEY,
    medicine_name VARCHAR(100) NOT NULL UNIQUE,
    unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty     INT NOT NULL DEFAULT 0 CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id     SERIAL PRIMARY KEY,
    medicine_id INT NOT NULL REFERENCES medicines(medicine_id) ON DELETE RESTRICT,
    quantity    INT NOT NULL CHECK (quantity > 0),
    unit_price  NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    sold_on     DATE NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE stock_audit (
    audit_id    SERIAL PRIMARY KEY,
    medicine_id INT NOT NULL REFERENCES medicines(medicine_id),
    old_qty     INT NOT NULL,
    new_qty     INT NOT NULL,
    changed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE daily_sales (
    sales_date   DATE PRIMARY KEY,
    total_qty    INT NOT NULL DEFAULT 0 CHECK (total_qty >= 0),
    total_amount NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (total_amount >= 0)
);

-- ------------------------------------------------------------
-- (b) Function: fn_sale_value 
-- Returns current unit_price * quantity
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INT, p_quantity INT)
RETURNS NUMERIC(10,2) AS $$
DECLARE
    v_price NUMERIC(10,2);
BEGIN
    IF p_medicine_id IS NULL THEN
        RAISE EXCEPTION 'Medicine ID cannot be NULL';
    END IF;
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be positive, got %', p_quantity;
    END IF;

    SELECT unit_price INTO v_price FROM medicines WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    RETURN ROUND(v_price * p_quantity, 2);
END;
$$ LANGUAGE plpgsql STABLE;

-- ------------------------------------------------------------
-- (c) Procedure: pr_record_sale 
-- Checks stock, stores current price, deducts stock exactly once
-- Invalid sale leaves both tables unchanged (exception = rollback)
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_record_sale(p_medicine_id INT, p_quantity INT, p_sold_on DATE)
AS $$
DECLARE
    v_price NUMERIC(10,2);
    v_stock INT;
BEGIN
    IF p_medicine_id IS NULL OR p_quantity IS NULL OR p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Medicine, quantity and sold_on cannot be NULL';
    END IF;
    IF p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be positive';
    END IF;

    -- Lock the medicine row to prevent concurrent overselling
    SELECT unit_price, stock_qty INTO v_price, v_stock
    FROM medicines WHERE medicine_id = p_medicine_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock for medicine %: available %, requested %',
            p_medicine_id, v_stock, p_quantity;
    END IF;

    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);

    -- Deduct exactly once. Trigger will audit this update.
    UPDATE medicines SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id;
END;
$$ LANGUAGE plpgsql;

-- ------------------------------------------------------------
-- (d) Trigger: AFTER UPDATE on medicines -> stock_audit 
-- Only when stock_qty actually changes
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_medicines_stock_audit()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.stock_qty IS DISTINCT FROM NEW.stock_qty THEN
        INSERT INTO stock_audit (medicine_id, old_qty, new_qty, changed_at)
        VALUES (NEW.medicine_id, OLD.stock_qty, NEW.stock_qty, NOW());
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_stock_audit ON medicines;
CREATE TRIGGER trg_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW EXECUTE FUNCTION trg_medicines_stock_audit();

-- ------------------------------------------------------------
-- (e) View: v_low_stock 
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_id, medicine_name, unit_price, stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;

-- ------------------------------------------------------------
-- (f) Index 
-- For finding one medicine's sales within a sold_on date range
-- ------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_sales_medicine_sold_on
ON sales (medicine_id, sold_on);

-- Matching query + EXPLAIN (run this to show plan in output):
-- EXPLAIN ANALYZE
-- SELECT * FROM sales
-- WHERE medicine_id = 1 AND sold_on BETWEEN '2026-01-01' AND '2026-01-31';

-- Justification (put in README):
-- Composite B-tree (medicine_id, sold_on) lets Postgres seek directly to
-- that medicine, then range-scan only its dates, instead of full table scan.
-- medicine_id first for equality, sold_on second for range.

-- ------------------------------------------------------------
-- (g) Scheduled Job: pr_refresh_sales 
-- Replace that day's totals - rerun does NOT duplicate / double-count
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day cannot be NULL';
    END IF;

    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    SELECT p_day,
           COALESCE(SUM(quantity), 0),
           COALESCE(SUM(quantity * unit_price), 0)
    FROM sales WHERE sold_on = p_day
    ON CONFLICT (sales_date) DO UPDATE
    SET total_qty = EXCLUDED.total_qty,
        total_amount = EXCLUDED.total_amount;
END;
$$ LANGUAGE plpgsql;

-- Schedule daily at 00:15 for previous day (requires pg_cron)
-- Run once in your DB:
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- SELECT cron.schedule('q1-refresh-daily-sales', '15 0 * * *',
--   $$ CALL pr_refresh_sales(CURRENT_DATE - 1); $$);

-- ------------------------------------------------------------
-- Seed Data: 3 medicines + 6 valid sales via procedure
-- ------------------------------------------------------------
INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
('Paracetamol 500mg', 5.00, 100),
('Amoxicillin 250mg', 12.50, 50),
('ORS Sachet', 3.00, 15)
ON CONFLICT (medicine_name) DO NOTHING;

CALL pr_record_sale(1, 5, '2026-11-20');
CALL pr_record_sale(1, 3, '2026-11-21');
CALL pr_record_sale(2, 2, '2026-11-20');
CALL pr_record_sale(2, 4, '2026-11-21');
CALL pr_record_sale(3, 6, '2026-11-20'); -- leaves ORS at 9 -> low stock
CALL pr_record_sale(3, 2, '2026-11-21');

-- ------------------------------------------------------------
-- Verification queries 
-- ------------------------------------------------------------
-- SELECT * FROM medicines;
-- SELECT * FROM sales ORDER BY sale_id;
-- SELECT * FROM stock_audit ORDER BY audit_id;
-- SELECT * FROM v_low_stock; -- should show ORS Sachet with 7 left
-- SELECT fn_sale_value(1, 10); -- 50.00
-- CALL pr_refresh_sales('2026-11-20');
-- SELECT * FROM daily_sales;
-- -- Invalid test - must fail and change nothing:
-- -- CALL pr_record_sale(1, 1000, '2026-11-22'); -- Insufficient stock
