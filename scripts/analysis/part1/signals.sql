USE validation;
-- Consecutive-hour tests use calendar timestamps, including midnight crossings.
CREATE TEMP TABLE extra_ev AS
WITH h AS (
 SELECT customer_number id, usage_date d, hour_ending he, hourly_kwh k,
        usage_date + (hour_ending-1)*INTERVAL '1 hour' ts
 FROM ods.ami_hourly
), adjacent AS (
 SELECT *, lag(k) OVER w prev,lead(k) OVER w nxt,lag(ts) OVER w before_ts,lead(ts) OVER w after_ts
 FROM h WINDOW w AS (PARTITION BY id ORDER BY ts)
), days AS (
 SELECT id,d, max(k) peak,
 max((k-prev>=3 AND nxt-prev>=2.5 AND ts-before_ts=INTERVAL '1 hour' AND after_ts-ts=INTERVAL '1 hour')::INT) step3,
 max((k-prev>=5 AND nxt-prev>=4 AND ts-before_ts=INTERVAL '1 hour' AND after_ts-ts=INTERVAL '1 hour')::INT) step5,
 max((he BETWEEN 17 AND 24 AND k-prev>=3 AND nxt-prev>=2.5 AND ts-before_ts=INTERVAL '1 hour' AND after_ts-ts=INTERVAL '1 hour')::INT) evening_step,
 max((he<=7 AND k-prev>=3 AND nxt-prev>=2.5 AND ts-before_ts=INTERVAL '1 hour' AND after_ts-ts=INTERVAL '1 hour')::INT) night_step,
 max((k>=3.3 AND nxt>=3.3 AND abs(k-nxt)<0.7 AND after_ts-ts=INTERVAL '1 hour')::INT) plateau_any
 FROM adjacent GROUP BY id,d
)
SELECT id,avg(step3) step3,avg(step5) step5,avg(evening_step) evening_step,avg(night_step) night_step,
 avg(plateau_any) plateau_any,quantile_cont(peak,0.9) peak90,quantile_cont(peak,0.5) peak50
FROM days GROUP BY id;

CREATE TEMP TABLE extra_hp AS
WITH wx AS (
 SELECT observation_date d,avg(temp) t FROM (
 SELECT observation_date,observation_time,avg(temp) temp FROM ods.weather_hourly GROUP BY ALL
 ) GROUP BY d
)
SELECT id,regr_slope(mean_kw,t) FILTER(WHERE t<55) winter_slope,
 corr(mean_kw,t) FILTER(WHERE t<55) winter_corr,
 regr_slope(mean_kw,t) FILTER(WHERE t>65) summer_slope,
 avg(mean_kw) FILTER(WHERE t BETWEEN 35 AND 50)-avg(mean_kw) FILTER(WHERE t BETWEEN 55 AND 65) shoulder_heat,
 avg(low_kw) FILTER(WHERE t<35)-avg(low_kw) FILTER(WHERE t BETWEEN 55 AND 65) cold_base,
 avg(night_kwh/6) FILTER(WHERE t<35)-avg(night_kwh/6) FILTER(WHERE t BETWEEN 55 AND 65) cold_night
FROM intermediate.daily JOIN wx USING(d) GROUP BY id;
