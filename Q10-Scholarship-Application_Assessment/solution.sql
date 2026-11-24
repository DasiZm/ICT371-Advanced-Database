-- ============================================================
-- ICT371 - Q10: Scholarship Application Assessment
-- Qualify ONLY when: age 18-25 inclusive, income <= K3000, mark >= 70
-- Statuses: PENDING, APPROVED, REJECTED
-- ============================================================

DROP VIEW IF EXISTS v_approved_applicants;
DROP TABLE IF EXISTS decision_audit;
DROP TABLE IF EXISTS applications;
DROP TABLE IF EXISTS students CASCADE;
DROP FUNCTION IF EXISTS fn_scholarship_eligible(INT, NUMERIC, NUMERIC);
DROP FUNCTION IF EXISTS pr_assess_application(INT);
DROP FUNCTION IF EXISTS pr_assess_pending();

-- ------------------------------------------------------------
-- (a) Tables
-- ------------------------------------------------------------
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
    application_id     SERIAL PRIMARY KEY,
    student_id         INT NOT NULL REFERENCES students(student_id) ON DELETE RESTRICT,
    age_at_application INT NOT NULL CHECK (age_at_application > 0),
    monthly_income     NUMERIC(10,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark       NUMERIC(5,2) NOT NULL CHECK (average_mark >= 0 AND average_mark <= 100),
    submitted_on       DATE NOT NULL DEFAULT CURRENT_DATE,
    status             VARCHAR(20) NOT NULL DEFAULT 'PENDING'
                       CHECK (status IN ('PENDING','APPROVED','REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id       SERIAL PRIMARY KEY,
    application_id INT NOT NULL REFERENCES applications(application_id),
    old_status     VARCHAR(20) NOT NULL,
    new_status     VARCHAR(20) NOT NULL,
    changed_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ------------------------------------------------------------
-- (b) Function: fn_scholarship_eligible
-- All 3 rules must pass. Reject invalid inputs.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INT, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income and mark cannot be NULL';
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive, got %', p_age;
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Income cannot be negative, got %', p_income;
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Mark must be 0 to 100, got %', p_mark;
    END IF;

    RETURN (p_age BETWEEN 18 AND 25)
       AND (p_income <= 3000)
       AND (p_mark >= 70);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- ------------------------------------------------------------
-- (c) Procedure: pr_assess_application
-- Require existing PENDING, call function, update to APPROVED / REJECTED
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INT)
AS $$
DECLARE
    v_age INT;
    v_income NUMERIC(10,2);
    v_mark NUMERIC(5,2);
    v_status VARCHAR(20);
    v_eligible BOOLEAN;
BEGIN
    IF p_application_id IS NULL THEN
        RAISE EXCEPTION 'Application ID cannot be NULL';
    END IF;

    SELECT age_at_application, monthly_income, average_mark, status
    INTO v_age, v_income, v_mark, v_status
    FROM applications WHERE application_id = p_application_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application_id: %', p_application_id;
    END IF;

    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % already assessed (status: %)', p_application_id, v_status;
    END IF;

    v_eligible := fn_scholarship_eligible(v_age, v_income, v_mark);

    UPDATE applications
    SET status = CASE WHEN v_eligible THEN 'APPROVED' ELSE 'REJECTED' END
    WHERE application_id = p_application_id;
    -- Trigger logs the status change to decision_audit automatically
END;
$$ LANGUAGE plpgsql;

-- ------------------------------------------------------------
-- (d) Trigger: AFTER UPDATE
-- Record ACTUAL status changes only
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_applications_decision_audit()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.status IS DISTINCT FROM NEW.status THEN
        INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
        VALUES (NEW.application_id, OLD.status, NEW.status, NOW());
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_applications_decision_audit ON applications;
CREATE TRIGGER trg_applications_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW EXECUTE FUNCTION trg_applications_decision_audit();

-- ------------------------------------------------------------
-- (e) View: v_approved_applicants
-- APPROVED only. Omit household income.
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number, s.full_name, a.average_mark, a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

-- ------------------------------------------------------------
-- (f) Index
-- Applications searched by status within submitted_on range
-- ------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_applications_status_submitted
ON applications (status, submitted_on);

-- Matching query + EXPLAIN:
-- EXPLAIN ANALYZE
-- SELECT * FROM applications
-- WHERE status = 'PENDING'
--   AND submitted_on BETWEEN '2026-11-01' AND '2026-11-30';

-- Justification: status first for equality, submitted_on second for range.
-- Lets Postgres seek to PENDING rows then scan only dates in range.
-- Partial index alternative: ON applications (submitted_on) WHERE status = 'PENDING'
-- is smaller if PENDING is a small share.

-- ------------------------------------------------------------
-- (g) Scheduled Job: pr_assess_pending
-- FOR loop over PENDING only, via pr_assess_application.
-- Rerun must NOT reassess completed or duplicate audit.
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_assess_pending()
AS $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN SELECT application_id FROM applications
             WHERE status = 'PENDING' ORDER BY application_id
    LOOP
        CALL pr_assess_application(r.application_id);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Schedule every Monday at 08:00 (requires pg_cron)
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- SELECT cron.schedule('q10-assess-pending', '0 8 * * 1',
--   $$ CALL pr_assess_pending(); $$);

-- Why rerun is safe:
-- 1. Loop only selects status = 'PENDING' - APPROVED/REJECTED are never picked up again
-- 2. pr_assess_application rejects non-PENDING if called directly
-- 3. Trigger only logs when status actually changes, so no duplicate audit rows

-- ------------------------------------------------------------
-- Seed Data: 6 PENDING, qualifying + non-qualifying + boundary, >= 3 students
-- ------------------------------------------------------------
INSERT INTO students (student_number, full_name) VALUES
('2026-001', 'Chanda Mwila'),
('2026-002', 'Grace Phiri'),
('2026-003', 'Kelvin Banda');

INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on, status) VALUES
(1, 20, 2500.00, 82.00, '2026-11-20', 'PENDING'), -- QUALIFIES: all pass
(1, 26, 2500.00, 82.00, '2026-11-20', 'PENDING'), -- FAILS: age 26 > 25
(2, 18, 3000.00, 70.00, '2026-11-21', 'PENDING'), -- BOUNDARY: 18, 3000, 70 -> QUALIFIES (inclusive)
(2, 25, 3000.01, 70.00, '2026-11-21', 'PENDING'), -- BOUNDARY FAIL: income 3000.01 > 3000
(3, 22, 2000.00, 69.99, '2026-11-22', 'PENDING'), -- BOUNDARY FAIL: mark 69.99 < 70
(3, 17, 2000.00, 90.00, '2026-11-22', 'PENDING'); -- FAILS: age 17 < 18

-- ------------------------------------------------------------
-- Verification
-- ------------------------------------------------------------
-- SELECT fn_scholarship_eligible(20, 2500, 82); -- TRUE
-- SELECT fn_scholarship_eligible(18, 3000, 70); -- TRUE (boundary)
-- SELECT fn_scholarship_eligible(26, 2500, 82); -- FALSE
-- -- Assess one:
-- -- CALL pr_assess_application(1); -- -> APPROVED + 1 audit row
-- -- CALL pr_assess_application(1); -- FAIL: already assessed
-- -- CALL pr_assess_application(999); -- FAIL: unknown
-- -- Assess all remaining via job:
-- -- CALL pr_assess_pending();
-- -- SELECT * FROM applications ORDER BY application_id;
-- -- SELECT * FROM v_approved_applicants; -- should show apps 1 + 3
-- -- SELECT * FROM decision_audit; -- 6 rows, one per application
-- -- CALL pr_assess_pending(); -- rerun: does nothing, no duplicate audit
-- -- Must fail - invalid inputs:
-- -- SELECT fn_scholarship_eligible(NULL, 2500, 80);
-- -- SELECT fn_scholarship_eligible(20, -100, 80);
-- -- SELECT fn_scholarship_eligible(20, 2500, 101);
