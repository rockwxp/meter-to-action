#!/usr/bin/env bash
# Rebuild the unified submission database from the authorized source snapshot.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p database
db=database/meter_to_action.duckdb
duckdb -no-agent -bail "$db" < sql/ddl/ods/001_create_source_tables.sql
python scripts/ingest/ods/load_source_tables.py --database "$db" --source-dir "${1:-Data/sourcedata}"
duckdb -no-agent -readonly -bail "$db" < sql/quality/ods/001_check_source_tables.sql
python scripts/analysis/run.py --database "$db"
python scripts/analysis/part1/validate.py
duckdb -no-agent -bail "$db" < scripts/analysis/part1/winter_path.sql
duckdb -no-agent -bail "$db" < scripts/analysis/part1/finish.sql
duckdb -no-agent -bail "$db" < scripts/analysis/part2/segment.sql
duckdb -no-agent -bail "$db" < scripts/analysis/part3/assessment.sql
duckdb -no-agent -bail "$db" < sql/quality/verify_submission.sql
