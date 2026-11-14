-- From repository root: duckdb -bail database/part1_final.duckdb < scripts/analysis/part1/finish.sql
-- Reuse the validated timer splits, ODS attachment and baseline attachment.
.read scripts/analysis/part1/pool_validation.sql
ATTACH 'database/part1_validation.duckdb' AS validated (READ_ONLY);
BEGIN TRANSACTION;

CREATE TEMP TABLE weather_days AS
SELECT d,avg(t) t FROM (
 SELECT observation_date d,observation_time,avg(temp) t FROM odsdb.ods.weather_hourly GROUP BY ALL
) GROUP BY d;

-- Compare morning pulses to a four-hour afternoon control window.
-- A pulse rises and drops back by at least half the rise in the following hour.
CREATE TEMP TABLE events AS
WITH h AS (
 SELECT customer_number id,usage_date d,hour_ending he,hourly_kwh k,
 lag(hourly_kwh) OVER w prev,lead(hourly_kwh) OVER w nxt
 FROM odsdb.ods.ami_hourly
 WINDOW w AS (PARTITION BY customer_number,usage_date ORDER BY hour_ending)
), daily_events AS (
 SELECT id,d,
 countif(he BETWEEN 7 AND 10 AND k-prev>=1.5 AND k-nxt>=(k-prev)*0.5)>0 morning_pulse,
 countif(he BETWEEN 13 AND 16 AND k-prev>=1.5 AND k-nxt>=(k-prev)*0.5)>0 afternoon_pulse,
 countif(he BETWEEN 2 AND 7 AND k-prev BETWEEN 2 AND 5 AND k-nxt>=(k-prev)*0.5)>0 night_pulse,
 avg(k) FILTER(WHERE he BETWEEN 22 AND 24) late_kw
 FROM h GROUP BY id,d HAVING count(k)=24
)
SELECT e.*,t,low_kw,midday_kw,evening_kw,night_kwh/6 night_kw,mean_kw,
 date_diff('week',DATE '2025-09-01',time_bucket(INTERVAL '1 week',d))%3 block,
 morning_steps>0 old_morning,night_steps>0 old_night
FROM daily_events e JOIN prior.daily USING(id,d) LEFT JOIN weather_days USING(d)
JOIN prior.classification c USING(id) WHERE c.sufficient_history;

CREATE TEMP TABLE rates_final AS
SELECT id,fold,block=fold test,count(*) days_used,
 avg(old_morning::INT) morning,avg(old_night::INT) night,avg(low_kw) base,
 avg(morning_pulse::INT)-avg(afternoon_pulse::INT) morning_excess,
 avg(morning_pulse::INT) FILTER(WHERE t>=55) warm_pulse,
 avg(night_pulse::INT) FILTER(WHERE t<35)-avg(night_pulse::INT) FILTER(WHERE t BETWEEN 55 AND 65) cold_excess,
 avg(night_pulse::INT) FILTER(WHERE t BETWEEN 55 AND 65) mild_night,
 avg(midday_kw) mid,avg(evening_kw) eve,avg(night_kw) overnight,
 avg(late_kw-evening_kw) rebound
FROM events CROSS JOIN range(3) f(fold) GROUP BY ALL HAVING count(*)>=28;

-- The peer is another known PV household matched on training-only overnight load.
-- Evaluate the candidate and the same peer on common dates within each split.
CREATE TEMP TABLE pv_pairs AS
SELECT a.id,b.id peer,a.fold FROM rates_final a
JOIN rates_final b ON a.fold=b.fold AND a.id<>b.id AND NOT b.test
JOIN prior.classification ca ON a.id=ca.id AND ca.known_pv
JOIN prior.classification cb ON b.id=cb.id AND cb.known_pv
WHERE NOT a.test AND a.mid<0.35 AND a.eve<0.65 AND NOT (b.mid<0.35 AND b.eve<0.65)
QUALIFY row_number() OVER(PARTITION BY a.id,a.fold ORDER BY abs(a.overnight-b.overnight),b.id)=1;

CREATE TEMP TABLE matched AS
SELECT p.id,p.fold,a.block=p.fold test,count(*) shared_days,avg(b.evening_kw-a.evening_kw) eve_gap,
 avg((a.late_kw-a.evening_kw)-(b.late_kw-b.evening_kw)) rebound_gap
FROM pv_pairs p JOIN events a ON a.id=p.id JOIN events b ON b.id=p.peer AND b.d=a.d
GROUP BY ALL HAVING count(*)>=28;

CREATE OR REPLACE TABLE appliance_holdout AS
SELECT r.id,r.fold,r.test,label,hit FROM rates_final r JOIN prior.classification c USING(id)
LEFT JOIN matched m USING(id,fold,test),
LATERAL (VALUES
 ('Water heater: baseline', morning>=0.30),
 ('Water heater: pulse', morning>=0.30 AND morning_excess>=0.10 AND warm_pulse>=0.15),
 ('Hot tub: baseline',night>=0.28 AND base>=0.25),
 ('Hot tub: cold cycling',night>=0.28 AND base>=0.25 AND cold_excess>=0.10 AND mild_night>=0.05),
 ('PV storage: baseline',CASE WHEN known_pv THEN mid<0.35 AND eve<0.65 END),
 ('PV storage: matched rebound',CASE WHEN known_pv AND shared_days>=28 THEN mid<0.35 AND eve<0.65 AND eve_gap>=0.20 AND rebound_gap>=0.15 END)
) rules(label,hit);

CREATE OR REPLACE TABLE rule_validation AS
SELECT a.label,a.fold,countif(a.hit) train_selected,countif(a.hit AND b.hit IS NOT NULL) evaluable,
 countif(a.hit AND b.hit) repeated FROM appliance_holdout a
LEFT JOIN appliance_holdout b ON a.id=b.id AND a.fold=b.fold AND a.label=b.label AND b.test
WHERE NOT a.test GROUP BY ALL;

CREATE OR REPLACE TABLE customer_devices AS
WITH timer AS (
 SELECT id,countif(train>=0.30 AND test>=0.30) rep FROM pairs
 WHERE hours=3 AND tol=1 GROUP BY id
), repeats AS (
 SELECT a.id,
 countif(a.label='Water heater: pulse' AND a.hit AND b.hit) water_rep,
 countif(a.label='Hot tub: cold cycling' AND a.hit AND b.hit) tub_rep,
 countif(a.label='PV storage: matched rebound' AND a.hit AND b.hit) pv_rep
 FROM appliance_holdout a JOIN appliance_holdout b USING(id,fold,label)
 WHERE NOT a.test AND b.test GROUP BY a.id
)
SELECT pop.id,c.hours,coalesce(c.sufficient_history,false) eligible,
 ev.customer_number IS NOT NULL ev_reference,hp.customer_number IS NOT NULL hp_reference,
 pv.customer_number IS NOT NULL known_pv,
 s.new_hit ev_candidate,s.ranking_score ev_rank_score,
 CASE WHEN s.new_hit THEN CASE WHEN c.ev_l2_signature THEN 'L2-like' WHEN c.ev_l1_signature THEN 'L1-like' ELSE 'Unresolved' END END ev_level_hint,
 h.selected hp_candidate,h.ranking_score hp_rank_score,
 CASE WHEN h.selected THEN CASE WHEN h.winter_path THEN 'Winter-only' ELSE 'Dual-season' END END hp_path,
 c.ac_signature cooling_candidate,c.strong_electric_heating_candidate,
 c.pool_signature seasonal_pool_screen,timer.rep pool_timer_repeats,
 c.water_heater_signature water_heater_screen,c.hot_tub_signature hot_tub_screen,
 c.pv_storage_signature pv_storage_screen,repeats.water_rep,repeats.tub_rep,repeats.pv_rep
FROM range(1,35726) pop(id) LEFT JOIN prior.classification c USING(id)
LEFT JOIN validated.screening s ON s.id=pop.id AND s.technology='ev'
LEFT JOIN validated.hp_winter_screen h ON h.id=pop.id
LEFT JOIN timer ON timer.id=pop.id LEFT JOIN repeats ON repeats.id=pop.id
LEFT JOIN odsdb.ods.ev_customers ev ON ev.customer_number=pop.id
LEFT JOIN odsdb.ods.hp_customers hp ON hp.customer_number=pop.id
LEFT JOIN odsdb.ods.pv_customers pv ON pv.customer_number=pop.id;
SELECT CASE WHEN count(*)=35725 AND count(DISTINCT id)=35725 THEN true ELSE error('Invalid customer grain') END verified FROM customer_devices;
COMMIT;
SELECT * FROM rule_validation ORDER BY label,fold;
SELECT count(*) total,countif(eligible) eligible,countif(ev_candidate) ev,countif(ev_level_hint='L1-like') l1,
countif(ev_level_hint='L2-like') l2,countif(ev_level_hint='Unresolved') unresolved,countif(hp_candidate) hp,
countif(cooling_candidate) ac,countif(strong_electric_heating_candidate) heating,countif(hp_reference AND strong_electric_heating_candidate) dual,
countif(seasonal_pool_screen) pool,countif(pool_timer_repeats=3) timer3,
countif(water_heater_screen) water,countif(water_heater_screen AND water_rep=3) water3,
countif(hot_tub_screen) tub,countif(hot_tub_screen AND tub_rep=3) tub3,
countif(known_pv) pv,countif(pv_storage_screen) storage,countif(pv_storage_screen AND pv_rep=3) storage3
FROM customer_devices;

.read scripts/analysis/part1/customer_characteristics.sql
