-- ============================================================
-- ICT371 - Q5: Hostel Room Allocation
-- No exceeding capacity. One ACTIVE allocation per student.
-- ENDED = history, does NOT occupy a bed.
-- ============================================================

DROP VIEW IF EXISTS v_room_occupancy;
DROP TABLE IF EXISTS occupancy_snapshot;
DROP TABLE IF EXISTS allocations;
DROP TABLE IF EXISTS rooms;
DROP TABLE IF EXISTS students CASCADE;
DROP FUNCTION IF EXISTS fn_free_beds(INT);
DROP FUNCTION IF EXISTS pr_allocate_room(INT, INT, DATE);
DROP FUNCTION IF EXISTS pr_refresh_occupancy();

-- ------------------------------------------------------------
-- (a) Tables 
-- ------------------------------------------------------------
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE rooms (
    room_id     SERIAL PRIMARY KEY,
    room_number VARCHAR(20) NOT NULL UNIQUE,
    capacity    INT NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_id    INT NOT NULL REFERENCES students(student_id) ON DELETE RESTRICT,
    room_id       INT NOT NULL REFERENCES rooms(room_id) ON DELETE RESTRICT,
    allocated_on  DATE NOT NULL DEFAULT CURRENT_DATE,
    released_on   DATE NULL,
    status        VARCHAR(20) NOT NULL CHECK (status IN ('ACTIVE','ENDED')),
    -- ACTIVE requires released_on NULL; ENDED requires release date
    CHECK (
        (status = 'ACTIVE' AND released_on IS NULL) OR
        (status = 'ENDED' AND released_on IS NOT NULL)
    ),
    CHECK (released_on IS NULL OR released_on >= allocated_on)
);

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE NOT NULL,
    room_id       INT NOT NULL REFERENCES rooms(room_id),
    occupied_beds INT NOT NULL DEFAULT 0 CHECK (occupied_beds >= 0),
    free_beds     INT NOT NULL DEFAULT 0 CHECK (free_beds >= 0),
    PRIMARY KEY (snapshot_date, room_id)
);

-- ------------------------------------------------------------
-- (b) Function: fn_free_beds 
-- capacity - ACTIVE count. Reject unknown room.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INT)
RETURNS INT AS $$
DECLARE
    v_capacity INT;
    v_active   INT;
BEGIN
    IF p_room_id IS NULL THEN
        RAISE EXCEPTION 'Room ID cannot be NULL';
    END IF;

    SELECT capacity INTO v_capacity FROM rooms WHERE room_id = p_room_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    SELECT COUNT(*) INTO v_active
    FROM allocations
    WHERE room_id = p_room_id AND status = 'ACTIVE';

    RETURN v_capacity - v_active;
END;
$$ LANGUAGE plpgsql STABLE;

-- ------------------------------------------------------------
-- (c) Procedure: pr_allocate_room 
-- Validate IDs, no ACTIVE for student, check availability, create ACTIVE
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_allocate_room(p_student_id INT, p_room_id INT, p_allocated_on DATE)
AS $$
DECLARE
    v_active_student INT;
    v_free INT;
BEGIN
    IF p_student_id IS NULL OR p_room_id IS NULL OR p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'Student, room and allocated_on cannot be NULL';
    END IF;

    PERFORM 1 FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    PERFORM 1 FROM rooms WHERE room_id = p_room_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    SELECT COUNT(*) INTO v_active_student
    FROM allocations WHERE student_id = p_student_id AND status = 'ACTIVE';
    IF v_active_student > 0 THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
    END IF;

    v_free := fn_free_beds(p_room_id);
    IF v_free <= 0 THEN
        RAISE EXCEPTION 'Room % is full (0 free beds)', p_room_id;
    END IF;

    -- Trigger will re-check capacity + one-active rule for safety
    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$ LANGUAGE plpgsql;

-- ------------------------------------------------------------
-- (d) Trigger: BEFORE INSERT OR UPDATE 
-- Enforces capacity + one ACTIVE per student for DIRECT SQL too.
-- On UPDATE, exclude the row being updated.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_allocations_enforce_rules()
RETURNS TRIGGER AS $$
DECLARE
    v_active_student INT;
    v_active_room INT;
    v_capacity INT;
BEGIN
    -- Only enforce for ACTIVE rows
    IF NEW.status = 'ACTIVE' THEN
        -- 1. One ACTIVE per student, excluding self
        SELECT COUNT(*) INTO v_active_student
        FROM allocations
        WHERE student_id = NEW.student_id
          AND status = 'ACTIVE'
          AND allocation_id IS DISTINCT FROM NEW.allocation_id;
        IF v_active_student > 0 THEN
            RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
        END IF;

        -- 2. Capacity, excluding self
        SELECT capacity INTO v_capacity FROM rooms WHERE room_id = NEW.room_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Unknown room_id: %', NEW.room_id;
        END IF;

        SELECT COUNT(*) INTO v_active_room
        FROM allocations
        WHERE room_id = NEW.room_id
          AND status = 'ACTIVE'
          AND allocation_id IS DISTINCT FROM NEW.allocation_id;

        IF v_active_room >= v_capacity THEN
            RAISE EXCEPTION 'Room % is full: capacity %, already occupied %', NEW.room_id, v_capacity, v_active_room;
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_allocations_enforce_rules ON allocations;
CREATE TRIGGER trg_allocations_enforce_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW EXECUTE FUNCTION trg_allocations_enforce_rules();

-- ------------------------------------------------------------
-- (e) View: v_room_occupancy 
-- Every room, even with no allocations (LEFT JOIN)
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id, r.room_number, r.capacity,
       COUNT(a.allocation_id) AS occupied_beds,
       (r.capacity - COUNT(a.allocation_id)) AS free_beds
FROM rooms r
LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity;

-- ------------------------------------------------------------
-- (f) Index 
-- Supporting ACTIVE allocations filtered by room_id
-- ------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_allocations_room_active
ON allocations (room_id, status);

-- Alternative / stronger: partial index
-- CREATE INDEX idx_allocations_room_active_partial ON allocations (room_id)
-- WHERE status = 'ACTIVE';

-- Matching query + EXPLAIN:
-- EXPLAIN ANALYZE
-- SELECT * FROM allocations
-- WHERE room_id = 1 AND status = 'ACTIVE';

-- Justification: room_id first for equality, status second to filter ACTIVE.
-- Partial index is smaller - only stores ACTIVE rows, exactly what occupancy queries need.

-- ------------------------------------------------------------
-- (g) Scheduled Job: pr_refresh_occupancy 
-- Store CURRENT_DATE occupancy for every room. One row per date+room, replace on rerun.
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE, r.room_id,
           COUNT(a.allocation_id),
           r.capacity - COUNT(a.allocation_id)
    FROM rooms r
    LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status = 'ACTIVE'
    GROUP BY r.room_id, r.capacity
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
    SET occupied_beds = EXCLUDED.occupied_beds,
        free_beds = EXCLUDED.free_beds;
END;
$$ LANGUAGE plpgsql;

-- Schedule daily at 23:55 (requires pg_cron)
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- SELECT cron.schedule('q5-refresh-occupancy', '55 23 * * *',
--   $$ CALL pr_refresh_occupancy(); $$);

-- ------------------------------------------------------------
-- Seed Data: rooms, students, allocations
-- Full, partly occupied, empty rooms + ENDED history
-- ------------------------------------------------------------
INSERT INTO students (student_number, full_name) VALUES
('2026-001', 'Chanda Mwila'),
('2026-002', 'Grace Phiri'),
('2026-003', 'Kelvin Banda'),
('2026-004', 'Mutinta Zulu'),
('2026-005', 'Boyd Chileshe');

INSERT INTO rooms (room_number, capacity) VALUES
('A101', 2), -- will be FULL
('A102', 3), -- partly occupied
('A103', 2); -- EMPTY

-- A101 FULL: 2 ACTIVE
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status) VALUES
(1, 1, '2026-11-01', NULL, 'ACTIVE'),
(2, 1, '2026-11-01', NULL, 'ACTIVE');
-- A102 partly: 1 ACTIVE + 1 ENDED history (ENDED does not occupy)
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status) VALUES
(3, 2, '2026-11-01', NULL, 'ACTIVE'),
(4, 2, '2026-10-01', '2026-10-20', 'ENDED');
-- A103 empty: no allocations
-- Student 5 has no allocation, can be allocated via procedure

-- Example procedure use:
-- CALL pr_allocate_room(5, 2, '2026-11-24'); -- OK, A102 has free beds
-- CALL pr_allocate_room(5, 1, '2026-11-24'); -- FAIL, A101 full
-- CALL pr_allocate_room(1, 2, '2026-11-24'); -- FAIL, student 1 already ACTIVE

-- ------------------------------------------------------------
-- Verification
-- ------------------------------------------------------------
-- SELECT fn_free_beds(1); -- 0
-- SELECT fn_free_beds(2); -- 2 (3 - 1 ACTIVE, ENDED ignored)
-- SELECT fn_free_beds(3); -- 2
-- SELECT * FROM v_room_occupancy;
-- CALL pr_refresh_occupancy();
-- SELECT * FROM occupancy_snapshot;
-- -- Direct SQL must also fail via trigger:
-- -- INSERT INTO allocations (student_id, room_id, allocated_on, status) VALUES (5, 1, '2026-11-24', 'ACTIVE');
