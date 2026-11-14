-- From the project root: duckdb -bail database/part3_final.duckdb < scripts/analysis/part3/opportunity.sql
-- Part 2 carries the approved Part 1 device flags. No source rows are updated.
ATTACH 'database/meter_to_action.duckdb' AS raw (READ_ONLY);
ATTACH 'database/part2_final.duckdb' AS profiles (READ_ONLY);
SET threads=12;
SET memory_limit='40GiB';
BEGIN TRANSACTION;

CREATE TEMP TABLE system_hours AS
SELECT usage_date d,hour_ending he,sum(hourly_kwh) load_kw,count(hourly_kwh) meters
FROM raw.ods.ami_hourly GROUP BY ALL;

-- Equal representation for winter and summer. At most one five-hour event per date.
CREATE OR REPLACE TABLE event_days AS
WITH daily AS (
 SELECT d,CASE WHEN month(d) IN (12,1,2) THEN 'Winter' ELSE 'Summer' END season,
 max(load_kw) event_peak_kw,arg_max(he,load_kw ORDER BY he) peak_he
 FROM system_hours WHERE he BETWEEN 17 AND 21 AND month(d) IN (12,1,2,6,7,8)
 GROUP BY ALL
)
SELECT * FROM daily QUALIFY row_number() OVER(PARTITION BY season ORDER BY event_peak_kw DESC,d)<=20;

CREATE TEMP TABLE available AS
SELECT a.customer_number id,e.d,e.season,e.peak_he
FROM raw.ods.ami_hourly a JOIN event_days e ON a.usage_date=e.d
WHERE a.hour_ending BETWEEN 17 AND 24 GROUP BY ALL HAVING count(a.hourly_kwh)=8;

-- Protect each household's usual evening demand. Flexible power caps are scenario
-- assumptions; use only the largest applicable cap to avoid stacking appliances.
CREATE TEMP TABLE screened AS
SELECT v.*,a.hour_ending he,a.hourly_kwh k,greatest(a.hourly_kwh-p.evening_kw,0) excess,
 greatest(CASE WHEN p.ev_candidate OR p.ev_reference THEN 1.50 ELSE 0 END,
 CASE WHEN v.season='Summer' AND p.cooling_candidate THEN 0.50
      WHEN v.season='Winter' AND (p.hp_candidate OR p.hp_reference OR p.strong_electric_heating_candidate) THEN 0.50 ELSE 0 END,
 CASE WHEN p.water_heater_screen AND p.water_rep=3 THEN 0.30 ELSE 0 END) flex_cap
FROM available v JOIN raw.ods.ami_hourly a ON v.id=a.customer_number AND v.d=a.usage_date
JOIN profiles.customer_segments p ON p.id=v.id
WHERE a.hour_ending BETWEEN 17 AND 21 AND p.hours>=8000 AND p.segment NOT IN ('No AMI','Limited history');

CREATE TEMP TABLE demand AS
SELECT *,least(excess,flex_cap) shift_kw,excess-least(excess,flex_cap) residual FROM screened;

CREATE TEMP TABLE daily_need AS
SELECT id,d,
 sum(shift_kw) shifted_kwh,max(shift_kw) FILTER(WHERE he=peak_he) peak_dr
FROM demand GROUP BY id,d;

CREATE OR REPLACE TABLE sizing AS
WITH stats AS (
 SELECT id,count(*) events,countif(shifted_kwh>=0.5) shift_days,
 avg(peak_dr) dr_peak,avg(shifted_kwh) dr_energy
 FROM daily_need GROUP BY id HAVING count(*)>=36
)
SELECT *, shift_days>=8 AND dr_peak>=0.1 AS use_dr FROM stats;

CREATE TEMP TABLE operational AS
SELECT d.*,s.use_dr,CASE WHEN use_dr THEN shift_kw ELSE 0 END dr,
 excess-CASE WHEN use_dr THEN shift_kw ELSE 0 END remaining
FROM demand d JOIN sizing s USING(id);

CREATE TEMP TABLE needs AS
SELECT id,d,sum(remaining)/(0.9*sqrt(0.894)) nameplate,max(remaining) power,
 max(remaining) FILTER(WHERE he=peak_he) at_peak FROM operational GROUP BY id,d;

CREATE OR REPLACE TABLE battery_design AS
WITH stats AS (
 SELECT id,quantile_cont(nameplate,0.95) kwh95,quantile_cont(power,0.95) kw95,
 countif(at_peak>=0.5) recurrent FROM needs GROUP BY id
)
SELECT *,CASE WHEN recurrent>=8 THEN least(20.16,ceil(kwh95*10)/10) ELSE 0 END capacity,
 CASE WHEN recurrent>=8 THEN least(7.68,kw95) ELSE 0 END inverter FROM stats;

-- Five equal hourly discharge budgets guarantee a feasible SOC trajectory even
-- on peak days. Equal recharge across HE22..24 respects the 7.68 kW reference
-- inverter; additionally limit discharge to what the proposed inverter can recharge.
CREATE TEMP TABLE dispatch AS
SELECT o.*,least(remaining,inverter,capacity*0.9*sqrt(0.894)/5,inverter*3*0.894/5) discharged,
 least(excess,inverter,capacity*0.9*sqrt(0.894)/5,inverter*3*0.894/5) standalone
FROM operational o JOIN battery_design USING(id);

CREATE OR REPLACE TABLE opportunity_metrics AS
WITH daily AS (
 SELECT id,d,sum(dr) shift_kwh,max(dr) dr_kw,
 max(dr) FILTER(WHERE he=peak_he) peak_dr,max(discharged) FILTER(WHERE he=peak_he) peak_bess
 FROM dispatch GROUP BY id,d
)
SELECT id,count(*) events,avg(shift_kwh) shift_kwh,avg(dr_kw) shift_kw,
 avg(peak_dr) peak_dr_kw,avg(peak_bess) peak_bess_kw,avg(peak_dr+peak_bess) peak_cut_kw
FROM daily GROUP BY id;

CREATE OR REPLACE TABLE customer_opportunity AS
WITH ranked AS (
 SELECT id,row_number() OVER(ORDER BY peak_cut_kw DESC,id) priority
 FROM opportunity_metrics WHERE peak_cut_kw>0
)
SELECT p.id customer_id,r.priority,
 CASE WHEN m.id IS NULL THEN 'Insufficient data' WHEN NOT s.use_dr THEN 'No DR'
 WHEN ev_reference OR ev_candidate THEN 'EV charging'
 WHEN (hp_candidate OR hp_reference OR strong_electric_heating_candidate) AND cooling_candidate THEN 'HVAC control'
 WHEN hp_candidate OR hp_reference OR strong_electric_heating_candidate THEN 'Heating control'
 WHEN cooling_candidate THEN 'Cooling control' ELSE 'Water heating' END dr_plan,
 CASE WHEN m.id IS NULL THEN 'Insufficient data' WHEN capacity=0 THEN 'No BESS'
 WHEN kwh95>20.16 OR kw95>7.68 THEN 'Partial coverage' ELSE 'Size for pilot' END bess_plan,
 round(m.shift_kw,2) shift_kw,round(m.shift_kwh,2) shift_kwh,round(capacity,2) battery_kwh,
 round(inverter,2) battery_kw,round(m.peak_cut_kw,2) peak_cut_kw
FROM profiles.customer_segments p LEFT JOIN opportunity_metrics m USING(id)
LEFT JOIN sizing s USING(id) LEFT JOIN battery_design b USING(id) LEFT JOIN ranked r USING(id);

-- Replay the top 500 at concurrent hours, including EV/HVAC recovery and battery losses.
CREATE OR REPLACE TABLE portfolio_replay AS
WITH actions AS (
 SELECT d,he,sum(dr) dr,sum(discharged) bat,sum(standalone) standalone FROM dispatch JOIN customer_opportunity p ON id=p.customer_id
 WHERE priority<=500 GROUP BY d,he
), recovery AS (
 SELECT d,sum(dr)/3 dr,sum(bat)/(0.894*3) bat,sum(standalone)/(0.894*3) standalone FROM actions GROUP BY d
)
SELECT s.*,load_kw-coalesce(a.dr,0)+CASE WHEN he>=22 THEN coalesce(r.dr,0) ELSE 0 END dr_only_kw,
 load_kw-coalesce(a.standalone,0)+CASE WHEN he>=22 THEN coalesce(r.standalone,0) ELSE 0 END bess_only_kw,
 load_kw-coalesce(a.dr+a.bat,0)+CASE WHEN he>=22 THEN coalesce(r.dr+r.bat,0) ELSE 0 END joint_kw
FROM system_hours s LEFT JOIN actions a USING(d,he) LEFT JOIN recovery r USING(d);

SELECT CASE WHEN count(*)=35725 AND count(DISTINCT customer_id)=35725 THEN true ELSE error('Customer grain mismatch') END verified FROM customer_opportunity;
SELECT CASE WHEN count(*)=0 THEN true ELSE error('Dispatch outside load bounds') END verified
FROM dispatch WHERE dr+discharged>excess+0.000001 OR dr<0 OR discharged<0;
COMMIT;
