-- Customer decision: one row per customer. Peak reductions are means over
-- the coincident system-peak hour of each evaluated event.
CREATE OR REPLACE VIEW customer_assessment AS
SELECT customer_id,
       (100.0 * priority / nullif(count(priority) OVER (), 0))::DECIMAL(6,3) AS peak_relief_top_pct,
       CASE WHEN events IS NULL THEN 'Insufficient data'
            WHEN dr_plan <> 'No DR' AND battery_kwh > 0 THEN dr_plan || ' + battery'
            WHEN battery_kwh > 0 THEN 'Battery only'
            WHEN dr_plan <> 'No DR' THEN dr_plan
            ELSE 'No qualifying measure' END AS recommended_action,
       shift_kwh::DECIMAL(12,2) AS dr_kwh_per_event,
       battery_kwh::DECIMAL(12,2) AS battery_size_kwh,
       battery_kw::DECIMAL(12,2) AS battery_power_kw,
       peak_cut_kw::DECIMAL(12,2) AS avg_peak_relief_kw
FROM assessment_values;

-- Modeled totals span the customer's evaluated events. Charging is grid-only.
CREATE OR REPLACE VIEW customer_event_impacts AS
SELECT customer_id, events AS event_count,
       before_kw::DECIMAL(12,2) AS avg_peak_import_before_kw,
       after_kw::DECIMAL(12,2) AS avg_peak_import_after_kw,
       peak_dr_kw::DECIMAL(12,2) AS avg_dr_peak_relief_kw,
       peak_bess_kw::DECIMAL(12,2) AS avg_battery_peak_relief_kw,
       shifted_total::DECIMAL(14,2) AS total_dr_shift_kwh,
       discharged_total::DECIMAL(14,2) AS total_battery_discharge_kwh,
       recharge_total::DECIMAL(14,2) AS total_grid_recharge_kwh,
       scenario_savings::DECIMAL(14,2) AS modeled_bill_savings_usd,
       study_hours AS hours_above_3kva_before,
       review_hours AS hours_above_3kva_after,
       known_pv AS pv_on_registry,
       CASE WHEN events IS NOT NULL THEN 0.00 END AS modeled_solar_charge_kwh,
       CASE bess_plan WHEN 'Size for pilot' THEN 'Within reference limits'
                      WHEN 'Partial coverage' THEN 'Reference limits exceeded'
                      ELSE bess_plan END AS battery_sizing_status
FROM assessment_values;
