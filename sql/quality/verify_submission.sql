-- Run from the repository root after the three final databases are built.
ATTACH 'database/part1_final.duckdb' AS devices (READ_ONLY);
ATTACH 'database/part2_final.duckdb' AS profiles (READ_ONLY);
ATTACH 'database/part3_assessment.duckdb' AS opportunities (READ_ONLY);

WITH device_rows AS (
    SELECT customer_id, count(*) n, count(DISTINCT characteristic) labels,
           countif(score_0_to_10 IS NULL OR score_0_to_10 NOT BETWEEN 0 AND 10) invalid
    FROM devices.customer_characteristics GROUP BY customer_id
), profile_rows AS (
    SELECT customer_id, count(*) n FROM profiles.customer_profile GROUP BY customer_id
), opportunity_rows AS (
    SELECT customer_id, count(*) n FROM opportunities.customer_assessment GROUP BY customer_id
)
SELECT CASE WHEN count(*) = 35725 AND countif(
    d.n IS DISTINCT FROM 12 OR d.labels IS DISTINCT FROM 12 OR d.invalid IS DISTINCT FROM 0
    OR p.n IS DISTINCT FROM 1 OR o.n IS DISTINCT FROM 1
) = 0 THEN true ELSE error('Invalid final customer grain or missing IDs') END AS customer_outputs_verified
FROM device_rows d FULL JOIN profile_rows p USING (customer_id)
FULL JOIN opportunity_rows o USING (customer_id);

SELECT CASE WHEN countif(a.peak_relief_top_pct IS DISTINCT FROM
    (100.0 * v.priority / nullif(t.ranked, 0))::DECIMAL(6,3)) = 0
    THEN true ELSE error('Candidate percentile mismatch') END AS priority_verified
FROM opportunities.customer_assessment a JOIN opportunities.assessment_values v USING (customer_id)
CROSS JOIN (SELECT count(priority) ranked FROM opportunities.assessment_values) t;
