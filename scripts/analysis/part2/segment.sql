USE part2;
-- From the repository root: duckdb -bail database/meter_to_action.duckdb < scripts/analysis/part2/segment.sql
-- All interval timestamps use local hour-ending labels from the ODS.
SET threads=12;
SET memory_limit='40GiB';
BEGIN TRANSACTION;

-- Sufficient statistics preserve hourly weighting when weekly halves are pooled.
CREATE TEMP TABLE buckets AS
SELECT customer_number id,
       date_diff('week',DATE '2025-09-01',time_bucket(INTERVAL '1 week',usage_date))%2 half,
       CASE WHEN month(usage_date) IN (12,1,2) THEN 'winter'
            WHEN month(usage_date) IN (6,7,8) THEN 'summer' ELSE 'shoulder' END season,
       hour_ending-1 h, sum(hourly_kwh) kwh,count(hourly_kwh) n
FROM ods.ami_hourly GROUP BY ALL;

CREATE TEMP TABLE features AS
WITH aggregated AS (
 SELECT id,coalesce(half,2) period,sum(n) hours_seen,sum(kwh)/sum(n) mean_kw,
 sum(kwh) FILTER(WHERE season='winter')/sum(n) FILTER(WHERE season='winter') winter_kw,
 sum(kwh) FILTER(WHERE season='summer')/sum(n) FILTER(WHERE season='summer') summer_kw,
 sum(kwh) FILTER(WHERE h<6)/sum(n) FILTER(WHERE h<6) night_kw,
 sum(kwh) FILTER(WHERE h BETWEEN 10 AND 14)/sum(n) FILTER(WHERE h BETWEEN 10 AND 14) midday_kw,
 sum(kwh) FILTER(WHERE h BETWEEN 17 AND 20)/sum(n) FILTER(WHERE h BETWEEN 17 AND 20) evening_kw,
 sum(n) FILTER(WHERE season='winter') winter_hours,sum(n) FILTER(WHERE season='summer') summer_hours
 FROM buckets GROUP BY GROUPING SETS ((id,half),(id))
)
SELECT *,CASE
 WHEN hours_seen < CASE WHEN period=2 THEN 4380 ELSE 2190 END
   OR coalesce(winter_hours,0)< CASE WHEN period=2 THEN 336 ELSE 168 END
   OR coalesce(summer_hours,0)< CASE WHEN period=2 THEN 336 ELSE 168 END THEN 'Limited history'
 WHEN night_kw>=1.35*mean_kw AND night_kw-mean_kw>=0.20 THEN 'Night-heavy'
 WHEN winter_kw>=1.6*summer_kw AND winter_kw-summer_kw>=0.5 THEN 'Winter-heavy'
 WHEN summer_kw>=1.6*winter_kw AND summer_kw-winter_kw>=0.5 THEN 'Summer-heavy'
 WHEN evening_kw>=1.35*mean_kw AND evening_kw-mean_kw>=0.30 THEN 'Evening-heavy'
 WHEN mean_kw>=1.50 THEN 'High average'
 ELSE 'Other profiles' END segment FROM aggregated;

CREATE OR REPLACE TABLE customer_segments AS
SELECT d.*,coalesce(f.segment,'No AMI') segment,f.mean_kw,f.winter_kw,f.summer_kw,f.night_kw,
 f.midday_kw,f.evening_kw,a.segment even_week_segment,b.segment odd_week_segment
FROM part1.customer_devices d LEFT JOIN features f ON d.id=f.id AND f.period=2
LEFT JOIN features a ON d.id=a.id AND a.period=0
LEFT JOIN features b ON d.id=b.id AND b.period=1;

-- Equal weight per customer for the representative hourly profile.
CREATE OR REPLACE TABLE typical_profile AS
WITH per_customer AS (SELECT id,h,sum(kwh)/sum(n) kw FROM buckets GROUP BY id,h)
SELECT segment,h,median(kw) median_kw,avg(kw) mean_kw,count(kw) contributors
FROM per_customer JOIN customer_segments USING(id) GROUP BY segment,h;

CREATE TEMP TABLE system_peaks AS
SELECT usage_date d,hour_ending he,sum(hourly_kwh) system_kw,count(hourly_kwh) meters
FROM ods.ami_hourly GROUP BY ALL ORDER BY system_kw DESC,d,he LIMIT 100;
CREATE OR REPLACE TABLE peak_contributions AS
WITH obs AS (
 SELECT p.d,p.he,s.segment,sum(a.hourly_kwh) kw,count(a.hourly_kwh) n
 FROM system_peaks p JOIN ods.ami_hourly a ON a.usage_date=p.d AND a.hour_ending=p.he
 JOIN customer_segments s ON s.id=a.customer_number GROUP BY ALL
)
SELECT p.*,g.segment,coalesce(o.kw,0) group_kw,coalesce(o.n,0) observed_customers
FROM system_peaks p CROSS JOIN (SELECT DISTINCT segment FROM customer_segments) g
LEFT JOIN obs o USING(d,he,segment);

CREATE OR REPLACE TABLE stability AS
SELECT even_week_segment,odd_week_segment,count(*) customers
FROM customer_segments GROUP BY ALL;

CREATE OR REPLACE TABLE segment_summary AS
WITH peak AS (
 SELECT segment,arg_max(group_kw,system_kw)/1000 peak_mw,100*arg_max(group_kw,system_kw)/max(system_kw) peak_pct,
 avg(group_kw)/1000 top100_mw,100*sum(group_kw)/sum(system_kw) top100_pct FROM peak_contributions GROUP BY segment
)
SELECT c.segment,count(*) customers, round(p.peak_mw,3) peak_mw,round(p.peak_pct,2) peak_pct,
 round(p.top100_mw,3) top100_mw,round(p.top100_pct,2) top100_pct,
 round(100*avg(ev_candidate::INT),1) ev_pct,round(100*avg(cooling_candidate::INT),1) cooling_pct,
 round(100*avg(strong_electric_heating_candidate::INT),1) heating_pct,
 round(100*avg(hp_candidate::INT),1) hp_pct,
 countif(even_week_segment=odd_week_segment) agree_halves
FROM customer_segments c JOIN peak p USING(segment) GROUP BY ALL;
SELECT CASE WHEN count(*)=35725 AND count(DISTINCT id)=35725 THEN true ELSE error('Customer grain mismatch') END verified FROM customer_segments;
SELECT CASE WHEN max(delta)<0.001 THEN true ELSE error('Coincident load mismatch') END verified
FROM (SELECT abs(sum(group_kw)-max(system_kw)) delta FROM peak_contributions GROUP BY d,he);
.read scripts/analysis/part2/customer_profile.sql
COMMIT;
SELECT * FROM segment_summary ORDER BY customers DESC;
SELECT segment,list(round(median_kw,2) ORDER BY h) hourly_median_kw FROM typical_profile GROUP BY segment;
SELECT d,he,system_kw,meters FROM system_peaks ORDER BY system_kw DESC LIMIT 1;
SELECT even_week_segment, sum(customers) n,sum(customers) FILTER(WHERE even_week_segment=odd_week_segment) retained
FROM stability GROUP BY even_week_segment ORDER BY n DESC;

-- Cohen's kappa uses only customers with sufficient coverage in both halves.
WITH matrix AS (
 SELECT * FROM stability WHERE even_week_segment <> 'Limited history' AND odd_week_segment <> 'Limited history'
), totals AS (
 SELECT sum(customers) n,sum(customers) FILTER(WHERE even_week_segment=odd_week_segment) agree FROM matrix
), marginals AS (
 SELECT a.n_even*b.n_odd product FROM
 (SELECT even_week_segment segment,sum(customers) n_even FROM matrix GROUP BY 1) a
 JOIN (SELECT odd_week_segment segment,sum(customers) n_odd FROM matrix GROUP BY 1) b USING(segment)
)
SELECT n,agree,round(100.0*agree/n,2) agreement_pct,
 round((agree/n-sum(product)/(n*n))/(1-sum(product)/(n*n)),3) kappa
FROM totals CROSS JOIN marginals GROUP BY n,agree;
