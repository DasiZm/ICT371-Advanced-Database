-- ============================================================
-- ICT371 - Q8: Transport Fleet Maintenance
-- Service due when >= 5000 km since last service.
-- Each new trip must start at vehicle's current odometer.
-- ============================================================

DROP VIEW IF EXISTS v_service_due;
DROP TABLE IF EXISTS service_alerts;
DROP TABLE IF EXISTS trips;
DROP TABLE IF EXISTS vehicles CASCADE;
DROP FUNCTION IF EXISTS fn_service_due(INT);
DROP FUNCTION IF EXISTS pr_record_trip(INT, DATE, INT, INT);
DROP FUNCTION IF EXISTS pr_refresh_service_alerts();

-- ------------------------------------------------------------
-- (a) Tables
-- ------------------------------------------------------------
CREATE TABLE vehicles (
    vehicle_id           SERIAL PRIMARY KEY,
    registration         VARCHAR(20) NOT NULL UNIQUE,
    current_odometer     INT NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer INT NOT NULL CHECK (last_service_odometer >= 0),
    CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id        SERIAL PRIMARY KEY,
    vehicle_id     INT NOT NULL REFERENCES vehicles(vehicle_id) ON DELETE RESTRICT,
    trip_on        DATE NOT NULL,
    start_odometer INT NOT NULL CHECK (start_odometer >= 0),
    end_odometer   INT NOT NULL CHECK (end_odometer >= 0)
);

CREATE TABLE service_alerts (
    vehicle_id      INT PRIMARY KEY REFERENCES vehicles(vehicle_id) ON DELETE CASCADE,
    km_since_service INT NOT NULL CHECK (km_since_service >= 0),
    flagged_on      DATE NOT NULL DEFAULT CURRENT_DATE
);

-- ------------------------------------------------------------
-- (b) Function: fn_service_due
-- TRUE if current - last_service >= 5000. Reject unknown vehicle.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INT)
RETURNS BOOLEAN AS $$
DECLARE
    v_current INT;
    v_last    INT;
BEGIN
    IF p_vehicle_id IS NULL THEN
        RAISE EXCEPTION 'Vehicle ID cannot be NULL';
    END IF;

    SELECT current_odometer, last_service_odometer
    INTO v_current, v_last
    FROM vehicles WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    RETURN (v_current - v_last) >= 5000;
END;
$$ LANGUAGE plpgsql STABLE;

-- ------------------------------------------------------------
-- (c) Procedure: pr_record_trip 
-- Validate vehicle, require end > start. Insert trip.
-- DO NOT update vehicle odometer here - trigger does it.
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_record_trip(p_vehicle_id INT, p_trip_on DATE, p_start INT, p_end INT)
AS $$
BEGIN
    IF p_vehicle_id IS NULL OR p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
        RAISE EXCEPTION 'Vehicle, trip_on, start and end cannot be NULL';
    END IF;

    PERFORM 1 FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    IF p_end <= p_start THEN
        RAISE EXCEPTION 'end_odometer % must be greater than start_odometer %', p_end, p_start;
    END IF;

    -- Trigger verifies start = current_odometer and updates vehicle exactly once
    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$ LANGUAGE plpgsql;

-- ------------------------------------------------------------
-- (d) Trigger: BEFORE INSERT on trips 
-- Verify start = current, reject invalid mileage, update current to end exactly once
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_trips_update_odometer()
RETURNS TRIGGER AS $$
DECLARE
    v_current INT;
BEGIN
    SELECT current_odometer INTO v_current
    FROM vehicles WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', NEW.vehicle_id;
    END IF;

    IF NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: end % must be > start %', NEW.end_odometer, NEW.start_odometer;
    END IF;

    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'Trip must start at current odometer % for vehicle %, got %',
            v_current, NEW.vehicle_id, NEW.start_odometer;
    END IF;

    -- Update exactly once, inside trigger only
    UPDATE vehicles SET current_odometer = NEW.end_odometer
    WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_trips_update_odometer ON trips;
CREATE TRIGGER trg_trips_update_odometer
BEFORE INSERT ON trips
FOR EACH ROW EXECUTE FUNCTION trg_trips_update_odometer();

-- ------------------------------------------------------------
-- (e) View: v_service_due 
-- Vehicles currently meeting threshold
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_service_due AS
SELECT v.registration,
       (v.current_odometer - v.last_service_odometer) AS km_since_service
FROM vehicles v
WHERE (v.current_odometer - v.last_service_odometer) >= 5000;

-- ------------------------------------------------------------
-- (f) Index 
-- One vehicle's trips within a trip_on date range
-- ------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_trips_vehicle_trip_on
ON trips (vehicle_id, trip_on);

-- Matching query + EXPLAIN:
-- EXPLAIN ANALYZE
-- SELECT * FROM trips
-- WHERE vehicle_id = 1 AND trip_on BETWEEN '2026-11-01' AND '2026-11-30';

-- Justification: vehicle_id first for equality, trip_on second for range.
-- Lets Postgres seek to that vehicle then scan only its dates.

-- ------------------------------------------------------------
-- (g) Scheduled Job: pr_refresh_service_alerts 
-- Insert/update one alert per due vehicle, DELETE alert when no longer due
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
AS $$
BEGIN
    -- Insert or update due vehicles
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id,
           (current_odometer - last_service_odometer),
           CURRENT_DATE
    FROM vehicles
    WHERE (current_odometer - last_service_odometer) >= 5000
    ON CONFLICT (vehicle_id) DO UPDATE
    SET km_since_service = EXCLUDED.km_since_service,
        flagged_on = EXCLUDED.flagged_on;

    -- Remove alerts for vehicles no longer due (e.g. after service)
    DELETE FROM service_alerts
    WHERE vehicle_id NOT IN (
        SELECT vehicle_id FROM vehicles
        WHERE (current_odometer - last_service_odometer) >= 5000
    );
END;
$$ LANGUAGE plpgsql;

-- Schedule every Monday at 06:00 (requires pg_cron)
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
-- SELECT cron.schedule('q8-refresh-service-alerts', '0 6 * * 1',
--   $$ CALL pr_refresh_service_alerts(); $$);

-- ------------------------------------------------------------
-- Seed Data: 3 vehicles, 6 trips VIA PROCEDURE after trigger installed
-- ------------------------------------------------------------
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
('BAC 1234', 48000, 44000), -- 4000 km since service - NOT due yet
('BAJ 5678', 62000, 55000), -- 7000 km - ALREADY due
('BAL 9012', 30000, 29000); -- 1000 km - NOT due

-- Trips through procedure - trigger updates odometer automatically
-- V1: 48000 -> 48500 (now 4500 since service, still not due)
CALL pr_record_trip(1, '2026-11-20', 48000, 48500);
-- V1: 48500 -> 49200 (now 5200 since service, NOW due)
CALL pr_record_trip(1, '2026-11-21', 48500, 49200);
-- V2: 62000 -> 62500 (still due)
CALL pr_record_trip(2, '2026-11-20', 62000, 62500);
-- V2: 62500 -> 63000
CALL pr_record_trip(2, '2026-11-21', 62500, 63000);
-- V3: 30000 -> 30500
CALL pr_record_trip(3, '2026-11-20', 30000, 30500);
-- V3: 30500 -> 31000 (now 2000 since service, not due)
CALL pr_record_trip(3, '2026-11-21', 30500, 31000);

-- ------------------------------------------------------------
-- Verification
-- ------------------------------------------------------------
-- SELECT * FROM vehicles; -- V1 current 49200, V2 63000, V3 31000
-- SELECT * FROM trips ORDER BY trip_id;
-- SELECT fn_service_due(1); -- TRUE (5200)
-- SELECT fn_service_due(3); -- FALSE (2000)
-- SELECT * FROM v_service_due; -- V1 + V2
-- CALL pr_refresh_service_alerts();
-- SELECT * FROM service_alerts;
-- -- Simulate service: V1 serviced at current odometer, alert must disappear on next refresh
-- -- UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 1;
-- -- CALL pr_refresh_service_alerts();
-- -- SELECT * FROM service_alerts; -- V1 gone
-- -- Must fail - wrong start odometer:
-- -- CALL pr_record_trip(1, '2026-11-22', 10000, 10100);
-- -- Must fail - end <= start:
-- -- CALL pr_record_trip(1, '2026-11-22', 49200, 49200);
