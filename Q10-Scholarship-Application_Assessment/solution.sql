-- ============================================================
-- Q10. SCHOLARSHIP APPLICATION ASSESSMENT
-- ============================================================
DROP SCHEMA IF EXISTS ict371_q10 CASCADE;
CREATE SCHEMA ict371_q10;
SET search_path TO ict371_q10, public;

CREATE TABLE students(
 student_id SERIAL PRIMARY KEY,student_number VARCHAR(20) NOT NULL UNIQUE,
 full_name VARCHAR(100) NOT NULL
);
CREATE TABLE applications(
 application_id SERIAL PRIMARY KEY,student_id INT NOT NULL REFERENCES students(student_id) ON DELETE RESTRICT,
 age_at_application INT NOT NULL CHECK(age_at_application>0),
 monthly_income NUMERIC(10,2) NOT NULL CHECK(monthly_income>=0),
 average_mark NUMERIC(5,2) NOT NULL CHECK(average_mark BETWEEN 0 AND 100),
 submitted_on DATE NOT NULL DEFAULT CURRENT_DATE,
 status VARCHAR(20) NOT NULL DEFAULT 'PENDING'
 CHECK(status IN('PENDING','APPROVED','REJECTED'))
);
CREATE TABLE decision_audit(
 audit_id SERIAL PRIMARY KEY,application_id INT NOT NULL REFERENCES applications(application_id),
 old_status VARCHAR(20) NOT NULL,new_status VARCHAR(20) NOT NULL,
 changed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INT,p_income NUMERIC,p_mark NUMERIC)
RETURNS BOOLEAN LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
 IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN RAISE EXCEPTION 'Age, income and mark cannot be NULL'; END IF;
 IF p_age<=0 THEN RAISE EXCEPTION 'Age must be positive'; END IF;
 IF p_income<0 THEN RAISE EXCEPTION 'Income cannot be negative'; END IF;
 IF p_mark<0 OR p_mark>100 THEN RAISE EXCEPTION 'Mark must be between 0 and 100'; END IF;
 RETURN p_age BETWEEN 18 AND 25 AND p_income<=3000 AND p_mark>=70;
END;
$$;

CREATE OR REPLACE FUNCTION trg_applications_decision_audit()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
 IF OLD.status IS DISTINCT FROM NEW.status THEN
   INSERT INTO decision_audit(application_id,old_status,new_status,changed_at)
   VALUES(NEW.application_id,OLD.status,NEW.status,NOW());
 END IF;
 RETURN NEW;
END;
$$;
CREATE TRIGGER applications_decision_audit AFTER UPDATE ON applications
FOR EACH ROW EXECUTE FUNCTION trg_applications_decision_audit();

CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INT)
LANGUAGE plpgsql AS $$
DECLARE v_age INT;v_income NUMERIC(10,2);v_mark NUMERIC(5,2);v_status VARCHAR(20);v_eligible BOOLEAN;
BEGIN
 IF p_application_id IS NULL THEN RAISE EXCEPTION 'Application ID cannot be NULL'; END IF;
 SELECT age_at_application,monthly_income,average_mark,status
 INTO v_age,v_income,v_mark,v_status
 FROM applications WHERE application_id=p_application_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown application ID: %',p_application_id; END IF;
 IF v_status<>'PENDING' THEN RAISE EXCEPTION 'Application % already assessed (status: %)',p_application_id,v_status; END IF;
 v_eligible:=fn_scholarship_eligible(v_age,v_income,v_mark);
 UPDATE applications SET status=CASE WHEN v_eligible THEN 'APPROVED' ELSE 'REJECTED' END
 WHERE application_id=p_application_id;
END;
$$;

CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number,s.full_name,a.average_mark,a.status
FROM applications a JOIN students s ON s.student_id=a.student_id
WHERE a.status='APPROVED';

CREATE INDEX idx_applications_status_submitted ON applications(status,submitted_on);

CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql AS $$
DECLARE r RECORD;
BEGIN
 FOR r IN SELECT application_id FROM applications
          WHERE status='PENDING' ORDER BY application_id
 LOOP
   CALL pr_assess_application(r.application_id);
 END LOOP;
END;
$$;

INSERT INTO students(student_number,full_name) VALUES
('2026-001','Chanda Mwila'),('2026-002','Grace Phiri'),('2026-003','Kelvin Banda');
INSERT INTO applications(student_id,age_at_application,monthly_income,average_mark,submitted_on,status) VALUES
((SELECT student_id FROM students WHERE student_number='2026-001'),20,2500,82,'2026-11-20','PENDING'),
((SELECT student_id FROM students WHERE student_number='2026-001'),26,2500,82,'2026-11-20','PENDING'),
((SELECT student_id FROM students WHERE student_number='2026-002'),18,3000,70,'2026-11-21','PENDING'),
((SELECT student_id FROM students WHERE student_number='2026-002'),25,3000.01,70,'2026-11-21','PENDING'),
((SELECT student_id FROM students WHERE student_number='2026-003'),22,2000,69.99,'2026-11-22','PENDING'),
((SELECT student_id FROM students WHERE student_number='2026-003'),17,2000,90,'2026-11-22','PENDING');
CALL pr_assess_pending();
CALL pr_assess_pending(); -- rerun: no changes, no duplicate audit rows
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM applications
WHERE status='PENDING'
AND submitted_on BETWEEN DATE '2026-11-01' AND DATE '2026-11-30';
