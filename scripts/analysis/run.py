"""Run the three analytical stages against a read-only ODS database."""
import argparse
from pathlib import Path
import duckdb

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--input", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
if not args.input.is_file() or args.input.resolve() == args.output.resolve():
    parser.error("Provide an existing ODS file and a separate results file.")
with duckdb.connect(str(args.output)) as db:
    path = str(args.input.resolve()).replace("'", "''")
    db.execute(f"ATTACH '{path}' AS src (READ_ONLY)")
    db.execute("SET threads=12")
    db.execute("SET memory_limit='42GiB'")
    db.execute("BEGIN")
    for name in ("part1_2.sql", "part3.sql"):
        db.execute(Path(__file__).with_name(name).read_text())
    db.execute("COMMIT")
