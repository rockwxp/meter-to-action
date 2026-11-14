# EV and heat pump validation

From the repository root, run the existing baseline analysis first, then run
`python scripts/analysis/part1/validate.py` and
`duckdb -readonly database/meter_to_action.duckdb < scripts/analysis/part1/report.sql`.
Runtime versions: DuckDB 2.0.0, NumPy 2.5.4 and scikit-learn 1.9.1.
Use --database to override the warehouse location.

Each technology uses stratified five-fold customer splits with a fixed seed.
Within each fold, review as many customers as the original rule selected.
Each customer's score is produced by a model trained only on other customers.
Reference membership is the target; unlisted households are unlabeled.
Use scores for ranking within folds, not as ownership probabilities.
The reference samples cover likely ownership, not EV charge levels or heating subtypes.

The screening table contains all eligible customers and fold assignments.
The reference_audit table includes every listed customer, measured rule inputs,
baseline miss reason, and out-of-fold selection. Examine all missed IDs with:

```sql
SELECT * FROM validation.reference_audit WHERE old_hit IS FALSE ORDER BY technology, id;
```

All-day plateau is the fraction of observed days with any consecutive pair
above 3.3 kW differing by less than 0.7 kW. Step frequency measures days
with a rise of at least 3 kW sustained above the previous baseline by at least
2.5 kW for the next hour. An event is assigned to its starting day.
Weather-response features derive from daily means and observed reference bands.
Missing seasonal features are passed to the estimator as NaN.

## Final customer-level inventory

Run the following from the repository root after the baseline and five-fold
validation stages. Keep all stages on the same source snapshot.

```sh
duckdb -bail database/meter_to_action.duckdb < scripts/analysis/part1/winter_path.sql
duckdb -bail database/meter_to_action.duckdb < scripts/analysis/part1/finish.sql
duckdb -readonly database/meter_to_action.duckdb
```

Use `customer_devices` as the Part 1 entry point. It has exactly one row for
each customer number in the challenge population. Reference membership is
preserved independently of AMI eligibility. Missing screening results are
unknown. EV charge-level hints apply only to selected EV candidates.
Rank scores order candidates; they are not calibrated ownership probabilities.

The broad appliance screens retain the annual rules. For higher-specificity
review, use the annual screen plus three successful weekly repeats for water
heating, hot tubs and PV storage. For pool timers use three successful
timer repeats. These are repeatable load signatures, not device ground truth.
The weekly folds share training weeks: three successes are not independent
replications. Query `rule_validation` for fold-level counts; `appliance_holdout`
retains per-customer train and test flags. A PV control can be reused, and
overnight-load matching does not control for PV array capacity or occupancy.
