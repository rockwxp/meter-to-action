USE intermediate;
-- Weather enters as a lookup at interval start. Aggregate only the lookup to maintain join cardinality.
CREATE OR REPLACE TEMP TABLE wx AS
SELECT observation_date d, hour(observation_time)+1 he, avg(temp) temp
FROM ods.weather_hourly GROUP BY ALL;

-- Use daily profiles to find repeated overnight plateaus and scheduled daytime loads.
CREATE OR REPLACE TABLE daily AS
WITH h AS (
    SELECT customer_number id, usage_date d, hour_ending he, hourly_kwh k,
           lag(hourly_kwh) OVER w prev, lag(hour_ending) OVER w prev_he
    FROM ods.ami_hourly
    WINDOW w AS (PARTITION BY customer_number, usage_date ORDER BY hour_ending)
)
SELECT id,d,count(k) n, sum(k) energy, avg(k) mean_kw, min(k) low_kw,
       avg(k) FILTER (WHERE he BETWEEN 11 AND 15) midday_kw,
       avg(k) FILTER (WHERE he BETWEEN 18 AND 21) evening_kw,
       sum(k) FILTER (WHERE he <= 6) night_kwh,
       count(*) FILTER (WHERE he<=7 AND he=prev_he+1 AND k>=3.3 AND prev>=3.3 AND abs(k-prev)<0.7) l2_pairs,
       count(*) FILTER (WHERE he<=7 AND he=prev_he+1 AND k BETWEEN 1.2 AND 2.6 AND prev BETWEEN 1.2 AND 2.6 AND abs(k-prev)<0.22) l1_pairs,
       count(*) FILTER (WHERE he BETWEEN 7 AND 10 AND he=prev_he+1 AND k-prev>=1.5) morning_steps,
       count(*) FILTER (WHERE he BETWEEN 10 AND 17 AND he=prev_he+1 AND k BETWEEN 0.8 AND 3 AND abs(k-prev)<0.15) pump_pairs,
       count(*) FILTER (WHERE he<=7 AND he=prev_he+1 AND k-prev BETWEEN 2 AND 5) night_steps
FROM h GROUP BY id,d;

CREATE OR REPLACE TABLE features AS
WITH temp_day AS (SELECT d,avg(temp) t FROM wx GROUP BY d),
stats AS (
 SELECT id, count(*) AS days,sum(n) AS hours, sum(energy) measured_kwh, sum(night_kwh)/nullif(sum(energy),0) night_share,
 avg(evening_kw) evening_kw, avg(midday_kw) midday_kw, avg(low_kw) base_kw,
 avg(mean_kw) FILTER (WHERE t BETWEEN 55 AND 65) mild,
 avg(mean_kw) FILTER (WHERE t>=20 AND t<35) moderate_cold,
 avg(mean_kw) FILTER (WHERE t<35) cold, avg(mean_kw) FILTER (WHERE t<20) very_cold,
 avg(mean_kw) FILTER (WHERE t>75) hot,
 avg((l2_pairs>=2)::INT) l2, avg((l1_pairs>=3)::INT) l1,
 avg((morning_steps>0)::INT) morning, avg((night_steps>0)::INT) cycling,
 avg((pump_pairs>=3)::INT) FILTER (WHERE month(d) BETWEEN 5 AND 9) summer_pump,
 avg((pump_pairs>=3)::INT) FILTER (WHERE month(d) IN (12,1,2)) winter_pump,
 avg(mean_kw) FILTER (WHERE month(d) IN (12,1,2)) winter,
 avg(mean_kw) FILTER (WHERE month(d) IN (6,7,8)) summer
 FROM daily LEFT JOIN temp_day USING(d) GROUP BY id)
SELECT *, cold-mild heating_kw, hot-mild cooling_kw, very_cold-cold extreme_kw,
       greatest(coalesce(l2,0),coalesce(l1,0)*0.5) ev_score,
       heating_kw+0.5*least(greatest(cooling_kw,0),2) hp_score
FROM stats;

-- Thresholds are screening assumptions. No reference labels are used to fit the rules.
CREATE OR REPLACE TABLE classification AS
SELECT f.id, f.hours, f.hours>=4380 AS sufficient_history,
 e.customer_number IS NOT NULL ev_reference, h.customer_number IS NOT NULL hp_reference,
 p.customer_number IS NOT NULL known_pv,
 CASE WHEN hours>=4380 THEN l2>=0.08 END ev_l2_signature,
 CASE WHEN hours>=4380 THEN l1>=0.20 AND l2<0.08 END ev_l1_signature,
 CASE WHEN hours>=4380 THEN cooling_kw>=0.45 END ac_signature,
 CASE WHEN hours>=4380 THEN heating_kw>=0.65 AND cooling_kw>=0.35 END hp_signature,
 CASE WHEN hours>=4380 THEN moderate_cold-mild>=1.20 AND very_cold-moderate_cold>=0.30 END strong_electric_heating_candidate,
 CASE WHEN hours>=4380 THEN morning>=0.30 END water_heater_signature,
 CASE WHEN hours>=4380 THEN summer_pump-winter_pump>=0.30 END pool_signature,
 CASE WHEN hours>=4380 THEN cycling>=0.28 AND base_kw>=0.25 END hot_tub_signature,
 CASE WHEN hours>=4380 AND p.customer_number IS NOT NULL THEN midday_kw<0.35 AND evening_kw<0.65 END pv_storage_signature,
 ev_score,hp_score
FROM features f LEFT JOIN ods.ev_customers e ON e.customer_number=f.id
LEFT JOIN ods.hp_customers h ON h.customer_number=f.id
LEFT JOIN ods.pv_customers p ON p.customer_number=f.id;

CREATE OR REPLACE TABLE segments AS
SELECT id, CASE WHEN hours<4380 THEN 'Limited history'
 WHEN night_share>=0.34 THEN 'Night-heavy'
 WHEN winter>=1.65*summer AND heating_kw>=0.65 THEN 'Winter-sensitive'
 WHEN summer>=1.65*winter AND cooling_kw>=0.45 THEN 'Summer-sensitive'
 WHEN evening_kw>=1.8 THEN 'High evening demand'
 ELSE 'Other observed profiles' END segment
FROM features;
