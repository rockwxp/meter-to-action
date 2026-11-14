-- DuckDB operational data store (ODS)
-- Preserve duplicate AMI and weather observations. Validate business keys after loading.
BEGIN TRANSACTION;

CREATE SCHEMA IF NOT EXISTS ods;
CREATE SCHEMA IF NOT EXISTS intermediate;
CREATE SCHEMA IF NOT EXISTS validation;
CREATE SCHEMA IF NOT EXISTS part1;
CREATE SCHEMA IF NOT EXISTS part2;
CREATE SCHEMA IF NOT EXISTS part3;

-- Each row represents one hourly usage record for one customer.
CREATE TABLE IF NOT EXISTS ods.ami_hourly (
    customer_number  INTEGER,
    usage_date       DATE,
    hour_ending      SMALLINT,  -- Hour ending (1-24). Hour 1 covers 00:00 to 01:00.
    day_type         VARCHAR,   -- Weekday / Weekend
    hourly_kwh       DOUBLE,    -- Energy consumed during the hour (kWh)
    interval_count   SMALLINT,  -- Number of meter readings included in the hour
    interval_type    VARCHAR,   -- Meter reading interval, e.g. 15-min
    is_complete_hour SMALLINT   -- 1 = complete, 0 = incomplete
);

-- Each row represents one weather observation. Timestamps can repeat.
CREATE TABLE IF NOT EXISTS ods.weather_hourly (
    observation_date DATE,
    observation_time TIME,
    temp             DOUBLE,    -- Outdoor temperature (degrees Fahrenheit)
    humidity         DOUBLE,    -- Relative humidity (%)
    windspeed        DOUBLE     -- Wind speed (mph)
);

-- EV and HP lists contain samples of likely owners. The PV list includes all known solar customers.
CREATE TABLE IF NOT EXISTS ods.ev_customers (
    customer_number INTEGER PRIMARY KEY
);

CREATE TABLE IF NOT EXISTS ods.hp_customers (
    customer_number INTEGER PRIMARY KEY
);

CREATE TABLE IF NOT EXISTS ods.pv_customers (
    customer_number INTEGER PRIMARY KEY
);

COMMIT;
