"""Compare EV and HP screening at identical review budgets using out-of-fold predictions."""
import argparse
import os
from pathlib import Path

os.environ.setdefault("OMP_NUM_THREADS", "4")
import duckdb
import numpy as np
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.model_selection import StratifiedKFold

ROOT = Path(__file__).resolve().parents[3]
EV = "l1 l2 night_share base_kw mild step3 step5 evening_step night_step plateau_any peak90 peak50".split()
HP = "heating_kw cooling_kw extreme_kw winter summer mild winter_slope winter_corr summer_slope shoulder_heat cold_base cold_night".split()


def evaluate(db, tech, columns):
    rule = "ev_l1_signature OR ev_l2_signature" if tech == "ev" else "hp_signature"
    sql = f"""SELECT id, {tech}_reference, ({rule}) IS TRUE, {', '.join(columns)}
              FROM signals WHERE sufficient_history ORDER BY id"""
    rows = db.execute(sql).fetchall()
    ids = np.array([r[0] for r in rows])
    y = np.array([r[1] for r in rows], dtype=int)
    old = np.array([r[2] for r in rows])
    x = np.asarray([r[3:] for r in rows], dtype=float)
    predictions = []
    for fold, (train, test) in enumerate(StratifiedKFold(5, shuffle=True, random_state=2026).split(x, y)):
        # Unlisted households provide comparison examples, including unknown positives.
        model = HistGradientBoostingClassifier(max_iter=65, max_leaf_nodes=7, min_samples_leaf=70,
                                               l2_regularization=8, random_state=2026)
        model.fit(x[train], y[train], sample_weight=np.where(y[train], 20., 1.))
        scores = model.predict_proba(x[test])[:, 1]
        budget = old[test].sum()
        ranked = np.lexsort((ids[test], -scores))
        selected = np.zeros(len(test), dtype=bool)
        selected[ranked[:budget]] = True
        predictions.extend((tech,int(ids[i]), fold, bool(y[i]),bool(old[i]), bool(selected[j]),float(scores[j]))
                           for j,i in enumerate(test))
    db.executemany("INSERT INTO screening VALUES (?, ?, ?, ?, ?, ?, ?)", predictions)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", type=Path, default=ROOT/"database/meter_to_action.duckdb")
    args = parser.parse_args()
    with duckdb.connect(str(args.database)) as db:
        db.execute("USE validation")
        db.execute("SET threads=12")
        db.execute("SET memory_limit='42GiB'")
        db.execute("BEGIN")
        db.execute(Path(__file__).with_name("signals.sql").read_text())
        db.execute("""CREATE OR REPLACE TABLE signals AS SELECT f.*,c.* EXCLUDE(id,hours),
                      e.* EXCLUDE(id),h.* EXCLUDE(id) FROM intermediate.features f
                      JOIN intermediate.classification c USING(id) JOIN extra_ev e USING(id)
                      LEFT JOIN extra_hp h USING(id)""")
        db.execute("""CREATE OR REPLACE TABLE screening(technology VARCHAR,id INTEGER,fold INTEGER,
                      reference BOOLEAN,old_hit BOOLEAN,new_hit BOOLEAN,ranking_score DOUBLE)""")
        evaluate(db,"ev",EV)
        evaluate(db,"hp",HP)
        db.execute("""CREATE OR REPLACE TABLE reference_audit AS
          WITH labels AS (SELECT 'ev' technology,customer_number id FROM ods.ev_customers
                          UNION ALL SELECT 'hp',customer_number FROM ods.hp_customers)
          SELECT l.*,f.hours,s.fold,s.old_hit,s.new_hit,s.ranking_score,f.l1,f.l2,f.plateau_any,
                 f.evening_step,f.step3,f.heating_kw,f.cooling_kw,f.winter_corr,
            CASE WHEN f.id IS NULL THEN 'Missing AMI'
                 WHEN NOT f.sufficient_history THEN 'Short history'
                 WHEN s.old_hit THEN 'Baseline hit'
                 WHEN l.technology='ev' AND f.plateau_any>=0.08 THEN 'All-day plateau, overnight thresholds missed'
                 WHEN l.technology='ev' AND f.step3>=0.08 THEN 'Repeated steps, overnight thresholds missed'
                 WHEN l.technology='ev' THEN 'Sparse or weak measured signatures'
                 WHEN f.heating_kw IS NULL OR f.cooling_kw IS NULL THEN 'Missing seasonal contrast'
                 WHEN f.heating_kw<0.65 AND f.cooling_kw<0.35 THEN 'Both contrasts below thresholds'
                 WHEN f.heating_kw<0.65 THEN 'Heating contrast below threshold'
                 ELSE 'Cooling contrast below threshold' END baseline_reason
          FROM labels l LEFT JOIN signals f USING(id) LEFT JOIN screening s USING(technology,id)""")
        db.execute("COMMIT")

if __name__ == "__main__":
    main()
