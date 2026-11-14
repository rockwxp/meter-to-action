# Meter to Action

2026 Avangrid Energy Innovation Hackathon. This repository turns one year of residential hourly meter readings into three customer-level decisions: probable equipment, load behavior and demand flexibility or battery opportunities.

## Reproduce the analysis

Tested on Linux with Python 3.13 and DuckDB 2.0.0. The largest queries use up to 12–16 threads and are configured with 40–48 GiB DuckDB memory limits. Use local disk with room for intermediate databases and temporary files.

From the repository root:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
bash scripts/run_pipeline.sh
```

Place the authorized, extracted dataset under `Data/sourcedata/`, or pass its path as the sole argument to the pipeline. Preserve the supplied directory, workbook and sheet names. The loader reads the 204 AMI CSV files and two Excel workbooks, including the supplementary CSV directory. Distribution archives are ignored. Keep the event data and customer-level databases local. Close interactive database sessions before rebuilding.

The loader checks the supplied snapshot counts and preserves observations, including repeated weather timestamps. Numeric Excel errors are recorded as NULL. On rerun, matching ODS counts skip ingestion; this checks row counts, not file identity. For a different source snapshot, use a fresh working directory and revise the snapshot-specific checks.

## Query a customer

After the build, run these commands from the repository root. Replace 6233 with another customer number.

```bash
duckdb -readonly database/meter_to_action.duckdb
```

In this single session, query all three schemas:

```sql
SELECT * FROM part1.customer_characteristics WHERE customer_id = 6233;
SELECT * FROM part2.customer_profile WHERE customer_id = 6233;
SELECT * FROM part3.customer_assessment WHERE customer_id = 6233;
```

The database lives under `database/`. The `ods` schema holds source tables, `intermediate` holds shared features, and `validation` holds model validation. The three `partN` schemas expose the outputs. Earlier standalone analysis files from the local migration are archived under `database/legacy/`.

| Output | Method | Interpretation |
|---|---|---|
| Part 1: customer characteristics | Rank EV and heat pump candidates with customer-held-out models, use the known PV registry, and screen other devices using weather contrasts and repeated hourly patterns. | One row per customer and characteristic. Scores from 0 to 10 express ordinal evidence. Equipment probabilities have not been calibrated. A score of 5 can indicate insufficient evidence. |
| Part 2: customer profile | Apply ordered load-shape and seasonal rules, then compare assignments on alternating weeks. | One row per customer, with behavior segment, average night/midday/evening load and observed demand during the population peak. |
| Part 3: customer assessment | Screen winter and summer coincident peaks, simulate demand shifting, size storage against remaining demand and replay the portfolio including rebound and charging losses. | One row per customer. Smaller peak-relief top percentages indicate higher priority. Capacity, power and peak reduction have distinct units. |

## Methods and checks

- **ODS:** `sql/ddl/ods/` defines the tables, `scripts/ingest/ods/` loads the data, and `sql/quality/ods/` checks duplicates, coverage, weather and reference-list linkage. The expected snapshot includes 306,671,987 AMI records and 8,761 weather records.
- **Part 1:** `scripts/analysis/part1_2.sql` builds daily and customer features. `scripts/analysis/part1/` contains model validation, the winter heat pump path, appliance holdouts and the final score view. See the [Part 1 methodology](scripts/analysis/part1/README.md). To reproduce the thermal threshold sensitivity tables, run `duckdb -bail database/meter_to_action.duckdb < scripts/analysis/part1/validate_thermal.sql` after building. Customers outside the EV and heat pump samples are unlabeled; load-signature repeatability measures behavioral stability.
- **Part 2:** `scripts/analysis/part2/segment.sql` produces 24-hour group profiles, alternating-week agreement, and contributions at the 100 highest population hours. Missing AMI and limited seasonal history receive separate labels.
- **Part 3:** `scripts/analysis/part3/opportunity.sql` evaluates 20 winter and 20 summer events. Storage is limited to 20.16 kWh and 7.68 kW, with a 90% usable energy window and 89.4% round-trip efficiency. `customer_event_impacts` reports the breakdown, including illustrative energy-charge savings at $0.30/kWh peak and $0.10/kWh recharge. The service-capacity scenario assumes 4 kW of incremental load and unity power factor. Actual tariffs, service headroom and solar surplus are unavailable. Rankings and impacts are historical scenario estimates.
- **Intermediate results:** `intermediate` contains the shared features and exploratory baselines. Use the three final schemas above for submission results. The same ID can carry multiple device signatures and exactly one behavior segment.

The pipeline performs stage-level reconciliation. Run `duckdb -bail database/meter_to_action.duckdb < sql/quality/verify_submission.sql` after a build to check the final customer grain, ID alignment, score bounds, and candidate rank direction.
