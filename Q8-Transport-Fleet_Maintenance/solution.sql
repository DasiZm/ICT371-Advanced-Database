-- ============================================================
-- Q8. TRANSPORT FLEET MAINTENANCE
-- ============================================================
DROP SCHEMA IF EXISTS ict371_q08 CASCADE;
CREATE SCHEMA ict371_q08;
SET search_path TO ict371_q08, public;

CREATE TABLE vehicles(
 vehicle_id SERIAL PRIMARY KEY,registration VARCHAR(20) NOT NULL UNIQUE,
 current_odometer INT NOT NULL CHECK(current_odometer>=0),
 last_service_odometer INT NOT NULL CHECK(last_service_odometer>=0 AND last_service_odometer<=current_odometer)
);
CREATE TABLE trips(
 trip_id SERIAL PRIMARY KEY,vehicle_id INT NOT NULL REFERENCES vehicles(vehicle_id),
 trip_on DATE NOT NULL,start_odometer INT NOT NULL CHECK(start_odometer>=0),
 end_odometer INT NOT NULL CHECK(end_odometer>start_odometer)
);
CREATE TABLE service_alerts(
 vehicle_id INT PRIMARY KEY REFERENCES vehicles(vehicle_id),
 km_since_service INT NOT NULL CHECK(km_since_service>=0),
 flagged_on DATE NOT NULL DEFAULT CURRENT_DATE
);

CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INT)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
DECLARE v_current INT;v_last INT;
BEGIN
 IF p_vehicle_id IS NULL THEN RAISE EXCEPTION 'Vehicle ID cannot be NULL'; END IF;
 SELECT current_odometer,last_service_odometer INTO v_current,v_last
 FROM vehicles WHERE vehicle_id=p_vehicle_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown vehicle ID: %',p_vehicle_id; END IF;
 RETURN v_current-v_last>=5000;
END;
$$;

CREATE OR REPLACE FUNCTION trg_trips_update_odometer()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_current INT;
BEGIN
 SELECT current_odometer INTO v_current FROM vehicles
 WHERE vehicle_id=NEW.vehicle_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown vehicle ID: %',NEW.vehicle_id; END IF;
 IF NEW.start_odometer<>v_current THEN
   RAISE EXCEPTION 'Trip must start at current odometer % (received %)',v_current,NEW.start_odometer;
 END IF;
 IF NEW.end_odometer<=NEW.start_odometer THEN RAISE EXCEPTION 'End odometer must exceed start odometer'; END IF;
 UPDATE vehicles SET current_odometer=NEW.end_odometer WHERE vehicle_id=NEW.vehicle_id;
 RETURN NEW;
END;
$$;
CREATE TRIGGER trips_update_odometer BEFORE INSERT ON trips
FOR EACH ROW EXECUTE FUNCTION trg_trips_update_odometer();

CREATE OR REPLACE PROCEDURE pr_record_trip(
 p_vehicle_id INT,p_trip_on DATE,p_start INT,p_end INT
) LANGUAGE plpgsql AS $$
BEGIN
 IF p_vehicle_id IS NULL OR p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
   RAISE EXCEPTION 'Vehicle, trip date and odometer values are required';
 END IF;
 IF p_end<=p_start THEN RAISE EXCEPTION 'End odometer must exceed start odometer'; END IF;
 PERFORM 1 FROM vehicles WHERE vehicle_id=p_vehicle_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown vehicle ID: %',p_vehicle_id; END IF;
 INSERT INTO trips(vehicle_id,trip_on,start_odometer,end_odometer)
 VALUES(p_vehicle_id,p_trip_on,p_start,p_end);
END;
$$;

CREATE OR REPLACE VIEW v_service_due AS
SELECT registration,current_odometer-last_service_odometer AS km_since_service
FROM vehicles WHERE current_odometer-last_service_odometer>=5000;

CREATE INDEX idx_trips_vehicle_date ON trips(vehicle_id,trip_on);

CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql AS $$
BEGIN
 INSERT INTO service_alerts(vehicle_id,km_since_service,flagged_on)
 SELECT vehicle_id,current_odometer-last_service_odometer,CURRENT_DATE
 FROM vehicles WHERE current_odometer-last_service_odometer>=5000
 ON CONFLICT(vehicle_id) DO UPDATE SET
 km_since_service=EXCLUDED.km_since_service,flagged_on=EXCLUDED.flagged_on;
 DELETE FROM service_alerts a WHERE NOT EXISTS(
   SELECT 1 FROM vehicles v WHERE v.vehicle_id=a.vehicle_id
   AND v.current_odometer-v.last_service_odometer>=5000);
END;
$$;

INSERT INTO vehicles(registration,current_odometer,last_service_odometer) VALUES
('BAC 1234',44000,44000),('BAJ 5678',55000,55000),('BAL 9012',29000,29000);
CALL pr_record_trip(1,CURRENT_DATE-6,44000,46000);
CALL pr_record_trip(1,CURRENT_DATE-5,46000,49200);
CALL pr_record_trip(2,CURRENT_DATE-6,55000,59000);
CALL pr_record_trip(2,CURRENT_DATE-5,59000,63000);
CALL pr_record_trip(3,CURRENT_DATE-4,29000,30000);
CALL pr_record_trip(3,CURRENT_DATE-3,30000,31000);
CALL pr_refresh_service_alerts();
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM trips WHERE vehicle_id=1
AND trip_on BETWEEN CURRENT_DATE-30 AND CURRENT_DATE;
