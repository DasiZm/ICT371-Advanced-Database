-- ============================================================
-- Q5. HOSTEL ROOM ALLOCATION
-- ============================================================
DROP SCHEMA IF EXISTS ict371_q05 CASCADE;
CREATE SCHEMA ict371_q05;
SET search_path TO ict371_q05, public;

CREATE TABLE students(student_id SERIAL PRIMARY KEY,student_number VARCHAR(20) UNIQUE NOT NULL,full_name VARCHAR(100) NOT NULL);
CREATE TABLE rooms(room_id SERIAL PRIMARY KEY,room_number VARCHAR(20) UNIQUE NOT NULL,capacity INT NOT NULL CHECK(capacity>0));
CREATE TABLE allocations(
 allocation_id SERIAL PRIMARY KEY,
 student_id INT NOT NULL REFERENCES students(student_id),
 room_id INT NOT NULL REFERENCES rooms(room_id),
 allocated_on DATE NOT NULL DEFAULT CURRENT_DATE,
 released_on DATE,
 status VARCHAR(10) NOT NULL CHECK(status IN('ACTIVE','ENDED')),
 CHECK((status='ACTIVE' AND released_on IS NULL) OR (status='ENDED' AND released_on IS NOT NULL)),
 CHECK(released_on IS NULL OR released_on>=allocated_on)
);
CREATE TABLE occupancy_snapshot(
 snapshot_date DATE NOT NULL,room_id INT NOT NULL REFERENCES rooms(room_id),
 occupied_beds INT NOT NULL CHECK(occupied_beds>=0),
 free_beds INT NOT NULL CHECK(free_beds>=0),
 PRIMARY KEY(snapshot_date,room_id)
);

CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INT)
RETURNS INT LANGUAGE plpgsql STABLE AS $$
DECLARE v_capacity INT;v_occupied INT;
BEGIN
 IF p_room_id IS NULL THEN RAISE EXCEPTION 'Room ID cannot be NULL'; END IF;
 SELECT capacity INTO v_capacity FROM rooms WHERE room_id=p_room_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown room ID: %',p_room_id; END IF;
 SELECT COUNT(*) INTO v_occupied FROM allocations WHERE room_id=p_room_id AND status='ACTIVE';
 RETURN v_capacity-v_occupied;
END;
$$;

CREATE OR REPLACE FUNCTION trg_allocations_enforce_rules()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_capacity INT;v_room_count INT;v_student_count INT;
BEGIN
 IF NEW.status='ACTIVE' THEN
   SELECT capacity INTO v_capacity FROM rooms WHERE room_id=NEW.room_id FOR UPDATE;
   IF NOT FOUND THEN RAISE EXCEPTION 'Unknown room ID: %',NEW.room_id; END IF;
   SELECT COUNT(*) INTO v_student_count FROM allocations
   WHERE student_id=NEW.student_id AND status='ACTIVE'
     AND allocation_id IS DISTINCT FROM NEW.allocation_id;
   IF v_student_count>0 THEN RAISE EXCEPTION 'Student already has an active allocation'; END IF;
   SELECT COUNT(*) INTO v_room_count FROM allocations
   WHERE room_id=NEW.room_id AND status='ACTIVE'
     AND allocation_id IS DISTINCT FROM NEW.allocation_id;
   IF v_room_count>=v_capacity THEN RAISE EXCEPTION 'Room % is full',NEW.room_id; END IF;
 END IF;
 RETURN NEW;
END;
$$;
CREATE TRIGGER allocations_enforce_rules BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW EXECUTE FUNCTION trg_allocations_enforce_rules();
CREATE UNIQUE INDEX uq_one_active_allocation_per_student
ON allocations(student_id) WHERE status='ACTIVE';
CREATE INDEX idx_allocations_room_active ON allocations(room_id) WHERE status='ACTIVE';

CREATE OR REPLACE PROCEDURE pr_allocate_room(p_student_id INT,p_room_id INT,p_day DATE DEFAULT CURRENT_DATE)
LANGUAGE plpgsql AS $$
BEGIN
 IF p_student_id IS NULL OR p_room_id IS NULL OR p_day IS NULL THEN RAISE EXCEPTION 'Student, room and date are required'; END IF;
 PERFORM 1 FROM students WHERE student_id=p_student_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown student ID: %',p_student_id; END IF;
 PERFORM 1 FROM rooms WHERE room_id=p_room_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown room ID: %',p_room_id; END IF;
 IF EXISTS(SELECT 1 FROM allocations WHERE student_id=p_student_id AND status='ACTIVE') THEN
   RAISE EXCEPTION 'Student already has an active allocation';
 END IF;
 IF fn_free_beds(p_room_id)<=0 THEN RAISE EXCEPTION 'Room is full'; END IF;
 INSERT INTO allocations(student_id,room_id,allocated_on,status) VALUES(p_student_id,p_room_id,p_day,'ACTIVE');
END;
$$;

CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id,r.room_number,r.capacity,
       COUNT(a.allocation_id) FILTER(WHERE a.status='ACTIVE')::INT AS occupied_beds,
       r.capacity-COUNT(a.allocation_id) FILTER(WHERE a.status='ACTIVE')::INT AS free_beds
FROM rooms r LEFT JOIN allocations a ON a.room_id=r.room_id
GROUP BY r.room_id,r.room_number,r.capacity;

CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql AS $$
BEGIN
 INSERT INTO occupancy_snapshot(snapshot_date,room_id,occupied_beds,free_beds)
 SELECT CURRENT_DATE,r.room_id,
   COUNT(a.allocation_id) FILTER(WHERE a.status='ACTIVE')::INT,
   r.capacity-COUNT(a.allocation_id) FILTER(WHERE a.status='ACTIVE')::INT
 FROM rooms r LEFT JOIN allocations a ON a.room_id=r.room_id
 GROUP BY r.room_id,r.capacity
 ON CONFLICT(snapshot_date,room_id) DO UPDATE SET
   occupied_beds=EXCLUDED.occupied_beds,free_beds=EXCLUDED.free_beds;
END;
$$;

INSERT INTO students(student_number,full_name) VALUES
('H001','Chanda'),('H002','Grace'),('H003','Kelvin'),('H004','Mutinta'),('H005','Peter');
INSERT INTO rooms(room_number,capacity) VALUES('A101',2),('A102',3),('A103',2);
CALL pr_allocate_room((SELECT student_id FROM students WHERE student_number='H001'),(SELECT room_id FROM rooms WHERE room_number='A101'));
CALL pr_allocate_room((SELECT student_id FROM students WHERE student_number='H002'),(SELECT room_id FROM rooms WHERE room_number='A101'));
CALL pr_allocate_room((SELECT student_id FROM students WHERE student_number='H003'),(SELECT room_id FROM rooms WHERE room_number='A102'));
INSERT INTO allocations(student_id,room_id,allocated_on,released_on,status)
VALUES((SELECT student_id FROM students WHERE student_number='H004'),
       (SELECT room_id FROM rooms WHERE room_number='A102'),CURRENT_DATE-10,CURRENT_DATE-2,'ENDED');
CALL pr_refresh_occupancy();
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM allocations WHERE room_id=1 AND status='ACTIVE';
