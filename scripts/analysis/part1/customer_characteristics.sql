USE part1;
-- Ordinal ownership evidence, not calibrated probabilities.
-- 0/10 require confirmed absence/presence. 5 is indeterminate.
-- No confirmed device-absence labels exist in this snapshot.
CREATE OR REPLACE VIEW customer_characteristics AS
WITH scores AS (
    SELECT *, CASE WHEN hp_reference AND hp_candidate THEN 9
                   WHEN hp_reference THEN 8 WHEN hp_candidate THEN 7
                   WHEN hp_candidate IS FALSE THEN 3 ELSE 5 END hp,
              CASE WHEN ev_reference AND ev_candidate THEN 9
                   WHEN ev_reference THEN 8 WHEN ev_candidate THEN 7
                   WHEN ev_candidate IS FALSE THEN 3 ELSE 5 END ev
    FROM customer_devices
)
SELECT id AS customer_id, characteristic, score::UTINYINT AS score_0_to_10, evidence
FROM scores, LATERAL (VALUES
 (1,'EV charging',ev,CASE WHEN ev=9 THEN 'EV list + model' WHEN ev=8 THEN 'Likely EV list' WHEN ev=7 THEN 'EV model' WHEN ev=3 THEN 'No model hit' ELSE 'Insufficient history' END),
 (2,'EV Level 1',CASE WHEN ev_level_hint='L1-like' THEN 7 WHEN ev=3 THEN 3 ELSE 5 END,
   CASE WHEN ev_level_hint='L1-like' THEN 'Low-power plateau' WHEN ev=3 THEN 'No EV model hit' ELSE 'Level undetermined' END),
 (3,'EV Level 2',CASE WHEN ev_level_hint='L2-like' THEN 7 WHEN ev=3 THEN 3 ELSE 5 END,
   CASE WHEN ev_level_hint='L2-like' THEN 'High-power plateau' WHEN ev=3 THEN 'No EV model hit' ELSE 'Level undetermined' END),
 (4,'Heat pump',hp,CASE WHEN hp=9 THEN 'HP list + model' WHEN hp=8 THEN 'Likely HP list' WHEN hp=7 THEN hp_path || ' model' WHEN hp=3 THEN 'No model hit' ELSE 'Insufficient history' END),
 (5,'Air conditioning',CASE WHEN cooling_candidate THEN 7 WHEN cooling_candidate IS FALSE THEN 3 ELSE 5 END,
   CASE WHEN cooling_candidate THEN 'Hot-day load rise' WHEN cooling_candidate IS FALSE THEN 'Below cooling threshold' ELSE 'Insufficient evidence' END),
 (6,'Strong electric heating',CASE WHEN strong_electric_heating_candidate THEN 7 WHEN strong_electric_heating_candidate IS FALSE THEN 3 ELSE 5 END,
   CASE WHEN strong_electric_heating_candidate THEN 'Two cold-band rises' WHEN strong_electric_heating_candidate IS FALSE THEN 'Below heating threshold' ELSE 'Insufficient evidence' END),
 (7,'Resistance heating',CASE WHEN strong_electric_heating_candidate THEN 5 WHEN strong_electric_heating_candidate IS FALSE THEN 3 ELSE 5 END,
   CASE WHEN strong_electric_heating_candidate THEN 'Heater type unresolved' WHEN strong_electric_heating_candidate IS FALSE THEN 'No strong heating signal' ELSE 'Insufficient evidence' END),
 (8,'Electric water heater',CASE WHEN water_heater_screen THEN 6+coalesce(water_rep,0)//2 WHEN water_heater_screen IS FALSE THEN 3 ELSE 5 END,
   CASE WHEN water_heater_screen THEN 'Morning pulses: ' || coalesce(water_rep,0) || '/3 repeats' WHEN water_heater_screen IS FALSE THEN 'No morning signature' ELSE 'Insufficient evidence' END),
 (9,'Pool pump',CASE WHEN pool_timer_repeats=3 THEN 8 WHEN pool_timer_repeats>0 THEN 7 WHEN seasonal_pool_screen THEN 6 WHEN seasonal_pool_screen IS FALSE THEN 3 ELSE 5 END,
   CASE WHEN pool_timer_repeats>0 THEN 'Timer: ' || pool_timer_repeats || '/3 repeats' WHEN seasonal_pool_screen THEN 'Seasonal plateau' WHEN seasonal_pool_screen IS FALSE THEN 'No seasonal signature' ELSE 'Insufficient evidence' END),
 (10,'Hot tub',CASE WHEN hot_tub_screen THEN 6+coalesce(tub_rep,0)//2 WHEN hot_tub_screen IS FALSE THEN 3 ELSE 5 END,
   CASE WHEN hot_tub_screen THEN 'Night cycles: ' || coalesce(tub_rep,0) || '/3 repeats' WHEN hot_tub_screen IS FALSE THEN 'No cycling signature' ELSE 'Insufficient evidence' END),
 (11,'Solar PV',CASE WHEN known_pv THEN 10 ELSE 1 END,CASE WHEN known_pv THEN 'Known PV registry' ELSE 'Absent from PV registry' END),
 (12,'Solar PV with battery',CASE WHEN NOT known_pv THEN 1 WHEN pv_storage_screen THEN 6+coalesce(pv_rep,0)//2 WHEN pv_storage_screen IS FALSE THEN 3 ELSE 5 END,
   CASE WHEN NOT known_pv THEN 'Absent from PV registry' WHEN pv_storage_screen THEN 'PV load: ' || coalesce(pv_rep,0) || '/3 repeats' WHEN pv_storage_screen IS FALSE THEN 'No storage signature' ELSE 'Insufficient evidence' END)
) v(position,characteristic,score,evidence)
ORDER BY customer_id,score_0_to_10 DESC,position;
