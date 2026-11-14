-- Run from repository root: duckdb -bail database/part3_assessment.duckdb < scripts/analysis/part3/assessment.sql
.read scripts/analysis/part3/opportunity.sql
BEGIN TRANSACTION;
CREATE OR REPLACE TABLE assessment_values AS
WITH daily AS (
 SELECT id,d,sum(dr) shifted,sum(discharged) discharge,
 max(k) FILTER(WHERE he=peak_he) before_kw,
 max(k-dr-discharged) FILTER(WHERE he=peak_he) after_kw,
 countif(4.0-dr-discharged>3.0) review_hours, count(*) study_hours
 FROM dispatch GROUP BY id,d
), impacts AS (
 SELECT id,sum(shifted) shifted_total,sum(discharge) discharged_total,
 avg(before_kw) before_kw,avg(after_kw) after_kw,sum(review_hours) review_hours,sum(study_hours) study_hours
 FROM daily GROUP BY id
)
SELECT c.*,s.events,s.shift_days,b.recurrent,m.peak_dr_kw,m.peak_bess_kw,
 i.before_kw,i.after_kw,i.shifted_total,i.discharged_total,i.discharged_total/0.894 recharge_total,
 -- Illustrative avoided energy charges, excluding demand charges, subsidies and capital costs.
 (i.shifted_total+i.discharged_total)*0.30-(i.shifted_total+i.discharged_total/0.894)*0.10 scenario_savings,
 i.review_hours,i.study_hours,p.known_pv
FROM customer_opportunity c LEFT JOIN sizing s ON s.id=c.customer_id
LEFT JOIN battery_design b ON b.id=c.customer_id LEFT JOIN opportunity_metrics m ON m.id=c.customer_id
LEFT JOIN impacts i ON i.id=c.customer_id JOIN profiles.customer_segments p ON p.id=c.customer_id;

.read scripts/analysis/part3/assessment_views.sql
SELECT CASE WHEN count(*)=35725 AND count(DISTINCT customer_id)=35725 AND
 countif(abs(before_kw-after_kw-peak_dr_kw-peak_bess_kw)>0.000001)=0 AND
 countif(review_hours>study_hours)=0 THEN true ELSE error('Assessment reconciliation failed') END verified
FROM assessment_values;
COMMIT;
