-- Run from the repository root using a fresh in-memory DuckDB CLI session:
-- duckdb -bail < scripts/analysis/part1/validate_thermal.sql

-- Match the baseline daily weather calculation. Keep cold and extreme days
-- in the same spell when temperatures cross 20 F without reaching 35 F.
CREATE TEMP TABLE dates AS
WITH hourly AS (
    SELECT observation_date d, observation_time, avg(temp) t
    FROM ods.weather_hourly GROUP BY ALL
), daily AS (SELECT d,avg(t) t FROM hourly GROUP BY d),
bands AS (
    SELECT *, CASE WHEN t>75 THEN 'hot' WHEN t<35 THEN 'cold'
                   WHEN t BETWEEN 55 AND 65 THEN 'mild' END band FROM daily
), starts AS (
    SELECT *, (band IS DISTINCT FROM lag(band) OVER (ORDER BY d))::INT AS new_spell FROM bands
), spells AS (
    SELECT *, sum(new_spell) OVER (ORDER BY d) spell FROM starts
), numbered AS (
    SELECT *, dense_rank() OVER (PARTITION BY band ORDER BY spell) seq FROM spells WHERE band IS NOT NULL
)
SELECT *, CASE WHEN seq % 3 = 2 THEN 'test' ELSE 'train' END AS split FROM numbered;

SELECT split,band,count(DISTINCT spell) spells,count(*) AS days,countif(t<20) extreme_days
FROM dates GROUP BY ALL ORDER BY band,split;

CREATE TEMP TABLE features AS
SELECT a.id, coalesce(split,'annual') split,
       avg(mean_kw) FILTER (WHERE t>75) - avg(mean_kw) FILTER (WHERE band='mild') cooling,
       avg(mean_kw) FILTER (WHERE t<35) - avg(mean_kw) FILTER (WHERE band='mild') heating,
       avg(mean_kw) FILTER (WHERE t<20) - avg(mean_kw) FILTER (WHERE t<35) extreme_orig,
       avg(mean_kw) FILTER (WHERE t<20) - avg(mean_kw) FILTER (WHERE t>=20 AND t<35) extreme_sep,
       avg(mean_kw) FILTER (WHERE t>=20 AND t<35) - avg(mean_kw) FILTER (WHERE band='mild') heating_sep
FROM intermediate.daily a JOIN dates USING(d) JOIN intermediate.classification c ON a.id=c.id AND c.sufficient_history
GROUP BY GROUPING SETS ((a.id,split),(a.id));

CREATE TEMP TABLE grid AS
SELECT 'AC' device, cooling_threshold x, 0.0 y
FROM (VALUES (0.30),(0.45),(0.60)) g(cooling_threshold)
UNION ALL
SELECT device,x,y FROM (VALUES ('R-original'),('R-separated')) g(device)
CROSS JOIN (VALUES (0.90),(1.20),(1.50)) h(x)
CROSS JOIN (VALUES (0.30),(0.45),(0.60)) e(y);

CREATE TEMP TABLE flags AS
SELECT id,split,device,x,y,
 CASE device WHEN 'AC' THEN cooling>=x WHEN 'R-original' THEN heating>=x AND extreme_orig>=y
 ELSE heating_sep>=x AND extreme_sep>=y END hit,
 CASE device WHEN 'AC' THEN cooling IS NOT NULL WHEN 'R-original' THEN heating IS NOT NULL AND extreme_orig IS NOT NULL
 ELSE heating_sep IS NOT NULL AND extreme_sep IS NOT NULL END available
FROM features CROSS JOIN grid;

SELECT a.device,a.x,a.y,countif(a.hit) AS annual,countif(b.hit) AS train,
       countif(b.hit AND c.available) testable,countif(b.hit AND c.hit) reproduced,
       round(100.0*countif(b.hit AND c.hit)/nullif(countif(b.hit AND c.available),0),1) repeat_pct,
       countif(a.hit AND hp.customer_number IS NOT NULL) hp_annual,
       countif(b.hit AND hp.customer_number IS NOT NULL) hp_train,
       countif(b.hit AND c.hit AND hp.customer_number IS NOT NULL) hp_repeat
FROM flags a LEFT JOIN flags b ON (a.id,a.device,a.x,a.y)=(b.id,b.device,b.x,b.y) AND b.split='train' LEFT JOIN flags c ON (a.id,a.device,a.x,a.y)=(c.id,c.device,c.x,c.y) AND c.split='test'
LEFT JOIN ods.hp_customers hp ON hp.customer_number=a.id
WHERE a.split='annual'
GROUP BY ALL ORDER BY a.device,a.x,a.y;

-- Examine customers immediately below and above the original thresholds.
WITH pairs AS (
    SELECT a.cooling x,b.cooling v,'AC' metric,0.45 cut,0.10 width FROM features a JOIN features b USING(id)
    WHERE a.split='train' AND b.split='test'
    UNION ALL
    SELECT a.extreme_orig,b.extreme_orig,'R-extreme',0.45,0.15 FROM features a JOIN features b USING(id)
    WHERE a.split='train' AND b.split='test' AND a.heating>=1.20
)
SELECT metric, CASE WHEN x<cut THEN 'below' ELSE 'above' END side,count(v) evaluable,
       round(median(v),3) median_test_kw,round(100*avg((v>=cut)::INT),1) pct_above_test_cut
FROM pairs WHERE x>=cut-width AND x<cut+width GROUP BY ALL ORDER BY metric,side;

SELECT f.split, count(*) hp_with_history, countif(f.heating IS NOT NULL AND f.extreme_orig IS NOT NULL) hp_evaluable
FROM features f JOIN ods.hp_customers hp ON hp.customer_number=f.id GROUP BY f.split ORDER BY f.split;

-- Rotate all three spell blocks as holdouts for the shortlisted thresholds.
WITH folds AS (
 SELECT d,t,band,seq,fold FROM dates CROSS JOIN range(3) r(fold)
), contrasts AS (
 SELECT a.id,fold,seq%3=fold AS held_out,
 avg(mean_kw) FILTER(WHERE t>75)-avg(mean_kw) FILTER(WHERE band='mild') ac,
 avg(mean_kw) FILTER(WHERE t>=20 AND t<35)-avg(mean_kw) FILTER(WHERE band='mild') cold_sep,
 avg(mean_kw) FILTER(WHERE t<20)-avg(mean_kw) FILTER(WHERE t>=20 AND t<35) extreme_sep,
 avg(mean_kw) FILTER(WHERE t<35)-avg(mean_kw) FILTER(WHERE band='mild') cold_orig,
 avg(mean_kw) FILTER(WHERE t<20)-avg(mean_kw) FILTER(WHERE t<35) extreme_orig
 FROM intermediate.daily a JOIN folds USING(d) JOIN intermediate.classification c ON c.id=a.id AND c.sufficient_history
 GROUP BY ALL
), scored AS (
 SELECT id,fold,held_out,name,hit FROM contrasts,
 LATERAL (VALUES ('AC .45', ac>=0.45), ('Original 1.20/.45',cold_orig>=1.20 AND extreme_orig>=0.45),
 ('Separated 1.20/.30', cold_sep>=1.20 AND extreme_sep>=0.30),
 ('Separated 1.20/.45', cold_sep>=1.20 AND extreme_sep>=0.45)) r(name,hit)
)
SELECT a.name,a.fold,countif(a.hit AND b.hit IS NOT NULL) tested,countif(a.hit AND b.hit) repeated,
 round(100.0*countif(a.hit AND b.hit)/nullif(countif(a.hit AND b.hit IS NOT NULL),0),1) repeat_pct
FROM scored a JOIN scored b USING(id,fold,name) WHERE NOT a.held_out AND b.held_out
GROUP BY ALL ORDER BY a.name,a.fold;
