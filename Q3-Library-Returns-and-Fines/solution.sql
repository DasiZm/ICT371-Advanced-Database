-- ============================================================
-- ICT371 -Q3. LIBRARY RETURNS AND OVERDUE FINES
-- ============================================================
DROP SCHEMA IF EXISTS ict371_q03 CASCADE;
CREATE SCHEMA ict371_q03;
SET search_path TO ict371_q03, public;

CREATE TABLE books(
    book_id SERIAL PRIMARY KEY, title VARCHAR(150) NOT NULL UNIQUE
);
CREATE TABLE loans(
    loan_id SERIAL PRIMARY KEY,
    book_id INT NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(100) NOT NULL,
    borrowed_on DATE NOT NULL,
    due_on DATE NOT NULL,
    returned_on DATE,
    fine_amount NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK(fine_amount>=0),
    CHECK(due_on>=borrowed_on),
    CHECK(returned_on IS NULL OR returned_on>=borrowed_on)
);
CREATE TABLE loan_audit(
    audit_id SERIAL PRIMARY KEY,
    loan_id INT NOT NULL REFERENCES loans(loan_id),
    old_returned_on DATE,
    new_returned_on DATE,
    old_fine NUMERIC(12,2),
    new_fine NUMERIC(12,2),
    changed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE overdue_summary(
    snapshot_date DATE PRIMARY KEY,
    overdue_count BIGINT NOT NULL CHECK(overdue_count>=0),
    total_fine NUMERIC(14,2) NOT NULL CHECK(total_fine>=0)
);

CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INT,p_as_of DATE)
RETURNS NUMERIC(12,2) LANGUAGE plpgsql STABLE AS $$
DECLARE v_due DATE; v_returned DATE; v_effective DATE;
BEGIN
    IF p_loan_id IS NULL OR p_as_of IS NULL THEN RAISE EXCEPTION 'Loan ID and as-of date are required'; END IF;
    SELECT due_on,returned_on INTO v_due,v_returned FROM loans WHERE loan_id=p_loan_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown loan ID: %',p_loan_id; END IF;
    v_effective:=CASE WHEN v_returned IS NULL THEN p_as_of ELSE LEAST(p_as_of,v_returned) END;
    RETURN GREATEST(v_effective-v_due,0)*2.00;
END;
$$;

CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INT,p_return_date DATE)
LANGUAGE plpgsql AS $$
DECLARE v_borrowed DATE; v_returned DATE; v_fine NUMERIC(12,2);
BEGIN
    IF p_loan_id IS NULL OR p_return_date IS NULL THEN RAISE EXCEPTION 'Loan ID and return date are required'; END IF;
    SELECT borrowed_on,returned_on INTO v_borrowed,v_returned
    FROM loans WHERE loan_id=p_loan_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown loan ID: %',p_loan_id; END IF;
    IF v_returned IS NOT NULL THEN RAISE EXCEPTION 'Loan % has already been returned',p_loan_id; END IF;
    IF p_return_date<v_borrowed THEN RAISE EXCEPTION 'Return date precedes borrowing date'; END IF;
    UPDATE loans SET returned_on=p_return_date,
      fine_amount=GREATEST(p_return_date-due_on,0)*2.00
    WHERE loan_id=p_loan_id;
END;
$$;

CREATE OR REPLACE FUNCTION trg_loan_audit()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.returned_on IS DISTINCT FROM NEW.returned_on THEN
        INSERT INTO loan_audit(loan_id,old_returned_on,new_returned_on,old_fine,new_fine)
        VALUES(NEW.loan_id,OLD.returned_on,NEW.returned_on,OLD.fine_amount,NEW.fine_amount);
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER loans_audit AFTER UPDATE ON loans
FOR EACH ROW EXECUTE FUNCTION trg_loan_audit();

CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT l.loan_id,b.title,l.borrower_name,l.borrowed_on,l.due_on,
       fn_loan_fine(l.loan_id,CURRENT_DATE) AS fine_amount
FROM loans l JOIN books b ON b.book_id=l.book_id
WHERE l.returned_on IS NULL AND l.due_on<CURRENT_DATE;

CREATE INDEX idx_loans_book_unreturned ON loans(book_id) WHERE returned_on IS NULL;

CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_as_of IS NULL THEN RAISE EXCEPTION 'Snapshot date cannot be NULL'; END IF;
    INSERT INTO overdue_summary(snapshot_date,overdue_count,total_fine)
    SELECT p_as_of,COUNT(*),COALESCE(SUM(GREATEST(p_as_of-due_on,0)*2.00),0)
    FROM loans
    WHERE borrowed_on<=p_as_of AND due_on<p_as_of
      AND (returned_on IS NULL OR returned_on>p_as_of)
    ON CONFLICT(snapshot_date) DO UPDATE
    SET overdue_count=EXCLUDED.overdue_count,total_fine=EXCLUDED.total_fine;
END;
$$;

INSERT INTO books(title) VALUES('Database Systems'),('Operating Systems'),('Computer Networks');
INSERT INTO loans(book_id,borrower_name,borrowed_on,due_on,returned_on,fine_amount) VALUES
(1,'Chanda','2026-10-20','2026-11-08',NULL,0),
(2,'Grace','2026-11-10','2026-11-22',NULL,0),
(3,'Kelvin','2026-11-01','2026-11-12','2026-11-12',0),
(1,'Mutinta','2026-11-01','2026-11-09','2026-11-12',6),
(2,'Peter','2026-11-05','2026-11-17',NULL,0),
(3,'Mary','2026-11-15','2026-11-25',NULL,0);
CALL pr_refresh_overdue(CURRENT_DATE);
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM loans WHERE book_id=1 AND returned_on IS NULL;
