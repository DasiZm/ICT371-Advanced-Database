-- ============================================================
-- ICT371 - Q4: Clinic Appointment Scheduling
-- Slots: 09:00, 10:00, 11:00, 12:00
-- Two non-cancelled appointments must never share doctor + date + slot
-- ============================================================

DROP VIEW IF EXISTS v_today_appointments;
DROP TABLE IF EXISTS clinic_summary;
DROP TABLE IF EXISTS appointments;
DROP TABLE IF EXISTS doctors;
DROP TABLE IF EXISTS patients CASCADE;
DROP FUNCTION IF EXISTS fn_daily_load(INT, DATE);
DROP FUNCTION IF EXISTS pr_book_appointment(INT, INT, DATE, TIME);
DROP FUNCTION IF EXISTS pr_refresh_clinic_summary(DATE);

-- ------------------------------------------------------------
-- (a) Tables 
-- ------------------------------------------------------------
CREATE TABLE patients (
    patient_id SERIAL PRIMARY KEY,
    full_name  VARCHAR(100) NOT NULL
);

CREATE TABLE doctors (
    doctor_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE appointments (
    appointment_id  SERIAL PRIMARY KEY,
    patient_id      INT NOT NULL REFERENCES patients(patient_id) ON DELETE RESTRICT,
    doctor_id       INT NOT NULL REFERENCES doctors(doctor_id) ON DELETE RESTRICT,
    appointment_day DATE NOT NULL,
    slot_time       TIME NOT NULL CHECK (slot_time IN ('09:00','10:00','11:00','12:00')),
    status          VARCHAR(20) NOT NULL DEFAULT 'BOOKED'
                    CHECK (status IN ('BOOKED','ATTENDED','CANCELLED'))
);

CREATE TABLE clinic_summary (
    summary_date    DATE PRIMARY KEY,
    booked_count    INT NOT NULL DEFAULT 0 CHECK (booked_count >= 0),
    attended_count  INT NOT NULL DEFAULT 0 CHECK (attended_count >= 0),
    cancelled_count INT NOT NULL DEFAULT 0 CHECK (cancelled_count >= 0)
);

-- ------------------------------------------------------------
-- (b) Function: fn_daily_load 
-- Count doctor's non-cancelled appointments on that day
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INT, p_day DATE)
RETURNS INT AS $$
DECLARE
    v_count INT;
BEGIN
    IF p_doctor_id IS NULL OR p_day IS NULL THEN
        RAISE EXCEPTION 'Doctor ID and day cannot be NULL';
    END IF;

    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    SELECT COUNT(*) INTO v_count
    FROM appointments
    WHERE doctor_id = p_doctor_id
      AND appointment_day = p_day
      AND status <> 'CANCELLED';

    RETURN v_count;
END;
$$ LANGUAGE plpgsql STABLE;

-- ------------------------------------------------------------
-- (c) Procedure: pr_book_appointment 
-- Validate IDs, reject past date / unsupported slot, insert BOOKED
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_book_appointment(p_patient_id INT, p_doctor_id INT, p_day DATE, p_slot TIME)
AS $$
BEGIN
    IF p_patient_id IS NULL OR p_doctor_id IS NULL OR p_day IS NULL OR p_slot IS NULL THEN
        RAISE EXCEPTION 'Patient, doctor, day and slot cannot be NULL';
    END IF;

    PERFORM 1 FROM patients WHERE patient_id = p_patient_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown patient_id: %', p_patient_id;
    END IF;

    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    IF p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Cannot book appointment in the past: %', p_day;
    END IF;

    IF p_slot NOT IN ('09:00','10:00','11:00','12:00') THEN
        RAISE EXCEPTION 'Unsupported slot: %. Allowed: 09:00, 10:00, 11:00, 12:00', p_slot;
    END IF;

    -- Trigger will enforce clash rule - procedure does NOT bypass it
    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$ LANGUAGE plpgsql;

-- ------------------------------------------------------------
-- (d) Trigger: BEFORE INSERT OR UPDATE 
-- Reject clash with another non-cancelled appointment.
-- On UPDATE, exclude the appointment being changed.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_appointments_no_clash()
RETURNS TRIGGER AS $$
DECLARE
    v_clash INT;
BEGIN
    -- Only check if this row itself is non-cancelled
    IF NEW.status <> 'CANCELLED' THEN
        SELECT COUNT(*) INTO v_clash
        FROM appointments
        WHERE doctor_id = NEW.doctor_id
          AND appointment_day = NEW.appointment_day
          AND slot_time = NEW.slot_time
          AND status <> 'CANCELLED'
          -- Exclude self on UPDATE (appointment_id is NULL on INSERT, so no effect)
          AND appointment_id IS DISTINCT FROM NEW.appointment_id;

        IF v_clash > 0 THEN
            RAISE EXCEPTION 'Slot clash: doctor % already has a non-cancelled appointment on % at %',
                NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_appointments_no_clash ON appointments;
CREATE TRIGGER trg_appointments_no_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW EXECUTE FUNCTION trg_appointments_no_clash();

-- ------------------------------------------------------------
-- (e) View: v_today_appointments 
-- Today's BOOKED only, patient + doctor + slot. No unrelated patient data.
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT a.appointment_id, p.full_name AS patient_name, d.full_name AS doctor_name,
       a.appointment_day, a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors d ON d.doctor_id = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED';

-- ------------------------------------------------------------
-- (f) Index - non-unique, for appointment_day + doctor_id
-- ------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_appointments_day_doctor
ON appointments (appointment_day, doctor_id);

-- Matching query + EXPLAIN:
-- EXPLAIN ANALYZE
-- SELECT * FROM appointments
-- WHERE appointment_day = CURRENT_DATE AND doctor_id = 1;

-- Justification: appointment_day first for date equality, doctor_id second
-- to narrow to one doctor. Non-unique because many appointments can share
-- same day+doctor (different slots). Supports daily load + schedule views.

-- ------------------------------------------------------------
-- (g) Scheduled Job: pr_refresh_clinic_summary 
-- Count each of 3 statuses for that date. Replace on rerun.
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day cannot be NULL';
    END IF;

    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    SELECT p_day,
           COUNT(*) FILTER (WHERE status = 'BOOKED'),
           COUNT(*) FILTER (WHERE status = 'ATTENDED'),
           COUNT(*) FILTER (WHERE status = 'CANCELLED')
    FROM appointments WHERE appointment_day = p_day
    ON CONFLICT (summary_date) DO UPDATE
    SET booked_count = EXCLUDED.booked_count,
        attended_count = EXCLUDED.attended_count,
        cancelled_count = EXCLUDED.cancelled_count;
END;
$$ LANGUAGE plpgsql;

-- Schedule daily at 01:00 for previous day (requires pg_cron)
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- SELECT cron.schedule('q4-refresh-clinic-summary', '0 1 * * *',
--   $$ CALL pr_refresh_clinic_summary(CURRENT_DATE - 1); $$);

-- ------------------------------------------------------------
-- Seed Data: 3 patients, 3 doctors, 6 appointments, no slot clash
-- ------------------------------------------------------------
INSERT INTO patients (full_name) VALUES
('Chanda Mwila'), ('Grace Phiri'), ('Kelvin Banda');

INSERT INTO doctors (full_name) VALUES
('Dr. Mutale'), ('Dr. Zulu'), ('Dr. Banda');

-- Use future dates relative to CURRENT_DATE so pr_book_appointment passes past-date check
-- If you run this after those dates pass, change to CURRENT_DATE + n
INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
(1, 1, CURRENT_DATE + 1, '09:00', 'BOOKED'),
(2, 1, CURRENT_DATE + 1, '10:00', 'BOOKED'),
(3, 1, CURRENT_DATE + 1, '11:00', 'ATTENDED'), -- past example: use via direct insert, trigger allows
(1, 2, CURRENT_DATE + 1, '09:00', 'BOOKED'),
(2, 2, CURRENT_DATE + 1, '10:00', 'CANCELLED'),
(3, 3, CURRENT_DATE + 2, '12:00', 'BOOKED');

-- Example procedure calls (uncomment to test):
-- CALL pr_book_appointment(1, 3, CURRENT_DATE + 2, '09:00'); -- OK, different slot
-- CALL pr_book_appointment(1, 1, CURRENT_DATE - 1, '09:00'); -- FAIL past date
-- CALL pr_book_appointment(1, 1, CURRENT_DATE + 1, '09:00'); -- FAIL clash (trigger)

-- ------------------------------------------------------------
-- Verification
-- ------------------------------------------------------------
-- SELECT fn_daily_load(1, CURRENT_DATE + 1); -- 3 (BOOKED+ATTENDED, excludes CANCELLED for Dr1? Actually Dr1 has 3 non-cancelled)
-- SELECT * FROM v_today_appointments;
-- CALL pr_refresh_clinic_summary(CURRENT_DATE + 1);
-- SELECT * FROM clinic_summary;
-- -- Clash test - must fail:
-- -- INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
-- -- VALUES (1, 1, CURRENT_DATE + 1, '09:00', 'BOOKED');
