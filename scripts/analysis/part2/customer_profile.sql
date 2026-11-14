USE part2;
-- Build inside segment.sql's transaction, with the ODS attached as raw.
CREATE OR REPLACE TABLE customer_profile AS
WITH peak AS (
    SELECT DISTINCT d, he, system_kw
    FROM peak_contributions ORDER BY system_kw DESC, d, he LIMIT 1
), demand AS (
    SELECT a.customer_number, a.hourly_kwh
    FROM ods.ami_hourly a JOIN peak p ON a.usage_date=p.d AND a.hour_ending=p.he
)
SELECT s.id AS customer_id, s.segment,
       round(s.night_kw, 2) AS night_kw, round(s.midday_kw, 2) AS midday_kw,
       round(s.evening_kw, 2) AS evening_kw, d.hourly_kwh AS at_peak_kw
FROM customer_segments s LEFT JOIN demand d ON s.id=d.customer_number;

SELECT CASE WHEN count(*)=35725 AND count(DISTINCT customer_id)=count(*)
            AND abs(sum(at_peak_kw)-(SELECT max(system_kw) FROM peak_contributions))<0.001
            THEN true ELSE error('Customer profile reconciliation failed') END AS verified
FROM customer_profile;
