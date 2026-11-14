USE validation;
SELECT technology,count(*) eligible,countif(reference) reference_n,countif(old_hit) old_budget,
       countif(new_hit) new_budget,countif(reference AND old_hit) old_hits,
       countif(reference AND new_hit) new_hits,countif(reference AND NOT old_hit AND new_hit) recovered,
       countif(reference AND old_hit AND NOT new_hit) lost
FROM screening GROUP BY technology ORDER BY technology;

SELECT technology,baseline_reason,count(*) customers,countif(new_hit) new_hits
FROM reference_audit GROUP BY ALL ORDER BY technology,customers DESC;

SELECT technology,fold,countif(reference) reference_n,countif(reference AND old_hit) old_hits,
       countif(reference AND new_hit) new_hits FROM screening GROUP BY ALL ORDER BY technology,fold;

SELECT technology,id,baseline_reason,new_hit,round(l1,2) l1,round(l2,2) l2,
       round(plateau_any,2) all_day_plateau,round(heating_kw,2) heating,round(cooling_kw,2) cooling
FROM reference_audit WHERE old_hit=false
QUALIFY row_number() OVER (PARTITION BY technology,new_hit ORDER BY id)<=3
ORDER BY technology,new_hit DESC,id;
