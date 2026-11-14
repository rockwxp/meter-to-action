-- In-sample opportunity screening. HE18..21 spans 17:00..21:00.
CREATE OR REPLACE TABLE system_hour AS
SELECT usage_date d,hour_ending he,sum(hourly_kwh) baseline_kw,count(hourly_kwh) meters
FROM src.ods.ami_hourly GROUP BY ALL;

CREATE OR REPLACE TEMP TABLE peak_hours AS
SELECT * FROM system_hour WHERE he BETWEEN 18 AND 21
ORDER BY baseline_kw DESC,d,he LIMIT 100;

CREATE OR REPLACE TABLE candidates AS
WITH peaks AS (
 SELECT a.customer_number id,avg(a.hourly_kwh) peak_kw,count(a.hourly_kwh) sampled_peaks
 FROM src.ods.ami_hourly a JOIN peak_hours p ON a.usage_date=p.d AND a.hour_ending=p.he
 GROUP BY 1
)
SELECT p.*, f.evening_kw AS target_kw, c.ev_reference OR c.ev_l2_signature AS flexible_ev,
 row_number() OVER (ORDER BY peak_kw-f.evening_kw DESC,id) priority
FROM peaks p JOIN features f USING(id) JOIN classification c USING(id)
WHERE f.hours>=8000 AND sampled_peaks>=95 AND peak_kw>f.evening_kw;

-- Evaluate the first 500 candidates. Each complete day starts and ends fully charged.
-- Simulated EV response: up to 1.5 kW above the customer's mean evening demand,
-- with all shifted energy recovered equally over HE22..24.
-- Two-unit BESS: 20.16 kWh, daily usable SOC window 10..100%, 7.68 kW continuous.
-- Allocate the AC energy budget equally across the four evening hours.
CREATE OR REPLACE TEMP TABLE actions AS
WITH readings AS (
 SELECT a.customer_number id, usage_date d, hour_ending he, hourly_kwh k,
        greatest(hourly_kwh-c.target_kw,0) surplus, flexible_ev,
        count(hourly_kwh) OVER (PARTITION BY a.customer_number, usage_date)=24 AS full_day
 FROM src.ods.ami_hourly a JOIN candidates c ON a.customer_number=c.id AND c.priority<=500
), dr AS (
 SELECT *,CASE WHEN full_day AND he BETWEEN 18 AND 21 THEN surplus ELSE 0 END requested,
 CASE WHEN full_day AND flexible_ev AND he BETWEEN 18 AND 21 THEN least(1.5,surplus) ELSE 0 END shifted
 FROM readings
)
SELECT *, least(requested,7.68,20.16*0.9*sqrt(0.894)/4) battery_only,
          least(requested-shifted,7.68,20.16*0.9*sqrt(0.894)/4) joint_battery FROM dr;

CREATE OR REPLACE TABLE candidate_benefits AS
WITH day AS (
 SELECT id,d,max(requested-shifted) required_kw,sum(requested-shifted)/sqrt(0.894)/0.9 required_kwh,
 sum(shifted) dr_kwh,sum(joint_battery) battery_kwh FROM actions WHERE full_day GROUP BY id,d
)
SELECT id, count(*) replay_days,quantile_cont(required_kw,0.95) p95_required_kw,
 quantile_cont(required_kwh,0.95) p95_required_nameplate_kwh, sum(dr_kwh) shifted_kwh,
 sum(battery_kwh) discharged_kwh, avg((required_kw<=7.68 AND required_kwh<=20.16)::INT) sizing_day_coverage
FROM day GROUP BY id;

CREATE OR REPLACE TABLE portfolio_hour AS
WITH changes AS (
 SELECT *,sum(shifted) OVER w day_dr,sum(battery_only) OVER w day_bat,sum(joint_battery) OVER w day_joint
 FROM actions WINDOW w AS (PARTITION BY id,d)
), hourly AS (
 SELECT d,he,sum(-shifted+CASE WHEN he>=22 THEN day_dr/3 ELSE 0 END) dr_change,
 sum(-battery_only+CASE WHEN he>=22 THEN day_bat/(3*0.894) ELSE 0 END) bat_change,
 sum(-joint_battery+CASE WHEN he>=22 THEN day_joint/(3*0.894) ELSE 0 END) joint_bat_change
 FROM changes GROUP BY d,he
)
SELECT s.*,baseline_kw+coalesce(dr_change,0) dr_kw,baseline_kw+coalesce(bat_change,0) bess_kw,
 baseline_kw+coalesce(dr_change+joint_bat_change,0) joint_kw
FROM system_hour s LEFT JOIN hourly USING(d,he);
