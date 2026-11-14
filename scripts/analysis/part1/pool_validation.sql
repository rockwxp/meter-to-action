-- Run with an in-memory connection, from the repository root.
ATTACH 'database/meter_to_action.duckdb' AS odsdb (READ_ONLY);
ATTACH 'database/analysis_results.duckdb' AS prior (READ_ONLY);
SET threads=12;
SET memory_limit='42GiB';

-- Only complete observed days are used for timer assessment. Other hours remain in ODS.
CREATE TEMP TABLE eligible_days AS
SELECT a.id,d,month(d) BETWEEN 5 AND 9 AS warm,
       date_diff('week',DATE '2025-09-01',time_bucket(INTERVAL '1 week',d))%3 AS block,
       pump_pairs>=3 AS old_event
FROM prior.daily a JOIN prior.classification c USING(id)
WHERE c.sufficient_history AND n=24 AND month(d) IN (5,6,7,8,9,12,1,2);

-- Segment the full day before filtering daytime starts. Require a visible upward
-- step before the first plateau hour and a downward step after the last hour.
CREATE TEMP TABLE runs AS
WITH h AS (
 SELECT customer_number id,usage_date d,hour_ending he,hourly_kwh k,
    lag(hourly_kwh) OVER w prev,lead(hourly_kwh) OVER w nxt
 FROM odsdb.ods.ami_hourly JOIN eligible_days e ON e.id=customer_number AND e.d=usage_date
 WINDOW w AS (PARTITION BY customer_number,usage_date ORDER BY hour_ending)
), in_band AS (
 SELECT *,sum(CASE WHEN prev BETWEEN 0.8 AND 3 AND abs(k-prev)<0.15 THEN 0 ELSE 1 END)
 OVER (PARTITION BY id,d ORDER BY he) grp
 FROM h WHERE k BETWEEN 0.8 AND 3
), islands AS (
 SELECT id,d,min(he)-1 start_h,max(he) stop_h,count(*) duration,
 arg_min(k-prev,he) rise,arg_max(k-nxt,he) fall
 FROM in_band GROUP BY id,d,grp
)
SELECT * FROM islands WHERE duration>=2 AND start_h BETWEEN 5 AND 17 AND stop_h<=23
AND stop_h-start_h=duration AND rise>=0.30 AND fall>=0.30
QUALIFY row_number() OVER (PARTITION BY id,d ORDER BY duration DESC,start_h)=1;

-- Derive typical clock times on training weeks only, for each minimum duration.
CREATE TEMP TABLE day_stats AS
SELECT e.*,r.start_h,r.stop_h,r.duration FROM eligible_days e LEFT JOIN runs r USING(id,d);

CREATE TEMP TABLE centers AS
SELECT id,fold,hours,quantile_disc(start_h,0.5) center_start,quantile_disc(stop_h,0.5) center_stop
FROM day_stats CROSS JOIN range(3) f(fold) CROSS JOIN (VALUES (2),(3),(4)) h(hours)
WHERE block<>fold AND warm AND duration>=hours GROUP BY ALL;

CREATE TEMP TABLE rates AS
WITH stats AS (
 SELECT ds.id,fold,hours,tol,block=fold AS test, warm,count(*) n,
 avg(old_event::INT) old_frequency,
 avg(coalesce((duration>=hours AND abs(start_h-center_start)<=tol AND abs(stop_h-center_stop)<=tol)::INT,0)) timed_frequency
 FROM day_stats ds CROSS JOIN range(3) f(fold) CROSS JOIN (VALUES (2),(3),(4)) h(hours)
 CROSS JOIN (VALUES (0),(1),(2)) t(tol) LEFT JOIN centers USING(id,fold,hours)
 GROUP BY ALL
)
SELECT id,fold,hours,tol,test,
 max(old_frequency) FILTER(WHERE warm)-max(old_frequency) FILTER(WHERE NOT warm) old_delta,
 max(timed_frequency) FILTER(WHERE warm)-max(timed_frequency) FILTER(WHERE NOT warm) timed_delta
FROM stats GROUP BY ALL HAVING max(n) FILTER(WHERE warm)>=14 AND max(n) FILTER(WHERE NOT warm)>=14;

CREATE TEMP TABLE pairs AS
SELECT a.id,a.fold,a.hours,a.tol,a.old_delta AS old_train,b.old_delta AS old_test,
       a.timed_delta AS train,b.timed_delta AS test
FROM rates a JOIN rates b USING(id,fold,hours,tol) WHERE NOT a.test AND b.test;

SELECT hours,tol,cut,fold,count(*) evaluable,countif(train>=cut) selected,
 countif(train>=cut AND test>=cut) repeated
FROM pairs CROSS JOIN (VALUES (0.20),(0.30),(0.40)) c(cut)
WHERE (tol=1 AND cut=0.30) OR (hours=3 AND cut=0.30) OR (hours=3 AND tol=1)
GROUP BY ALL ORDER BY hours,tol,cut,fold;

SELECT fold,countif(old_train>=0.3) old_selected,countif(old_train>=0.3 AND old_test>=0.3) old_repeated,
countif(old_train>=0.3 AND train>=0.3) old_with_timer,
countif(old_train>=0.3 AND train>=0.3 AND test>=0.3) old_timer_repeated
FROM pairs WHERE hours=3 AND tol=1 GROUP BY fold ORDER BY fold;

-- Count distinct households across folds and show their training clock templates.
SELECT p.id,count(*) selected_folds,countif(test>=0.30) repeated_folds,
 min(center_start) earliest_start,max(center_start) latest_start,
 min(center_stop) earliest_stop,max(center_stop) latest_stop
FROM pairs p JOIN centers c USING(id,fold,hours)
WHERE hours=3 AND tol=1 AND train>=0.30 GROUP BY p.id ORDER BY repeated_folds DESC,p.id;
