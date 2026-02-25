-- Initialize GEOINT PostGIS database
-- Creates tables for geospatial features used in the demo

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_topology;

-- Named Areas of Interest (NAIs)
CREATE TABLE IF NOT EXISTS named_areas (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    category VARCHAR(100),
    description TEXT,
    priority VARCHAR(20) DEFAULT 'normal',
    geom GEOMETRY(Polygon, 4326),
    created_at TIMESTAMP DEFAULT NOW()
);

-- Points of Interest (POIs)
CREATE TABLE IF NOT EXISTS points_of_interest (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    poi_type VARCHAR(100),
    description TEXT,
    geom GEOMETRY(Point, 4326),
    created_at TIMESTAMP DEFAULT NOW()
);

-- Detection results from AI pipeline
CREATE TABLE IF NOT EXISTS detections (
    id SERIAL PRIMARY KEY,
    source_image VARCHAR(500),
    object_class VARCHAR(100),
    confidence FLOAT,
    bbox_geom GEOMETRY(Polygon, 4326),
    detected_at TIMESTAMP DEFAULT NOW(),
    metadata JSONB
);

-- Sensor coverage areas
CREATE TABLE IF NOT EXISTS sensor_coverage (
    id SERIAL PRIMARY KEY,
    sensor_name VARCHAR(255),
    sensor_type VARCHAR(100),
    coverage_geom GEOMETRY(Polygon, 4326),
    active BOOLEAN DEFAULT true,
    updated_at TIMESTAMP DEFAULT NOW()
);

-- Movement tracks
CREATE TABLE IF NOT EXISTS tracks (
    id SERIAL PRIMARY KEY,
    track_id VARCHAR(100),
    entity_type VARCHAR(100),
    geom GEOMETRY(LineString, 4326),
    start_time TIMESTAMP,
    end_time TIMESTAMP,
    metadata JSONB
);

-- Spatial indexes
CREATE INDEX idx_named_areas_geom ON named_areas USING GIST (geom);
CREATE INDEX idx_poi_geom ON points_of_interest USING GIST (geom);
CREATE INDEX idx_detections_geom ON detections USING GIST (bbox_geom);
CREATE INDEX idx_sensor_coverage_geom ON sensor_coverage USING GIST (coverage_geom);
CREATE INDEX idx_tracks_geom ON tracks USING GIST (geom);

-- Sample data: Washington DC area demo scenario
INSERT INTO named_areas (name, category, description, priority, geom) VALUES
('Pentagon Observation Zone', 'military', 'Monitoring area around the Pentagon', 'high',
 ST_GeomFromText('POLYGON((-77.06 38.87, -77.04 38.87, -77.04 38.88, -77.06 38.88, -77.06 38.87))', 4326)),
('Reagan Airport Approach', 'aviation', 'Aircraft approach corridor', 'normal',
 ST_GeomFromText('POLYGON((-77.05 38.84, -77.03 38.84, -77.03 38.86, -77.05 38.86, -77.05 38.84))', 4326)),
('Potomac River Patrol', 'maritime', 'River patrol zone', 'normal',
 ST_GeomFromText('POLYGON((-77.06 38.85, -77.04 38.85, -77.04 38.87, -77.06 38.87, -77.06 38.85))', 4326));

INSERT INTO points_of_interest (name, poi_type, description, geom) VALUES
('Washington Monument', 'landmark', 'National landmark', ST_GeomFromText('POINT(-77.0352 38.8895)', 4326)),
('Capitol Building', 'government', 'US Capitol', ST_GeomFromText('POINT(-77.0091 38.8899)', 4326)),
('NGA HQ', 'intelligence', 'National Geospatial-Intelligence Agency', ST_GeomFromText('POINT(-77.1482 38.7509)', 4326));
