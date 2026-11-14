#!/usr/bin/env bash
# Rebuild the three submission databases from the authorized source snapshot.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p database
duckdb -no-agent -bail database/meter_to_action.duckdb < sql/ddl/ods/001_create_source_tables.sql
python scripts/ingest/ods/load_source_tables.py --database database/meter_to_action.duckdb --source-dir "${1:-Data/sourcedata}"
duckdb -no-agent -readonly -bail database/meter_to_action.duckdb < sql/quality/ods/001_check_source_tables.sql
python scripts/analysis/run.py --input database/meter_to_action.duckdb --output database/analysis_results.duckdb
python scripts/analysis/part1/validate.py
duckdb -no-agent -bail database/part1_validation.duckdb < scripts/analysis/part1/winter_path.sql
duckdb -no-agent -bail database/part1_final.duckdb < scripts/analysis/part1/finish.sql
duckdb -no-agent -bail database/part2_final.duckdb < scripts/analysis/part2/segment.sql
duckdb -no-agent -bail database/part3_assessment.duckdb < scripts/analysis/part3/assessment.sql
duckdb -no-agent -bail < sql/quality/verify_submission.sql
