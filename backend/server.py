"""Network/API gateway for NSE Algo Signal. PAPER signals only; no order placement."""
import asyncio,threading,time,datetime as dt,os
from typing import Optional
from fastapi import FastAPI,Header,HTTPException,Response,WebSocket,WebSocketDisconnect
from fastapi.middleware.gzip import GZipMiddleware
from pydantic import BaseModel
import uvicorn
import config as C
from angel_client import AngelClient
from signals import Engine
from nse_client import NSEClient
import nse_features
from nse_mcp import NSEMCP,result_to_csv
from ai_model import p_up,label
from ai_orchestrator import provider_status, provider_live_status, validate_all, NSE_SITE_URL, _nse_site_evidence
from market_core import router as market_core_router, ingest_chain, put_spot, evidence as market_evidence, mount_mcp, install_mcp_auth
from strategy_api import router as strategy_router
from council import router as council_router
from notifier import router as alert_router, alert_loop
from strategy_store import save_oi_snapshot
from strategy_mcp_server import mount_strategy_mcp
from engine_contract import engine_state, strategy_state
from angel_data_layer import build_ai_read
from quant.live import build_quant_evidence

app=FastAPI(title="NSE Algo Signal API"); app.add_middleware(GZipMiddleware,minimum_size=1024); app.include_router(strategy_router); app.include_router(market_core_router); app.include_router(council_router); app.include_router(alert_router); eng=Engine(); client=AngelClient(); nse=NSEClient(); nse_mcp=NSEMCP()
state={"error":None,"nse_error":None,"last_update":None,"angel_message":"Not connected","nse_mcp_error":None,"nse_mcp_checked":False}
prev_chain={"c":None}; workers_started=False; last_oi_save=0.0

# Two read-only MCP servers live in this same Railway/Fly process.
# /mcp serves the shared market snapshot; /mcp-strategy serves strategy evidence/backtests.
mount_mcp(app)
mount_strategy_mcp(app)
install_mcp_auth(app)

class AIValidationRequest(BaseModel):
    payload:dict = {}

class AngelLoginRequest(BaseModel):
    # The APK uses clientId/pin/totp/apiKey. clientCode is accepted as a
    # compatibility alias for simple Railway clients.
    clientId:Optional[str]=None
    clientCode:Optional[str]=None
    pin:str
    totp:str
    apiKey:Optional[str]=None

    @property
    def client_code(self) -> str:
        return (self.clientId or self.clientCode or "").strip()

def market_open():
    now=dt.datetime.now(dt.timezone(dt.timedelta(hours=5,minutes=30)))
    return now.weekday()<5 and dt.time(9,15)<=now.time()<=dt.time(15,30)

@app.on_event("startup")
def start_workers():
    global workers_started
    if workers_started:
        return
    workers_started = True
    threading.Thread(target=loop, daemon=True, name="angel-data-loop").start()
    threading.Thread(target=nse_loop, daemon=True, name="nse-data-loop").start()
    asyncio.create_task(alert_loop(), name="qualified-alert-loop")

def _ensure_angel():
    # App login is the normal path. Only auto-login on startup when complete
    # server-side Angel credentials are configured in Railway environment.
    if client.api is None and C.API_KEY and C.CLIENT and C.PIN and C.TOTP_SECRET:
        client.login()
        state["angel_message"]="Connected using server credentials (6h session reuse)."

def loop():
    global last_oi_save
    while True:
        try:
            _ensure_angel()
            if market_open():
                snap=client.snapshot()
                eng.update(snap); state["last_update"]=time.time(); state["error"]=None
                if time.time()-last_oi_save >= max(60, min(180, int(C.NSE_POLL_SEC))):
                    try:
                        save_oi_snapshot(C.SYMBOL, snap)
                        last_oi_save=time.time()
                    except Exception:
                        pass
        except Exception as e:
            state["error"]=str(e); state["angel_message"]="Angel connection failed."; client.api=None; time.sleep(10)
        time.sleep(C.POLL_SEC)

def nse_loop():
    while True:
        try:
            if market_open():
                ch=nse.fetch(C.SYMBOL)
                features=nse_features.compute(ch,prev_chain["c"]); prev_chain["c"]=ch
                eng.set_nse(features,ch["ts"])
                ingest_chain(ch,"nse")
                state["nse_error"]=None
        except Exception as e: state["nse_error"]=str(e)
        time.sleep(C.NSE_POLL_SEC)

def auth(x_token: str = None, x_app_key: str = None):
    expected = (C.API_TOKEN or "").strip()
    provided = (x_token or x_app_key or "").strip()
    if expected and provided != expected:
        raise HTTPException(
            401,
            detail={
                "code": "APP_TOKEN_REJECTED",
                "message": "Terminal app token rejected. This is not the Angel One SmartAPI key."
            },
        )

@app.get("/health")
def health():
    return {"ok":True,"auth_mode":"optional" if not C.API_TOKEN else "required","market_open":market_open(),"angel_connected":client.api is not None,"angel_message":state["angel_message"],"nse_mcp":"configured","last_update":state["last_update"],"error":state["error"],"nse_error":state["nse_error"],"nse_mcp_error":state["nse_mcp_error"]}

@app.post("/v1/angel/login")
@app.post("/angel/login")
def angel_login(body:AngelLoginRequest,x_token:str=Header(None),x_app_key:str=Header(None)):
    auth(x_token,x_app_key)
    client_code=body.client_code
    if not client_code: raise HTTPException(400,"Client ID is required.")
    if len(body.totp)!=6 or not body.totp.isdigit(): raise HTTPException(400,"TOTP must be the current 6-digit code.")
    try:
        result=client.login(api_key=body.apiKey or C.API_KEY,client_code=client_code,pin=body.pin,totp=body.totp)
        reused=bool(result.get("data",{}).get("session_reused"))
        state["angel_message"]="Angel One session reused (6h)." if reused else "Angel One connected."
        state["error"]=None
        return {"ok":True,"connected":True,"session_reused":reused,"message":"Existing Angel session reused." if reused else "Angel One connected.","profile":result.get("data",{}).get("clientcode")}
    except Exception as ex:
        client.api=None
        client.session_started=0.0
        state["angel_message"]="Angel connection failed."
        safe = str(ex).replace(body.apiKey or "", "[REDACTED]").replace(body.pin, "[REDACTED]").replace(body.totp, "[REDACTED]")
        state["error"]=safe[:300]
        raise HTTPException(
            401,
            detail={
                "code": "ANGEL_LOGIN_REJECTED",
                "message": safe[:300] or "Angel login failed. Check Client ID, PIN, TOTP and SmartAPI key."
            },
        )

@app.get("/v1/angel/status")
@app.get("/angel/status")
def angel_status(x_token:str=Header(None),x_app_key:str=Header(None)):
    auth(x_token,x_app_key); return {"connected":client.api is not None,"message":state["angel_message"],"last_update":state["last_update"],"error":state["error"]}
@app.websocket("/v1/ws")
async def native_market_websocket(websocket: WebSocket):
    token = (websocket.query_params.get("token") or "").strip()
    expected = (C.API_TOKEN or "").strip()
    if expected and token != expected:
        await websocket.close(code=1008, reason="APP_TOKEN_REJECTED")
        return
    await websocket.accept()
    try:
        while True:
            await websocket.send_json(terminal_snapshot())
            await asyncio.sleep(1.0)
    except WebSocketDisconnect:
        return
    except Exception:
        try:
            await websocket.close(code=1011)
        except Exception:
            pass



def angel_required():
    if client.api is None:
        raise HTTPException(503,"Angel One is not connected. Connect from Angel API screen first.")

@app.get("/v1/angel/commodities")
def angel_commodities(x_token:str=Header(None)):
    auth(x_token); angel_required()
    try: return client.commodity_quotes()
    except Exception as e: raise HTTPException(502,str(e))

@app.get("/v1/angel/indices")
def angel_indices(x_token:str=Header(None)):
    auth(x_token); angel_required()
    try: return client.index_catalog_quotes()
    except Exception as e: raise HTTPException(502,str(e))

@app.get("/v1/angel/market")
def angel_market(x_token:str=Header(None)):
    auth(x_token); angel_required()
    try:
        return client.index_quote()
    except Exception as e:
        raise HTTPException(502,str(e))

@app.get("/v1/angel/candles")
def angel_candles(exchange:str="NSE",token:str="99926000",interval:str="FIVE_MINUTE",days:int=1,x_token:str=Header(None)):
    auth(x_token); angel_required()
    allowed={"ONE_MINUTE","THREE_MINUTE","FIVE_MINUTE","TEN_MINUTE","FIFTEEN_MINUTE","THIRTY_MINUTE","ONE_HOUR","ONE_DAY"}
    if interval not in allowed: raise HTTPException(400,"Unsupported interval")
    try: return client.candles(exchange,token,interval,days)
    except Exception as e: raise HTTPException(502,str(e))

@app.get("/v1/option-chain")
def unified_option_chain(symbol:str="NIFTY",count:int=10,x_token:str=Header(None)):
    auth(x_token); angel_required()
    aliases={"NIFTY 50":"NIFTY","NIFTYBANK":"BANKNIFTY","BANK NIFTY":"BANKNIFTY","MIDCAP SELECT":"MIDCPNIFTY"}
    key=symbol.upper().replace(" ","")
    key=aliases.get(symbol.upper(), aliases.get(key,key))
    try:
        result=client.option_chain_rows(symbol=key,count=max(5,min(count,25)))
        rows=result.get("rows",[]) if isinstance(result,dict) else []
        return {**result,"source":"Angel One SmartAPI","rows":rows}
    except Exception as e:
        raise HTTPException(502,"Option chain unavailable: "+str(e))

@app.get("/v1/angel/option-chain")
def angel_option_chain(symbol:str="NIFTY",count:int=200,x_token:str=Header(None)):
    auth(x_token); angel_required()
    allowed={"NIFTY","BANKNIFTY","FINNIFTY","MIDCPNIFTY","MIDCAPSELECT","SENSEX","BANKEX"}
    symbol=symbol.upper().replace(" ","")
    if symbol not in allowed: raise HTTPException(400,"Unsupported index")
    try:
        result=client.option_chain_rows(symbol=symbol,count=max(10,min(count,250)))
        # Angel's Option Greeks endpoint is currently NSE-only. Enrich NSE rows when live expiry data is available.
        if symbol in {"NIFTY","BANKNIFTY","FINNIFTY","MIDCPNIFTY","MIDCAPSELECT"} and result.get("expiry"):
            try:
                expiry_value=str(result["expiry"])
                try:
                    expiry_value=dt.datetime.fromisoformat(expiry_value).strftime("%d%b%Y").upper()
                except Exception:
                    expiry_value=expiry_value.upper()
                gd=client.option_greeks(symbol, expiry_value)
                greeks=gd.get("data",[]) if isinstance(gd,dict) else []
                gm={(float(g.get("strikePrice")),str(g.get("optionType")).upper()):g for g in greeks if isinstance(g,dict) and g.get("strikePrice") is not None}
                for row in result.get("rows",[]):
                    g=gm.get((float(row.get("strike")),str(row.get("type")).upper()))
                    if g:
                        row.update({"delta":g.get("delta"),"gamma":g.get("gamma"),"theta":g.get("theta"),"vega":g.get("vega"),"iv":g.get("impliedVolatility")})
            except Exception:
                pass
        return result
    except Exception as e: raise HTTPException(502,str(e))

@app.get("/v1/angel/oi")
def angel_oi(token:str,interval:str="THREE_MINUTE",hours:int=6,x_token:str=Header(None)):
    auth(x_token); angel_required()
    try: return client.oi_history(token,interval,hours)
    except Exception as e: raise HTTPException(502,str(e))

@app.get("/v1/angel/search")
def angel_search(exchange:str="NSE",q:str="",x_token:str=Header(None)):
    auth(x_token); angel_required()
    if not q.strip(): raise HTTPException(400,"Search query is required")
    try: return client.search(exchange,q.strip())
    except Exception as e: raise HTTPException(502,str(e))

@app.get("/v1/angel/portfolio")
def angel_portfolio(x_token:str=Header(None)):
    auth(x_token); angel_required()
    try: return client.portfolio()
    except Exception as e: raise HTTPException(502,str(e))

@app.get("/v1/angel/gainers-losers")
def angel_gainers_losers(datatype:str="PercPriceGainers",expirytype:str="NEAR",x_token:str=Header(None)):
    auth(x_token); angel_required()
    try: return client.gainers_losers(datatype,expirytype)
    except Exception as e: raise HTTPException(502,str(e))

@app.get("/v1/angel/oi-buildup")
def angel_oi_buildup(datatype:str="Long Built Up",expirytype:str="NEAR",x_token:str=Header(None)):
    auth(x_token); angel_required()
    try: return client.oi_buildup(datatype,expirytype)
    except Exception as e: raise HTTPException(502,str(e))

@app.get("/v1/angel/greeks")
def angel_greeks(name:str="NIFTY",expiry:str="",x_token:str=Header(None)):
    auth(x_token); angel_required()
    if not expiry: raise HTTPException(400,"Expiry is required")
    try: return client.option_greeks(name,expiry)
    except Exception as e: raise HTTPException(502,str(e))

@app.get("/v1/mcp/status")
def mcp_status(x_token:str=Header(None)):
    auth(x_token)
    return {
        "market_mcp":{"mounted":True,"endpoint":"/mcp","auth":"x-mcp-token or Bearer"},
        "strategy_mcp":{"mounted":True,"endpoint":"/mcp-strategy","auth":"x-mcp-token or Bearer"},
        "official_nse_mcp":{"configured":True,"endpoint":nse_mcp.url},
        "paper_only":True,"orders_enabled":False,
    }

@app.get("/v1/nse/mcp/tools")
def nse_mcp_tools(x_token:str=Header(None)):
    auth(x_token)
    try:
        tools=nse_mcp.tools()
        state["nse_mcp_checked"]=True
        state["nse_mcp_error"]=None
        return {"connected":True,"endpoint":nse_mcp.url,"tools":[{"name":t.get("name"),"description":t.get("description")} for t in tools]}
    except Exception as e:
        state["nse_mcp_checked"]=True
        state["nse_mcp_error"]=str(e)
        raise HTTPException(502,"NSE MCP unavailable")

@app.get("/v1/nse/mcp/context")
def nse_mcp_context(symbol:str="NIFTY",x_token:str=Header(None)):
    auth(x_token)
    try:
        data=nse_mcp.context(symbol.upper())
        state["nse_mcp_checked"]=True
        state["nse_mcp_error"]=None
        return data
    except Exception as e:
        state["nse_mcp_checked"]=True
        state["nse_mcp_error"]=str(e)
        return {"connected":False,"endpoint":nse_mcp.url,"tool_count":0,"tools":[],"data":[],"error":str(e)[:500]}
@app.get("/v1/nse/option-chain.csv")
def nse_option_chain_csv(symbol:str="NIFTY",expiry:Optional[str]=None,x_token:str=Header(None)):
    auth(x_token)
    try:
        tool,result=nse_mcp.option_chain(symbol.upper(),expiry)
        state["nse_mcp_error"]=None
        csv=result_to_csv(result)
        return Response(
            content=csv,
            media_type="text/csv",
            headers={"Content-Disposition":f'attachment; filename="{symbol.upper()}_NSE_option_chain.csv"',"X-NSE-MCP-Tool":tool}
        )
    except Exception as e:
        state["nse_mcp_error"]=str(e)
        raise HTTPException(502,str(e))

def _strategy_refresh(index: str = "NIFTY"):
    return strategy_state(client, eng, index)

@app.get("/v1/strategy/refresh")
def strategy_refresh(index:str="NIFTY",x_token:str=Header(None)):
    auth(x_token)
    return _strategy_refresh(index)

@app.get("/v1/ai/context")
def ai_context(index:str="NIFTY",x_token:str=Header(None)):
    auth(x_token)
    terminal=terminal_snapshot()
    try:
        mcp=nse_mcp.context(index.upper())
        state["nse_mcp_checked"]=True
        state["nse_mcp_error"]=None
    except Exception as e:
        mcp={"connected":False,"endpoint":nse_mcp.url,"tool_count":0,"tools":[],"data":[],"error":str(e)[:500]}
        state["nse_mcp_checked"]=True
        state["nse_mcp_error"]=str(e)
    official=_nse_site_evidence({"terminal":terminal,"symbol":index})
    strategy=_strategy_refresh(index)
    data_layer=None
    if client.api is not None:
        try:
            data_layer=build_ai_read(client, index.upper(), "FIVE_MINUTE", 5)
        except Exception as exc:
            data_layer={"available":False,"error":str(exc)[:300],"source":"Angel One SmartAPI -> AI Read data layer"}
    else:
        data_layer={"available":False,"reason":"Angel One is not connected. Connect from Angel API screen first.","source":"Angel One SmartAPI -> AI Read data layer"}
    market=terminal.get("market") or {}
    quant_payload={"terminal":terminal,"strategy":strategy,"data_layer":data_layer,"three_sources":{
        "angel_api":{"connected":bool((terminal.get("angel_api") or {}).get("connected")),"data":terminal.get("data"),"option_chain":terminal.get("option_chain")},
        "nse_mcp":mcp,
        "nse_internet":{"connected":official.get("connected",False),"evidence":official}
    }}
    quant_payload["market_evidence"]={
        "index":index.upper(),"spot":market.get("spot"),"atm":market.get("atm"),
        "pcr":strategy.get("pcr"),"top_ce_oi":strategy.get("highest_ce_oi",[]),"top_pe_oi":strategy.get("highest_pe_oi",[]),
        "trend":strategy.get("trend"),"support":strategy.get("support"),"resistance":strategy.get("resistance"),
        "max_pain":strategy.get("max_pain")
    },"ai_rule":"Reconcile Angel API + official NSE MCP + Internet evidence. Missing or conflicting evidence forces WAIT."}
    quant_payload["quant_evidence"]=build_quant_evidence(quant_payload)
    return quant_payload
@app.get("/v1/ai/provider-status")
def ai_provider_status(x_token:str=Header(None),probe:bool=False):
    """Safe AI provider status. probe=true performs real minimal API calls; secrets are never returned."""
    auth(x_token)
    if probe:
        return provider_live_status()
    rows=provider_status()
    return {"providers":rows,"configured":sum(1 for x in rows if x["configured"]),"live":None,
            "total":len(rows),"six_ai_live":None,
            "message":"Use ?probe=true for a real server-side connectivity check."}

@app.post("/v1/ai/validate")
def ai_validate(body:AIValidationRequest,x_token:str=Header(None)):
    auth(x_token)
    payload=body.payload if isinstance(body.payload,dict) else {}
    try:
        return validate_all(payload)
    except Exception as e:
        return {"final":"WAIT","cross_verified":False,"reason":"AI orchestration failed safely; local evidence path remains active.",
                "configured":0,"successful":0,"parsed_states":0,"total":6,"providers":[],
                "local_fallback":{"status":"error_local","text":str(e)[:300]}}

@app.get("/v1/live/news")
def live_news(x_token:str=Header(None),q:str="NIFTY India"):
    auth(x_token)
    import xml.etree.ElementTree as ET
    import urllib.parse
    try:
        url="https://news.google.com/rss/search?"+urllib.parse.urlencode({"q":q,"hl":"en-IN","gl":"IN","ceid":"IN:en"})
        r=requests.get(url,headers={"User-Agent":"ParmarTrading/1.0"},timeout=8)
        r.raise_for_status()
        root=ET.fromstring(r.text)
        items=[]
        for item in root.findall("./channel/item")[:20]:
            title=(item.findtext("title") or "").strip()
            link=(item.findtext("link") or "").strip()
            pub=(item.findtext("pubDate") or "").strip()
            source=item.find("source")
            source_name=(source.text or "").strip() if source is not None else ""
            items.append({"title":title,"link":link,"published":pub,"source":source_name})
        return {"connected":True,"query":q,"count":len(items),"items":items,"fetched_at":time.time()}
    except Exception as e:
        return {"connected":False,"query":q,"count":0,"items":[],"error":str(e)[:300],"fetched_at":time.time()}

@app.get("/v1/quant/live")
def quant_live(x_token:str=Header(None),index:str="NIFTY"):
    auth(x_token)
    payload=ai_context(index=index,x_token=x_token)
    return build_quant_evidence(payload)

@app.get("/v1/live/snapshot")
def live_snapshot(x_token:str=Header(None)):
    auth(x_token)
    snap=terminal_snapshot()
    snap["live_transport"]="http"
    snap["server_time"]=time.time()
    return snap

@app.websocket("/ws/live")
async def live_websocket(websocket:WebSocket):
    token=websocket.query_params.get("token")
    try:
        if os.getenv("API_TOKEN"):
            if token != C.API_TOKEN:
                await websocket.close(code=1008)
                return
        await websocket.accept()
        while True:
            snap=terminal_snapshot()
            snap["live_transport"]="websocket"
            snap["server_time"]=time.time()
            await websocket.send_json(snap)
            await asyncio.sleep(max(2, min(int(C.POLL_SEC), 10)))
    except WebSocketDisconnect:
        return
    except Exception:
        try:
            await websocket.close(code=1011)
        except Exception:
            pass

@app.get("/v1/diagnostics")
def diagnostics(x_token:str=Header(None)):
    auth(x_token); providers=ai_status(x_token)["providers"]; ev=getattr(eng,"strategy_evidence",[]) if hasattr(eng,"strategy_evidence") else []
    return {"angel":{"connected":client.api is not None,"message":state["angel_message"]},"nse":{"available":state["nse_error"] is None,"error":state["nse_error"]},"ai":{"configured":sum(1 for p in providers if p["configured"]),"providers":providers},"strategies":{"registered":len(ev),"evaluated":len(ev),"active":sum(1 for x in ev if isinstance(x,dict) and x.get("state")=="active"),"unavailable":sum(1 for x in ev if isinstance(x,dict) and x.get("state")=="unavailable"),"not_evaluated":0}}

@app.get("/v1/audit/latest")
def latest_audit(x_token:str=Header(None)):
    auth(x_token); last=eng.last if isinstance(eng.last,dict) else {}; return {"action":last.get("action","WAIT"),"reasons":last.get("reasons",[]),"timestamp":state["last_update"]}

@app.get("/signal")
def signal(x_token:str=Header(None)): auth(x_token); return terminal_snapshot()

@app.get("/v1/terminal")
def terminal_snapshot_endpoint(x_token:str=Header(None)): auth(x_token); return terminal_snapshot()

def terminal_snapshot():
    last=eng.last if isinstance(eng.last,dict) else {}
    nse_view=eng.nse_view if isinstance(eng.nse_view,dict) else {}
    live_engine=engine_state(client, eng, C.SYMBOL)
    nse_status = "NOT CHECKED"
    if state["nse_mcp_checked"]:
        nse_status = "CONNECTED" if state["nse_mcp_error"] is None else "UNAVAILABLE"
    return {"ts":time.time(),"market_open":market_open(),
            "connection":{"angel":client.api is not None,"nse":state["nse_error"] is None,"server":True,
                          "last_update":state["last_update"],"error":state["error"],"nse_error":state["nse_error"],
                          "angel_message":state["angel_message"]},
            "market":{"symbol":live_engine.get("symbol",C.SYMBOL),"spot":live_engine.get("index_ltp"),
                      "atm":live_engine.get("atm"),"action":live_engine.get("signal_status","WAIT"),
                      "ltp":live_engine.get("option_ltp")},
            "engine_state":live_engine,"signals":last,"oi_lab":nse_view,
            "option_chain":last.get("chain",last.get("opts")),
            "charts":{"spot":live_engine.get("index_ltp"),"ltp":live_engine.get("option_ltp"),
                      "timestamp":state["last_update"],"source":"Angel One SmartAPI","endpoint":"/v1/angel/candles"},
            "nse":nse_view,
            "angel_data":{"market_endpoint":"/v1/angel/market","candles_endpoint":"/v1/angel/candles",
                          "option_chain_endpoint":"/v1/angel/option-chain","oi_endpoint":"/v1/angel/oi",
                          "search_endpoint":"/v1/angel/search","portfolio_endpoint":"/v1/angel/portfolio",
                          "gainers_losers_endpoint":"/v1/angel/gainers-losers","oi_buildup_endpoint":"/v1/angel/oi-buildup",
                          "greeks_endpoint":"/v1/angel/greeks"},
            "nse_mcp":{"status":"official NSE Streamable HTTP MCP","state":nse_status,"endpoint":nse_mcp.url,
                       "connected":state["nse_mcp_checked"] and state["nse_mcp_error"] is None,
                       "error":state["nse_mcp_error"],"csv_endpoint":"/v1/nse/option-chain.csv"},
            "angel_api":{"connected":client.api is not None,"message":state["angel_message"]},"data":last,
            "instruments":{"source":"Angel One SmartAPI instrument master","loaded":bool(client.chain),
                           "expiry":str(client.expiry) if client.expiry else None,"strike_count":len(client.strikes)},
            "watchlist":{"source":"Angel One SmartAPI","items":[]},"search":{"source":"Angel One SmartAPI","items":[]},
            "commodity":{"source":"Angel One SmartAPI","items":[]},"market_details":nse_view,
            "news":{"source":"server-side news adapter","items":[]},
            "settings":{"symbol":C.SYMBOL,"poll_sec":C.POLL_SEC,"nse_poll_sec":C.NSE_POLL_SEC},
            "more":{"paper_only":True,"orders_enabled":False},"error":state["error"],"nse_error":state["nse_error"]}

if __name__=="__main__":
    uvicorn.run(app,host="0.0.0.0",port=8000)
