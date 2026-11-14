"""Load the 2026 hackathon source snapshot into an empty DuckDB ODS schema."""

import argparse
import csv
import os
from collections import Counter
from contextlib import closing
from pathlib import Path

import duckdb
from openpyxl import load_workbook


EXPECTED_ROWS = {
    "ami_hourly": 306_671_987,
    "weather_hourly": 8_761,
    "ev_customers": 200,
    "hp_customers": 100,
    "pv_customers": 434,
}

AMI_TYPES = {
    "customer_number": "INTEGER",
    "usage_date": "DATE",
    "hour_ending": "SMALLINT",
    "day_type": "VARCHAR",
    "hourly_kwh": "DOUBLE",
    "interval_count": "SMALLINT",
    "interval_type": "VARCHAR",
    "is_complete_hour": "SMALLINT",
}

DEVICE_SHEETS = {
    "EV Customers": "ev_customers",
    "HP Customers": "hp_customers",
    "PV Customers": "pv_customers",
}


def check_header(header, expected, source):
    if tuple(str(cell).strip().lower() for cell in header) != tuple(expected):
        raise ValueError(f"Unexpected header in {source}: {header}")


def load_sheet(db, sheet, table, source_columns, target_columns):
    rows = sheet.iter_rows()
    check_header([cell.value for cell in next(rows, ())], source_columns, sheet.title)
    records = []
    errors = Counter()
    for row in rows:
        record = []
        for column, cell in zip(target_columns, row, strict=True):
            if cell.data_type == "e" and table == "weather_hourly" and column in ("temp", "humidity", "windspeed"):
                errors[column, cell.value] += 1
                record.append(None)
            else:
                record.append(cell.value)
        records.append(record)
    for (column, error), count in errors.items():
        print(f"ods.{table}.{column}: mapped {count} Excel {error} values to NULL")
    placeholders = ", ".join("?" for _ in target_columns)
    columns = ", ".join(target_columns)
    db.executemany(f"INSERT INTO ods.{table} ({columns}) VALUES ({placeholders})", records)


def load(database, source):
    if not database.is_file():
        raise FileNotFoundError(f"Expected an initialized ODS database at {database}. Use --database.")
    with duckdb.connect(str(database), read_only=True) as db:
        counts = {
            table: db.execute(f"SELECT count(*) FROM ods.{table}").fetchone()[0]
            for table in EXPECTED_ROWS
        }
    if counts == EXPECTED_ROWS:
        print("All five ODS row counts match the expected snapshot. Skipping import.")
        for table, count in counts.items():
            print(f"ods.{table}: {count:,}")
        return
    if any(counts.values()):
        raise ValueError(f"ODS contains unexpected row counts. Load cancelled: {counts}")
    if not source.is_dir():
        raise FileNotFoundError(f"Source directory not found: {source}. Use --source-dir.")
    files = sorted(source.glob("2026 Avangrid Hackathon Data_*/part-*.csv"))
    if len(files) != 204:
        raise ValueError(f"Expected 204 AMI CSV files, found {len(files)}")
    for path in files:
        with path.open(encoding="utf-8-sig", newline="") as stream:
            check_header(next(csv.reader(stream), ()), AMI_TYPES, path)

    with duckdb.connect(str(database)) as db:
        db.execute("SET threads = 16")
        db.execute("SET memory_limit = '48GiB'")
        db.execute("BEGIN TRANSACTION")
        try:
            for table in EXPECTED_ROWS:
                if db.execute(f"SELECT 1 FROM ods.{table} LIMIT 1").fetchone():
                    raise ValueError(f"ods.{table} already contains data. Load cancelled.")

            weather = source / "Weather Data_Avangrid_Hackathon .xlsx"
            with closing(load_workbook(weather, read_only=True, data_only=True)) as book:
                load_sheet(db, book["Sheet1"], "weather_hourly",
                           ("date", "time", "temp", "humidity", "windspeed"),
                           ("observation_date", "observation_time", "temp", "humidity", "windspeed"))

            devices = source / "EV_Heat Pump_Solar PV Customers.xlsx"
            with closing(load_workbook(devices, read_only=True, data_only=True)) as book:
                for sheet, table in DEVICE_SHEETS.items():
                    load_sheet(db, book[sheet], table, ("customer_number",), ("customer_number",))

            print(f"Loading {len(files)} AMI CSV files.", flush=True)
            db.execute("""
                INSERT INTO ods.ami_hourly BY NAME
                SELECT * FROM read_csv(
                    ?, columns = ?, header = true, auto_detect = false,
                    delim = ',', filename = false, ignore_errors = false
                )
            """, [[str(path) for path in files], AMI_TYPES])

            mismatches = []
            for table, expected in EXPECTED_ROWS.items():
                actual = db.execute(f"SELECT count(*) FROM ods.{table}").fetchone()[0]
                print(f"ods.{table}: expected {expected:,}, loaded {actual:,}", flush=True)
                if actual != expected:
                    mismatches.append(table)
            if mismatches:
                raise ValueError(f"Row count mismatch: {', '.join(mismatches)}")
            db.execute("COMMIT")
        except BaseException:
            db.rollback()
            raise
    print("ODS load committed.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", type=Path, help="Override the DuckDB file path.")
    parser.add_argument("--source-dir", type=Path, help="Override the extracted source directory.")
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[3]
    # Keep the legacy external layout available when explicitly configured.
    external_home = os.environ.get("METER_TO_ACTION_HOME")
    data_root = Path(external_home).expanduser() if external_home else repo_root
    default_database = (data_root if external_home else repo_root / "database") / "meter_to_action.duckdb"
    database = (args.database or default_database).expanduser().resolve()
    source = (args.source_dir or data_root / "Data" / "sourcedata").expanduser().resolve()
    print(f"Database: {database}\nSource:   {source}", flush=True)
    try:
        load(database, source)
    except (FileNotFoundError, ValueError, duckdb.Error) as error:
        parser.exit(1, f"Load failed: {error}\n")
