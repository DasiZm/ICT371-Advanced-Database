-- ============================================================
-- ICT371 - Q3: Library Returns and Overdue Fines
-- Fine = K2 per day after due date. On due date = 0.
-- Returned loan stops accumulating fines.
-- ============================================================

DROP VIEW IF EXISTS v_overdue_loans;
DROP TABLE IF EXISTS overdue_summary;
DROP TABLE IF EXISTS loan_audit;
DROP TABLE IF EXISTS loans;
DROP TABLE IF EXISTS books CASCADE;
DROP FUNCTION IF EXISTS fn_loan_fine(INT, DATE);
DROP FUNCTION IF EXISTS pr_return_loan(INT, DATE);
DROP FUNCTION IF EXISTS pr_refresh_overdue(DATE);

-- ------------------------------------------------------------
-- (a) Tables
-- ------------------------------------------------------------
CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title   VARCHAR(200) NOT NULL
);

CREATE TABLE loans (
    loan_id       SERIAL PRIMARY KEY,
    book_id       INT NOT NULL REFERENCES books(book_id) ON DELETE RESTRICT,
    borrower_name VARCHAR(100) NOT NULL,
    borrowed_on   DATE NOT NULL,
    due_on        DATE NOT NULL CHECK (due_on >= borrowed_on),
    returned_on   DATE NULL CHECK (returned_on IS NULL OR returned_on >= borrowed_on),
    fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0)
);

CREATE TABLE loan_audit (
    audit_id         SERIAL PRIMARY KEY,
    loan_id          INT NOT NULL REFERENCES loans(loan_id),
    old_returned_on  DATE NULL,
    new_returned_on  DATE NULL,
    changed_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INT NOT NULL DEFAULT 0 CHECK (overdue_count >= 0),
    total_fine    NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (total_fine >= 0)
);

-- ------------------------------------------------------------
-- (b) Function: fn_loan_fine
-- K2 * overdue days, min 0. Use earlier of p_as_of and returned_on.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INT, p_as_of DATE)
RETURNS NUMERIC(10,2) AS $$
DECLARE
    v_due_on      DATE;
    v_returned_on DATE;
    v_effective   DATE;
    v_overdue_days INT;
BEGIN
    IF p_loan_id IS NULL OR p_as_of IS NULL THEN
        RAISE EXCEPTION 'Loan ID and as_of date cannot be NULL';
    END IF;

    SELECT due_on, returned_on INTO v_due_on, v_returned_on
    FROM loans WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;

    -- If returned, fines stop at return date. Else stop at p_as_of.
    IF v_returned_on IS NOT NULL THEN
        v_effective := LEAST(p_as_of, v_returned_on);
    ELSE
        v_effective := p_as_of;
    END IF;

    v_overdue_days := GREATEST(0, v_effective - v_due_on);

    RETURN ROUND(v_overdue_days * 2.00, 2);
END;
$$ LANGUAGE plpgsql STABLE;

-- ------------------------------------------------------------
-- (c) Procedure: pr_return_loan
-- Store return date + final fine TOGETHER in one UPDATE
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INT, p_returned_on DATE)
AS $$
DECLARE
    v_borrowed_on DATE;
    v_returned_on DATE;
    v_fine NUMERIC(10,2);
BEGIN
    IF p_loan_id IS NULL OR p_returned_on IS NULL THEN
        RAISE EXCEPTION 'Loan ID and returned_on cannot be NULL';
    END IF;

    SELECT borrowed_on, returned_on INTO v_borrowed_on, v_returned_on
    FROM loans WHERE loan_id = p_loan_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;
    IF v_returned_on IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % already returned on %', p_loan_id, v_returned_on;
    END IF;
    IF p_returned_on < v_borrowed_on THEN
        RAISE EXCEPTION 'Return date % cannot be before borrowed_on %', p_returned_on, v_borrowed_on;
    END IF;

    -- Final fine uses return date as effective date
    v_fine := fn_loan_fine(p_loan_id, p_returned_on);

    UPDATE loans
    SET returned_on = p_returned_on,
        fine_amount = v_fine
    WHERE loan_id = p_loan_id;
END;
$$ LANGUAGE plpgsql;

-- ------------------------------------------------------------
-- (d) Trigger: AFTER UPDATE on loans -> loan_audit
-- Only when returned_on actually changes
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_loans_return_audit()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.returned_on IS DISTINCT FROM NEW.returned_on THEN
        INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on, changed_at)
        VALUES (NEW.loan_id, OLD.returned_on, NEW.returned_on, NOW());
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_loans_return_audit ON loans;
CREATE TRIGGER trg_loans_return_audit
AFTER UPDATE ON loans
FOR EACH ROW EXECUTE FUNCTION trg_loans_return_audit();

-- ------------------------------------------------------------
-- (e) View: v_overdue_loans
-- Currently unreturned AND due before CURRENT_DATE
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT l.loan_id, b.title AS book_title, l.borrower_name, l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

-- ------------------------------------------------------------
-- (f) Index
-- For a given book's unreturned loans
-- ------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_loans_book_unreturned
ON loans (book_id, returned_on);

-- Alternative stronger version (partial index - mention in README):
-- CREATE INDEX idx_loans_book_unreturned_partial ON loans (book_id)
-- WHERE returned_on IS NULL;

-- Matching query + EXPLAIN:
-- EXPLAIN ANALYZE
-- SELECT * FROM loans
-- WHERE book_id = 1 AND returned_on IS NULL;

-- Justification: book_id first for equality, returned_on second to filter
-- unreturned quickly. Partial index is even smaller - only stores unreturned rows.

-- ------------------------------------------------------------
-- (g) Scheduled Job: pr_refresh_overdue
-- Count loans still unreturned as of p_as_of + sum their fines.
-- Replace same snapshot_date on rerun.
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
AS $$
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of cannot be NULL';
    END IF;

    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of,
           COUNT(*),
           COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
    FROM loans
    WHERE borrowed_on <= p_as_of
      AND due_on < p_as_of
      AND (returned_on IS NULL OR returned_on > p_as_of)
    ON CONFLICT (snapshot_date) DO UPDATE
    SET overdue_count = EXCLUDED.overdue_count,
        total_fine = EXCLUDED.total_fine;
END;
$$ LANGUAGE plpgsql;

-- Schedule daily at 00:10 for CURRENT_DATE (requires pg_cron)
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- SELECT cron.schedule('q3-refresh-overdue', '10 0 * * *',
--   $$ CALL pr_refresh_overdue(CURRENT_DATE); $$);

-- ------------------------------------------------------------
-- Seed Data: 3 books + 6 loans
-- 1 = open overdue, 2 = on-time (not yet due / returned on time), 3 = returned late, etc.
-- ------------------------------------------------------------
INSERT INTO books (title) VALUES
('Database System Concepts'),
('Introduction to Algorithms'),
('Clean Code')
ON CONFLICT DO NOTHING;

-- Use direct INSERT for seed so we can set returned loans for history.
-- In real use, returns go through pr_return_loan().
INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on, returned_on, fine_amount) VALUES
(1, 'Mutinta Zulu',   '2026-11-01', '2026-11-08', NULL, 0), -- open overdue
(1, 'Boyd Chileshe',  '2026-11-15', '2026-11-22', NULL, 0), -- open, not yet overdue if today < 22nd
(2, 'Nchimunya Banda','2026-11-05', '2026-11-12', '2026-11-12', 0), -- on-time return, 0 fine
(2, 'Chisomo Phiri',  '2026-11-02', '2026-11-09', '2026-11-12', 6.00), -- returned 3 days late = K6
(3, 'Tawanda Moyo',   '2026-11-10', '2026-11-17', NULL, 0), -- open overdue
(3, 'Luyando Mwewa',  '2026-11-18', '2026-11-25', NULL, 0)  -- open, not yet due
ON CONFLICT DO NOTHING;

-- Example of procedure use (uncomment to test):
-- CALL pr_return_loan(1, '2026-11-24'); -- will set fine + trigger audit

-- ------------------------------------------------------------
-- Verification
-- ------------------------------------------------------------
-- SELECT * FROM books;
-- SELECT * FROM loans ORDER BY loan_id;
-- SELECT fn_loan_fine(1, '2026-11-24'); -- e.g. (24-08)=16 days *2 = 32.00 if still unreturned
-- SELECT fn_loan_fine(4, '2026-11-20'); -- returned loan: uses returned_on 12th, (12-09)=3*2=6.00
-- SELECT * FROM v_overdue_loans;
-- CALL pr_refresh_overdue(CURRENT_DATE);
-- SELECT * FROM overdue_summary;
-- SELECT * FROM loan_audit;
-- -- Must fail:
-- -- CALL pr_return_loan(3, '2026-11-01'); -- already returned
-- -- CALL pr_return_loan(999, '2026-11-20'); -- unknown
