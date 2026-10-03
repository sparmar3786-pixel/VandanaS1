"""Shared NSE/Angel market core.
One process, one in-memory snapshot store. Writers: NSE poll + Angel WS/REST.
Readers: APK REST endpoints + MCP tools. No order placement.
"""
from __future__ import annotations
import os, time, threading
from copy import deepcopy
from fastapi import APIRouter, Header, HTTPException
from mcp.server.fastmcp import FastMCP

INDICES=("NIFTY","BANKNIFTY","FINNIFTY","MIDCPNIFTY","SENSEX","BANKEX")
STALE_SEC=float(os.getenv("MARKET_STALE_SEC","15"))
MCP_AUTH=os.getenv("MCP_AUTH_TOKEN","").strip()
LOCK=threading.RLock()
STORE={}
COMMODITY_STORE={"rows":[],"ts":0.0,"source":None}

def _now(): return time.time()

def _idx(index):
    s=str(index or "NIFTY").upper().replace(" ","")
    aliases={"NIFTY50":"NIFTY","NIFTYBANK":"BANKNIFTY","BANKNIFTY":"BANKNIFTY",
             "BANKNIFTY":"BANKNIFTY","FINNIFTY":"FINNIFTY","MIDCAPSELECT":"MIDCPNIFTY",
             "MIDCPNIFTY":"MIDCPNIFTY","SENSEX":"SENSEX","BANKEX":"BANKEX"}
    return aliases.get(s,s)

def _ensure(index):
    index=_idx(index)
    return STORE.setdefault(index,{"spot":None,"atm":None,"expiry":None,"ts":0.0,
                                   "source_ts":{},"source":None,"rows":{}})

def _fresh(ts):
    return bool(ts and (_now()-float(ts)) <= STALE_SEC)

def put(index,strike,side,src,ts=None,**values):
    index=_idx(index); side=str(side).upper()
    if side not in ("CE","PE"): return False
    try: strike=float(strike)
    except Exception: return False
    incoming=float(ts or _now())
    with LOCK:
        idx=_ensure(index); row=idx["rows"].setdefault(strike,{})
        leg=row.setdefault(side,{"ts":0.0,"source":None})
        # Per-leg monotonic timestamp: an older NSE response cannot erase a newer WS tick.
        if incoming < float(leg.get("ts",0.0)): return False
        clean={k:v for k,v in values.items() if v is not None}
        leg.update(clean); leg["ts"]=incoming; leg["source"]=src
        idx["ts"]=max(float(idx.get("ts",0)),incoming)
        idx["source"]=src
    return True

def put_spot(index,spot,src,ts=None,atm=None,expiry=None):
    index=_idx(index); incoming=float(ts or _now())
    with LOCK:
        idx=_ensure(index)
        if incoming < float(idx.get("source_ts",{}).get("spot",0.0)): return False
        if spot is not None: idx["spot"]=float(spot)
        if atm is not None: idx["atm"]=float(atm)
        if expiry is not None: idx["expiry"]=expiry
        idx["source_ts"]["spot"]=incoming; idx["source"]=src; idx["ts"]=max(idx["ts"],incoming)
    return True

def ingest_chain(payload,src):
    if not isinstance(payload,dict): return 0
    index=_idx(payload.get("symbol") or payload.get("index") or "NIFTY")
    ts=float(payload.get("ts") or _now())
    put_spot(index,payload.get("spot"),src,ts,payload.get("atm"),payload.get("expiry"))
    n=0
    for r in payload.get("rows",[]) or []:
        side=r.get("type") or r.get("side")
        if side:
            n += int(put(index,r.get("strike"),side,src,ts,
                         ltp=r.get("ltp"),oi=r.get("oi"),volume=r.get("volume") or r.get("vol"),
                         open=r.get("open"),high=r.get("high"),low=r.get("low"),close=r.get("close"),
                         oiChangePct=r.get("oiChangePct"),chg_oi=r.get("chg_oi"),
                         symbol=r.get("symbol"),token=r.get("token")))
    return n

def snapshot(index,include_stale=True):
    index=_idx(index)
    now=_now()
    with LOCK:
        idx=deepcopy(_ensure(index))
    rows=[]
    for strike,legs in sorted(idx["rows"].items()):
        for side,leg in legs.items():
            ts=float(leg.get("ts",0)); age=max(0.0,now-ts) if ts else None
            if include_stale or (age is not None and age<=STALE_SEC):
                x=dict(leg); x.update({"strike":float(strike),"type":side,"age_s":round(age,2) if age is not None else None,
                                       "stale":not _fresh(ts)})
                rows.append(x)
    data_ts=float(idx.get("ts",0)); age=max(0.0,now-data_ts) if data_ts else None
    valid_rows=sum(1 for x in rows if not x["stale"])
    data_ok=bool(idx.get("spot") is not None and valid_rows>0 and _fresh(data_ts))
    return {"index":index,"spot":idx.get("spot"),"atm":idx.get("atm"),"expiry":idx.get("expiry"),
            "ts":data_ts,"age_s":round(age,2) if age is not None else None,"stale":not _fresh(data_ts),
            "data_ok":data_ok,"source":idx.get("source"),"rows":rows}

def evidence(index):
    s=snapshot(index,True); rows=s["rows"]
    ce=[r for r in rows if r["type"]=="CE" and not r["stale"]]
    pe=[r for r in rows if r["type"]=="PE" and not r["stale"]]
    ce_oi=sum(float(r.get("oi") or 0) for r in ce); pe_oi=sum(float(r.get("oi") or 0) for r in pe)
    pcr=(pe_oi/ce_oi) if ce_oi else None
    top_ce=sorted(ce,key=lambda r:float(r.get("oi") or 0),reverse=True)[:5]
    top_pe=sorted(pe,key=lambda r:float(r.get("oi") or 0),reverse=True)[:5]
    return {"index":s["index"],"data_ok":s["data_ok"],"age_s":s["age_s"],"source":s["source"],
            "spot":s["spot"],"atm":s["atm"],"expiry":s["expiry"],"pcr":pcr,
            "ce_oi":ce_oi,"pe_oi":pe_oi,
            "top_ce_oi":[{"strike":x["strike"],"oi":x.get("oi"),"ltp":x.get("ltp")} for x in top_ce],
            "top_pe_oi":[{"strike":x["strike"],"oi":x.get("oi"),"ltp":x.get("ltp")} for x in top_pe],
            "fresh_rows":len(ce)+len(pe),"total_rows":len(rows)}

router=APIRouter()
@router.get("/api/chain/{index}")
def api_chain(index:str):
    return snapshot(index,True)

@router.get("/api/evidence/{index}")
def api_evidence(index:str):
    return evidence(index)

@router.get("/api/market-core/health")
def core_health():
    with LOCK: counts={k:len(v["rows"]) for k,v in STORE.items()}
    return {"ok":True,"store_indexes":counts,"stale_sec":STALE_SEC,"mcp_auth_configured":bool(MCP_AUTH)}

mcp=FastMCP("NSE Market Core", stateless_http=True, json_response=True)

@mcp.tool()
def get_chain(index:str="NIFTY")->dict:
    """Read the latest shared option-chain snapshot. No external call."""
    return snapshot(index,True)

@mcp.tool()
def get_evidence(index:str="NIFTY")->dict:
    """Read compact engine evidence from the same shared snapshot. No external call."""
    return evidence(index)

@mcp.tool()
def get_commodities()->dict:
    """Read the latest shared MCX commodity snapshot populated by the server."""
    return commodity_snapshot()

def mcp_auth_ok(token):
    return bool(MCP_AUTH) and token==MCP_AUTH

def require_mcp_auth(x_mcp_token=None, authorization=None):
    token=x_mcp_token
    if not token and authorization and authorization.lower().startswith("bearer "):
        token=authorization[7:].strip()
    if not mcp_auth_ok(token):
        raise HTTPException(401,"MCP authentication required")

def mount_mcp(app):
    # FastMCP's HTTP app is mounted into the existing FastAPI process.
    # The outer middleware below protects every /mcp request with MCP_AUTH_TOKEN.
    try:
        mcp_app=mcp.http_app(path="/")
    except AttributeError:
        mcp_app=mcp.streamable_http_app()
    app.mount("/mcp",mcp_app)
    return mcp_app

def install_mcp_auth(app):
    @app.middleware("http")
    async def _mcp_guard(request,call_next):
        if request.url.path.startswith("/mcp"):
            token=request.headers.get("x-mcp-token")
            auth=request.headers.get("authorization","")
            if not mcp_auth_ok(token or (auth[7:].strip() if auth.lower().startswith("bearer ") else "")):
                from fastapi.responses import JSONResponse
                return JSONResponse({"detail":"MCP authentication required"},status_code=401)
        return await call_next(request)

def bind_angel_tick(index,strike,side,**data):
    return put(index,strike,side,"angel_ws",**data)

def put_commodities(rows, src="angel_api", ts=None):
    incoming=float(ts or _now())
    clean=[dict(r) for r in (rows or []) if isinstance(r,dict)]
    with LOCK:
        if incoming < float(COMMODITY_STORE.get("ts",0.0)):
            return False
        COMMODITY_STORE.update({"rows":clean,"ts":incoming,"source":src})
    return True

def commodity_snapshot():
    now=_now()
    with LOCK:
        rows=deepcopy(COMMODITY_STORE["rows"])
        ts=float(COMMODITY_STORE["ts"])
        source=COMMODITY_STORE.get("source")
    age=max(0.0,now-ts) if ts else None
    return {"rows":rows,"ts":ts,"age_s":round(age,2) if age is not None else None,
            "stale":not _fresh(ts),"source":source,"data_ok":bool(rows and _fresh(ts))}

def clear():
    with LOCK:
        STORE.clear()
        COMMODITY_STORE.update({"rows":[],"ts":0.0,"source":None})
