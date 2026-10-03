"""Immutable strategy versions and approval metadata using SQLite."""
from __future__ import annotations
import json, sqlite3, time, os

DB_PATH=os.getenv("STRATEGY_DB","data/strategies.sqlite3")

def _db():
    os.makedirs(os.path.dirname(DB_PATH) or ".",exist_ok=True)
    c=sqlite3.connect(DB_PATH)
    c.execute("""CREATE TABLE IF NOT EXISTS strategies(
      id TEXT NOT NULL, version TEXT NOT NULL, strategy_json TEXT NOT NULL,
      train_metrics TEXT, test_metrics TEXT, approval TEXT NOT NULL,
      created_at REAL NOT NULL, PRIMARY KEY(id,version))""")
    c.commit()
    return c

def save_version(strategy, train_metrics, test_metrics, approval):
    sid=str(strategy["id"]); version=str(strategy.get("version","v1"))
    c=_db()
    try:
        c.execute("INSERT INTO strategies VALUES(?,?,?,?,?,?,?)",
                  (sid,version,json.dumps(strategy,separators=(",",":")),
                   json.dumps(train_metrics,separators=(",",":")),
                   json.dumps(test_metrics,separators=(",",":")),
                   json.dumps(approval,separators=(",",":")),time.time()))
        c.commit()
    finally: c.close()
    return {"id":sid,"version":version,"immutable":True}

def get_version(strategy_id, version):
    c=_db()
    try:
        row=c.execute("SELECT strategy_json,train_metrics,test_metrics,approval,created_at FROM strategies WHERE id=? AND version=?",
                      (strategy_id,version)).fetchone()
        if not row: return None
        return {"strategy":json.loads(row[0]),"train_metrics":json.loads(row[1]),
                "test_metrics":json.loads(row[2]),"approval":json.loads(row[3]),"created_at":row[4]}
    finally: c.close()


def save_oi_snapshot(index, snapshot):
    """Persist one read-only option-chain snapshot for future OI backtests."""
    c=_db()
    try:
        c.execute("""CREATE TABLE IF NOT EXISTS oi_snapshots(
          id INTEGER PRIMARY KEY AUTOINCREMENT, idx TEXT NOT NULL,
          ts REAL NOT NULL, snapshot_json TEXT NOT NULL)""")
        c.execute("INSERT INTO oi_snapshots(idx,ts,snapshot_json) VALUES(?,?,?)",
                  (str(index).upper(), float(snapshot.get("ts",time.time())),
                   json.dumps(snapshot,separators=(",",":"),default=str)))
        c.commit()
    finally: c.close()

def get_oi_snapshots(index, from_ts=0.0, to_ts=0.0):
    c=_db()
    try:
        c.execute("""CREATE TABLE IF NOT EXISTS oi_snapshots(
          id INTEGER PRIMARY KEY AUTOINCREMENT, idx TEXT NOT NULL,
          ts REAL NOT NULL, snapshot_json TEXT NOT NULL)""")
        q="SELECT ts,snapshot_json FROM oi_snapshots WHERE idx=?"
        args=[str(index).upper()]
        if from_ts:
            q+=" AND ts>=?"; args.append(float(from_ts))
        if to_ts:
            q+=" AND ts<=?"; args.append(float(to_ts))
        q+=" ORDER BY ts ASC"
        rows=[]
        for ts,payload in c.execute(q,args).fetchall():
            try: rows.append(json.loads(payload))
            except Exception: pass
        return rows
    finally: c.close()
