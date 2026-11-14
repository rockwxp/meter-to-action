-- Run with: duckdb -no-agent -bail -readonly database/meter_to_action.duckdb < sql/quality/ods/001_check_source_tables.sql
-- All working relations are temporary and disappear when the connection closes.
-- The reference population is customer IDs 1..35725 for the supplied 12-month snapshot.
BEGIN TRANSACTION;

SELECT count(*) AS source_rows, count(DISTINCT customer_number) AS observed_customers,
       count(*) FILTER (WHERE customer_number IS NULL OR customer_number NOT BETWEEN 1 AND 35725
           OR usage_date IS NULL OR usage_date NOT BETWEEN DATE '2025-09-01' AND DATE '2026-08-31'
           OR hour_ending IS NULL OR hour_ending NOT BETWEEN 1 AND 24) AS invalid_key_rows
FROM ods.ami_hourly;

-- A 24-bit mask per customer-day counts distinct hours without sorting all source rows.
CREATE TEMP TABLE audit_days AS
SELECT customer_number, usage_date, count(*) AS source_rows,
       bit_count(bit_or(1::BIGINT << (hour_ending - 1))) AS observed_hours,
       coalesce(bit_count(bit_or(1::BIGINT << (hour_ending - 1))
           FILTER (WHERE is_complete_hour = 1)), 0) AS complete_hours
FROM ods.ami_hourly
WHERE customer_number BETWEEN 1 AND 35725 AND hour_ending BETWEEN 1 AND 24
  AND usage_date BETWEEN DATE '2025-09-01' AND DATE '2026-08-31'
GROUP BY customer_number, usage_date;

CREATE TEMP TABLE audit_duplicate_hours AS
SELECT a.customer_number, a.usage_date, a.hour_ending, count(*) AS occurrences,
       count(DISTINCT (a.day_type, a.hourly_kwh, a.interval_count, a.interval_type, a.is_complete_hour))
           AS payload_versions
FROM ods.ami_hourly a
JOIN (SELECT customer_number, usage_date FROM audit_days WHERE source_rows > observed_hours) d
USING (customer_number, usage_date)
WHERE a.hour_ending BETWEEN 1 AND 24
GROUP BY a.customer_number, a.usage_date, a.hour_ending
HAVING count(*) > 1;

SELECT count(*) AS duplicate_keys, coalesce(sum(occurrences - 1), 0) AS excess_rows,
       count(*) FILTER (WHERE payload_versions > 1) AS conflicting_keys
FROM audit_duplicate_hours;

CREATE TEMP TABLE audit_customer_month AS
WITH months AS (
    SELECT m::DATE AS month_start, day(last_day(m)) * 24 AS expected_hours
    FROM generate_series(DATE '2025-09-01', DATE '2026-08-01', INTERVAL '1 month') t(m)
), monthly AS (
    SELECT customer_number, date_trunc('month', usage_date)::DATE AS month_start,
           sum(observed_hours)::INTEGER AS observed_hours,
           sum(complete_hours)::INTEGER AS complete_hours
    FROM audit_days GROUP BY ALL
)
SELECT c.customer_number, m.month_start, m.expected_hours,
       coalesce(a.observed_hours, 0) AS observed_hours, coalesce(a.complete_hours, 0) AS complete_hours,
       coalesce(a.observed_hours, 0)::DOUBLE / m.expected_hours AS coverage
FROM range(1, 35726) c(customer_number) CROSS JOIN months m
LEFT JOIN monthly a USING (customer_number, month_start);

-- For individual results in the same session: SELECT * FROM audit_customer_month WHERE customer_number = 1;
SELECT month_start, max(expected_hours) AS expected_hours,
       round(100 * avg(coverage), 3) AS coverage_pct,
       round(100 * sum(complete_hours) / sum(expected_hours), 3) AS complete_pct,
       count(*) FILTER (WHERE coverage = 1) AS full_customers,
       count(*) FILTER (WHERE coverage > 0 AND coverage < 1) AS partial_customers,
       count(*) FILTER (WHERE coverage = 0) AS absent_customers
FROM audit_customer_month GROUP BY month_start ORDER BY month_start;

SELECT observed, count(*) AS customers
FROM (SELECT customer_number, sum(observed_hours) AS observed FROM audit_customer_month GROUP BY customer_number)
GROUP BY observed ORDER BY customers DESC, observed LIMIT 10;

SELECT count(*) AS weather_rows, count(DISTINCT (observation_date, observation_time)) AS distinct_times,
       count(*) FILTER (WHERE observation_date IS NULL OR observation_time IS NULL) AS missing_time,
       count(*) - count(temp) AS missing_temp, count(*) - count(humidity) AS missing_humidity,
       count(*) - count(windspeed) AS missing_windspeed,
       count(*) FILTER (WHERE temp IS NULL OR humidity IS NULL OR windspeed IS NULL) AS missing_any,
       count(*) FILTER (WHERE temp IS NULL AND humidity IS NULL AND windspeed IS NULL) AS missing_all
FROM ods.weather_hourly;

SELECT count(*) AS missing_weather_hours
FROM generate_series(TIMESTAMP '2025-09-01 00:00:00', TIMESTAMP '2026-08-31 23:00:00', INTERVAL '1 hour') t(ts)
ANTI JOIN ods.weather_hourly w ON t.ts = w.observation_date + w.observation_time;

SELECT * FROM ods.weather_hourly
QUALIFY count(*) OVER (PARTITION BY observation_date, observation_time) > 1
ORDER BY observation_date, observation_time, temp, humidity, windspeed;

WITH devices AS (
    SELECT 'EV' AS device, customer_number FROM ods.ev_customers UNION ALL
    SELECT 'HP', customer_number FROM ods.hp_customers UNION ALL
    SELECT 'PV', customer_number FROM ods.pv_customers
), customers AS (
    SELECT DISTINCT customer_number FROM ods.ami_hourly
)
SELECT device, count(*) AS listed, count(c.customer_number) AS matched,
       count(*) - count(c.customer_number) AS unmatched,
       string_agg(d.customer_number::VARCHAR, ', ' ORDER BY d.customer_number)
           FILTER (WHERE c.customer_number IS NULL) AS unmatched_ids
FROM devices d LEFT JOIN customers c USING (customer_number)
GROUP BY device ORDER BY device;
COMMIT;
