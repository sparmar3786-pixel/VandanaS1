"""Read-only MCP server for strategy evidence and deterministic paper backtests.
No order-placement tools are exposed.
"""
from __future__ import annotations
import json, os
from mcp.server.fastmcp import FastMCP
from strategy_engine import run_backtest
from strategy_store import get_version

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(BASE_DIR, "data")

mcp = FastMCP("NSE Strategy Evidence MCP", stateless_http=True, json_response=True)

def _load_jsonl(name: str):
    path = os.path.join(DATA_DIR, name)
    if not os.path.exists(path): return []
    out=[]
    with open(path, encoding="utf-8") as f:
        for line in f:
            try: out.append(json.loads(line))
            except Exception: pass
    return out

@mcp.tool()
def get_option_chain(index: str) -> dict:
    """Return read-only local option-chain evidence; missing data is reported, never invented."""
    path=os.path.join(DATA_DIR, f"{index.upper()}_option_chain.json")
    if not os.path.exists(path): return {"index":index.upper(),"available":False,"rows":[]}
    with open(path,encoding="utf-8") as f: return json.load(f)

@mcp.tool()
def get_candles(symbol: str, tf: str, from_ts: str="", to_ts: str="") -> dict:
    """Return read-only historical candles from the local JSONL store."""
    rows=[x for x in _load_jsonl("candles.jsonl") if x.get("symbol")==symbol and x.get("tf")==tf]
    if from_ts: rows=[x for x in rows if str(x.get("timestamp",""))>=from_ts]
    if to_ts: rows=[x for x in rows if str(x.get("timestamp",""))<=to_ts]
    return {"symbol":symbol,"tf":tf,"rows":rows}

@mcp.tool()
def get_oi_snapshots(index: str, from_ts: str="", to_ts: str="") -> dict:
    """Return read-only saved OI snapshots; missing history is reported, not invented."""
    rows=[x for x in _load_jsonl("oi_snapshots.jsonl") if str(x.get("index","")).upper()==index.upper()]
    if from_ts: rows=[x for x in rows if str(x.get("timestamp",""))>=from_ts]
    if to_ts: rows=[x for x in rows if str(x.get("timestamp",""))<=to_ts]
    return {"index":index.upper(),"rows":rows,"history_available":bool(rows)}

@mcp.tool()
def run_backtest_tool(strategy_id: str, version: str, from_ts: str="", to_ts: str="") -> dict:
    """Run a deterministic paper backtest using stored candles; no live orders."""
    saved=get_version(strategy_id,version)
    if not saved: return {"ok":False,"error":"strategy version not found"}
    rows=[x for x in _load_jsonl("candles.jsonl") if x.get("symbol")==saved["strategy"]["index"] and x.get("tf")==saved["strategy"]["tf"]]
    if from_ts: rows=[x for x in rows if str(x.get("timestamp",""))>=from_ts]
    if to_ts: rows=[x for x in rows if str(x.get("timestamp",""))<=to_ts]
    result=run_backtest(saved["strategy"],rows)
    return {"ok":True,"metrics":result.metrics,"trades":result.trades[:30],"equity_curve":result.equity_curve}

@mcp.tool()
def get_signal_context(index: str) -> dict:
    """Return read-only engine evidence for the selected index."""
    path=os.path.join(DATA_DIR,"signal_context.json")
    if not os.path.exists(path): return {"index":index.upper(),"available":False}
    with open(path,encoding="utf-8") as f: data=json.load(f)
    return data.get(index.upper(),{"index":index.upper(),"available":False})

def mount_strategy_mcp(app):
    try:
        mcp_app=mcp.http_app(path="/")
    except AttributeError:
        mcp_app=mcp.streamable_http_app()
    app.mount("/mcp-strategy",mcp_app)
    return mcp_app

if __name__=="__main__":
    mcp.run()
