"""Run the three analytical stages using the ODS schema of the unified database."""
import argparse
from pathlib import Path
import duckdb

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--database", type=Path, required=True)
args = parser.parse_args()
with duckdb.connect(str(args.database)) as db:
    db.execute("SET threads=12")
    db.execute("SET memory_limit='42GiB'")
    db.execute("BEGIN")
    for name in ("part1_2.sql", "part3.sql"):
        db.execute(Path(__file__).with_name(name).read_text())
    db.execute("COMMIT")
