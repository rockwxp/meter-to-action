-- Run against database/part1_validation.duckdb after validate.py.
-- Preserve the original rule flag and use the existing out-of-fold HP model only
-- for ranking households within each path. Reserve 15% of the original budget
-- for the winter path, rounded down per fold. No labels enter path selection.
BEGIN TRANSACTION;

CREATE OR REPLACE TABLE hp_winter_screen AS
WITH pool AS (
    SELECT s.id, s.fold, s.reference, s.old_hit, s.ranking_score,
           f.heating_kw, f.cooling_kw, f.winter_corr,
           (f.heating_kw >= 0.65 AND f.cooling_kw < 0.35
            AND f.winter_corr <= -0.50) IS TRUE AS winter_path
    FROM screening s JOIN signals f USING (id)
    WHERE s.technology = 'hp'
), budgets AS (
    SELECT fold, countif(old_hit) AS budget,
           least(countif(winter_path), (countif(old_hit) * 15) // 100) AS winter_slots
    FROM pool GROUP BY fold
), ranked AS (
    SELECT p.*, b.budget, b.winter_slots,
           row_number() OVER (PARTITION BY fold, old_hit, winter_path
                              ORDER BY ranking_score DESC, id) AS path_rank
    FROM pool p JOIN budgets b USING (fold)
)
SELECT *, (old_hit AND path_rank <= budget - winter_slots)
       OR (winter_path AND path_rank <= winter_slots) AS selected
FROM ranked;

-- The requested EV choice is exposed as the Part 1 EV screening output.
CREATE OR REPLACE VIEW ev_selected AS
SELECT id, fold, ranking_score FROM screening WHERE technology='ev' AND new_hit;

SELECT CASE WHEN count(*) = 5 AND bool_and(old_n = new_n) THEN true
            ELSE error('The per-fold screening budgets do not match.') END AS budgets_verified
FROM (SELECT fold,countif(old_hit) old_n,countif(selected) new_n FROM hp_winter_screen GROUP BY fold);
COMMIT;

SELECT fold, count(*) AS eligible, countif(reference) AS reference_n,
       countif(selected) AS screened, countif(selected AND winter_path) AS winter_seats,
       countif(reference AND old_hit) AS baseline_hits, countif(reference AND selected) AS combined_hits,
       countif(reference AND selected AND NOT old_hit) AS recovered,
       countif(reference AND old_hit AND NOT selected) AS displaced
FROM hp_winter_screen GROUP BY GROUPING SETS ((fold),()) ORDER BY fold NULLS LAST;

SELECT id, fold, old_hit, selected, heating_kw, cooling_kw, winter_corr
FROM hp_winter_screen WHERE reference AND old_hit <> selected ORDER BY selected DESC,id;
