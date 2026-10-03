"""Angel One SmartAPI wrapper: login, option-chain tokens, live LTP/OI snapshots."""
import json, os, time, urllib.request, datetime as dt, threading
import pyotp
from SmartApi import SmartConnect
from SmartApi.smartWebSocketV2 import SmartWebSocketV2
import config as C

MASTER_URL="https://margincalculator.angelbroking.com/OpenAPI_File/files/OpenAPIScripMaster.json"
INDEX={"NIFTY":"99926000","BANKNIFTY":"99926009","FINNIFTY":"99926037","SENSEX":"99919000"}
CACHE="scrip_master.json"

class AngelClient:
    def __init__(self):
        self.api=None; self.chain={}; self.strikes=[]; self.expiry=None; self.chain_symbol=C.SYMBOL; self.chain_exchange="NFO"
        self.last_chain_cache={}; self.last_chain_cache_ts={}
        self.ws=None; self.ws_thread=None; self.ws_quotes={}; self.ws_lock=threading.Lock(); self.login_lock=threading.Lock(); self.session_started=0.0; self.session_ttl=6*60*60
        self.active_api_key=None; self.active_client_code=None; self.active_pin=None; self.active_totp=None; self.last_snapshot=None
    def login(self, api_key=None, client_code=None, pin=None, totp=None, force=False):
        # Reuse one successful Angel session for 6 hours; avoid repeated TOTP/session calls.
        now=time.time()
        if not force and self.api is not None and now-self.session_started < self.session_ttl:
            return {"status": True, "message": "Existing Angel session reused.", "data": {"session_reused": True}}
        with self.login_lock:
            now=time.time()
            if not force and self.api is not None and now-self.session_started < self.session_ttl:
                return {"status": True, "message": "Existing Angel session reused.", "data": {"session_reused": True}}
            api_key=api_key or C.API_KEY; client_code=client_code or C.CLIENT; pin=pin or C.PIN
            totp=totp or (pyotp.TOTP(C.TOTP_SECRET).now() if C.TOTP_SECRET else None)
            if not api_key or not client_code or not pin or not totp:
                raise RuntimeError("Angel credentials are not configured.")
            self.api=SmartConnect(api_key=api_key)
            self.active_api_key=api_key
            self.active_client_code=client_code
            self.active_pin=pin
            self.active_totp=totp
            d=self.api.generateSession(client_code,pin,totp)
            if not d.get("status"):
                self.api=None; self.session_started=0.0
                raise RuntimeError(f"Angel login failed: {d.get('message', d)}")
            try:
                profile = self.api.getProfile(d.get("data", {}).get("refreshToken") or d.get("data", {}).get("refresh_token"))
                if isinstance(profile, dict) and profile.get("status") is False:
                    raise RuntimeError(
                        f"SmartAPI data authentication rejected: {profile.get('errorcode','UNKNOWN')} {profile.get('message','')}"
                    )
            except Exception as ex:
                self.api=None; self.session_started=0.0
                raise RuntimeError(f"SmartAPI API key/data authentication rejected: {str(ex)[:220]}")
            self.session_started=time.time()
            self.build_chain()
            self._start_stream(d)
            return d

    def _master(self):
        fresh=os.path.exists(CACHE) and time.time()-os.path.getmtime(CACHE)<43200
        if not fresh: urllib.request.urlretrieve(MASTER_URL,CACHE)
        with open(CACHE) as f: return json.load(f)
    def _symbol_config(self, symbol):
        s=(symbol or C.SYMBOL).upper().replace(" ","")
        aliases={"NIFTY50":"NIFTY","NIFTY":"NIFTY","BANKNIFTY":"BANKNIFTY","FINNIFTY":"FINNIFTY",
                 "MIDCPNIFTY":"MIDCPNIFTY","MIDCAPSELECT":"MIDCPNIFTY","SENSEX":"SENSEX","BANKEX":"BANKEX"}
        s=aliases.get(s,s)
        if s in ("SENSEX","BANKEX"): return s,"BFO"
        return s,"NFO"

    def build_chain(self, symbol=None):
        symbol, exchange=self._symbol_config(symbol)
        today=dt.date.today()
        master=self._master()
        rows=[r for r in master if str(r.get("name","")).upper()==symbol and r.get("exch_seg")==exchange and r.get("instrumenttype")=="OPTIDX"]
        if not rows and symbol=="MIDCPNIFTY":
            rows=[r for r in master if str(r.get("name","")).upper() in ("MIDCPNIFTY","MIDCPNIFTY") and r.get("exch_seg")==exchange and r.get("instrumenttype")=="OPTIDX"]
        def exp(r): return dt.datetime.strptime(r["expiry"],"%d%b%Y").date()
        expiries=sorted({exp(r) for r in rows if r.get("expiry") and exp(r)>=today})
        if not expiries: raise RuntimeError(f"No active {symbol} option expiry found in {exchange}.")
        self.expiry=expiries[0]; self.chain={}; self.chain_symbol=symbol; self.chain_exchange=exchange
        for r in rows:
            if exp(r)!=self.expiry: continue
            strike=float(r["strike"])/100; typ=str(r["symbol"])[-2:]
            if typ in ("CE","PE"): self.chain[(strike,typ)]={"token":r["token"],"symbol":r["symbol"]}
        self.strikes=sorted({k[0] for k in self.chain})

    def _index_token(self, symbol):
        symbol,_=self._symbol_config(symbol)
        if symbol in INDEX: return INDEX[symbol]
        master=self._master()
        aliases={"MIDCPNIFTY":["MIDCPNIFTY","MIDCAP SELECT","NIFTY MID SELECT"],"BANKEX":["BANKEX"]}
        wanted=[symbol]+aliases.get(symbol,[])
        for r in master:
            if r.get("exch_seg") not in ("NSE","BSE") or r.get("instrumenttype")!="AMXIDX": continue
            name=str(r.get("name","")).upper(); sym=str(r.get("symbol","")).upper()
            if any(w.upper() in name or w.upper() in sym for w in wanted):
                return str(r.get("token"))
        raise RuntimeError(f"Index token not found for {symbol}.")

    def spot(self, symbol=None):
        symbol,_=self._symbol_config(symbol)
        token=self._index_token(symbol)
        with self.ws_lock:
            tick=self.ws_quotes.get(str(token))
        if tick and tick.get("ltp") is not None and time.time()-tick.get("ts",0) < 15:
            return float(tick["ltp"])
        exchange="BSE" if symbol in ("SENSEX","BANKEX") else "NSE"
        r=self.api.getMarketData("LTP",{exchange:[token]})
        return float(r["data"]["fetched"][0]["ltp"])

    def _start_stream(self, session):
        data=session.get("data",{}) if isinstance(session,dict) else {}
        jwt=data.get("jwtToken") or data.get("jwt_token")
        feed=data.get("feedToken") or data.get("feed_token")
        api_key=self.active_api_key or C.API_KEY
        client_code=self.active_client_code or C.CLIENT
        if not jwt or not feed or not api_key or not client_code:
            return
        try:
            if self.ws:
                self.ws.close_connection()
            self.ws=SmartWebSocketV2(jwt,api_key,client_code,feed,max_retry_attempt=5,retry_strategy=1,retry_delay=3,retry_multiplier=2,retry_duration=5)
            self.ws.on_open=self._ws_on_open
            self.ws.on_data=self._ws_on_data
            self.ws.on_error=self._ws_on_error
            self.ws.on_close=self._ws_on_close
            self.ws_thread=threading.Thread(target=self.ws.connect,daemon=True,name="angel-smart-ws")
            self.ws_thread.start()
        except Exception:
            self.ws=None

    def _ws_tokens(self):
        out=[]
        if self.chain and self.strikes:
            try:
                spot=self.spot(self.chain_symbol)
                atm=min(self.strikes,key=lambda x:abs(x-spot))
                i=self.strikes.index(atm)
                selected=self.strikes[max(0,i-10):i+11]
                for strike in selected:
                    for typ in ("CE","PE"):
                        item=self.chain.get((strike,typ))
                        if item and item.get("token"):
                            out.append(str(item["token"]))
            except Exception:
                pass
        try:
            out.append(str(self._index_token(self.chain_symbol)))
        except Exception:
            pass
        return list(dict.fromkeys(out))[:50]

    def _ws_on_open(self, wsapp):
        tokens=self._ws_tokens()
        if not tokens:
            return
        exchange_type=4 if self.chain_exchange=="BFO" else 2
        index_token=str(self._index_token(self.chain_symbol))
        option_tokens=[t for t in tokens if t!=index_token]
        groups=[]
        if option_tokens:
            groups.append({"exchangeType":exchange_type,"tokens":option_tokens})
        groups.append({"exchangeType":1 if self.chain_exchange=="NFO" else 3,"tokens":[index_token]})
        self.ws.subscribe("VNDWS001",SmartWebSocketV2.SNAP_QUOTE,groups)

    def _ws_on_data(self, wsapp, message):
        if not isinstance(message,dict):
            return
        token=str(message.get("token",""))
        ltp=message.get("last_traded_price")
        if ltp is None:
            return
        row={"ltp":float(ltp)/100.0,"ts":time.time()}
        for src,dst in (("open_interest","oi"),("volume_trade_for_the_day","volume"),("open_price_of_the_day","open"),("high_price_of_the_day","high"),("low_price_of_the_day","low"),("closed_price","close"),("open_interest_change_percentage","oiChangePct")):
            if message.get(src) is not None:
                row[dst]=float(message[src])
        if row.get("close") is not None:
            row["chg"] = row["ltp"] - row["close"]
        with self.ws_lock:
            self.ws_quotes[token]=row
        # Mirror the tick into the shared market core without touching signal formulas.
        try:
            item=next(((k[0],k[1]) for k,v in self.chain.items() if str(v.get("token"))==token), None)
            if item:
                strike,side=item
                from market_core import bind_angel_tick
                bind_angel_tick(self.chain_symbol,strike,side,ts=row["ts"],
                                ltp=row.get("ltp"),oi=row.get("oi"),volume=row.get("volume"),
                                open=row.get("open"),high=row.get("high"),low=row.get("low"),
                                close=row.get("close"),chg=row.get("chg"),oiChangePct=row.get("oiChangePct"),
                                token=token)
        except Exception:
            pass

    def _ws_on_error(self, wsapp, error):
        return

    def _ws_on_close(self, wsapp):
        return

    def require_api(self):
        if self.api is None:
            raise RuntimeError("Angel One session is not connected.")
        return self.api

    def clear_market_cache(self):
        # Clear only in-memory market snapshots; credentials/session remain intact.
        with self.ws_lock:
            self.ws_quotes.clear()
        self.last_chain_cache.clear()
        self.last_chain_cache_ts.clear()
        self.last_snapshot = None
        self.chain = {}
        self.strikes = []
        self.expiry = None
        return {
            "ok": True,
            "cleared": [
                "websocket_quotes",
                "option_chain_cache",
                "last_snapshot",
                "instrument_chain",
            ],
            "session_preserved": self.api is not None,
        }

    def index_catalog(self):
        master=self._master()
        rows=[]; seen=set()
        for r in master:
            if r.get("instrumenttype")=="AMXIDX" and r.get("exch_seg") in ("NSE","BSE"):
                token=str(r.get("token",""))
                if not token or token in seen: continue
                seen.add(token)
                rows.append({"token":token,"name":r.get("name") or r.get("symbol"),"symbol":r.get("symbol"),"exchange":r.get("exch_seg")})
        fixed=[
            {"token":"99926000","name":"NIFTY 50","symbol":"Nifty 50","exchange":"NSE"},
            {"token":"99926009","name":"NIFTY BANK","symbol":"Nifty Bank","exchange":"NSE"},
            {"token":"99926037","name":"NIFTY FIN SERVICE","symbol":"Nifty Fin Service","exchange":"NSE"},
            {"token":"99919000","name":"SENSEX","symbol":"SENSEX","exchange":"BSE"}]
        bytoken={r["token"]:r for r in rows}
        for r in fixed: bytoken[r["token"]]=r
        return sorted(bytoken.values(),key=lambda x:(x["exchange"],x["name"] or ""))

    def index_catalog_quotes(self):
        api=self.require_api(); instruments=self.index_catalog(); grouped={"NSE":[],"BSE":[]}
        for r in instruments: grouped[r["exchange"]].append(r["token"])
        fetched=[]
        for exchange,tokens in grouped.items():
            for i in range(0,len(tokens),40):
                batch=tokens[i:i+40]
                if batch:
                    result=api.getMarketData("FULL",{exchange:batch})
                    fetched.extend(result.get("data",{}).get("fetched",[]) or [])
        q={str(r.get("symbolToken")):r for r in fetched}
        return {"data":[{**inst,"ltp":q.get(inst["token"],{}).get("ltp"),"open":q.get(inst["token"],{}).get("open"),"high":q.get(inst["token"],{}).get("high"),"low":q.get(inst["token"],{}).get("low"),"close":q.get(inst["token"],{}).get("close"),"netChange":q.get(inst["token"],{}).get("netChange"),"percentChange":q.get(inst["token"],{}).get("percentChange"),"volume":q.get(inst["token"],{}).get("tradeVolume")} for inst in instruments]}

    def index_quote(self, symbols=None):
        api=self.require_api()
        symbols=symbols or {
            "NIFTY":"99926000","BANKNIFTY":"99926009","FINNIFTY":"99926037",
            "SENSEX":"99919000"
        }
        tokens=list(symbols.values())
        result=api.getMarketData("FULL", {"NSE": [t for t in tokens if t!="99919000"], "BSE":["99919000"]})
        return result

    def candles(self, exchange, token, interval="FIVE_MINUTE", days=1):
        api=self.require_api()
        now=dt.datetime.now(dt.timezone(dt.timedelta(hours=5,minutes=30)))
        start=now-dt.timedelta(days=max(1,min(int(days),30)))
        p={"exchange":exchange,"symboltoken":str(token),"interval":interval,
           "fromdate":start.strftime("%Y-%m-%d %H:%M"),"todate":now.strftime("%Y-%m-%d %H:%M")}
        return api.getCandleData(p)

    def oi_history(self, token, interval="THREE_MINUTE", hours=6):
        api=self.require_api()
        now=dt.datetime.now(dt.timezone(dt.timedelta(hours=5,minutes=30)))
        start=now-dt.timedelta(hours=max(1,min(int(hours),24)))
        p={"exchange":"NFO","symboltoken":str(token),"interval":interval,
           "fromdate":start.strftime("%Y-%m-%d %H:%M"),"todate":now.strftime("%Y-%m-%d %H:%M")}
        return api.getOIData(p)

    def option_greeks(self, name, expiry):
        api=self.require_api()
        return api._postRequest("api.optionGreek", {"name":name,"expirydate":expiry})

    def gainers_losers(self, datatype="PercPriceGainers", expirytype="NEAR"):
        api=self.require_api()
        return api._postRequest("api.gainersLosers", {"datatype":datatype,"expirytype":expirytype})

    def oi_buildup(self, datatype="Long Built Up", expirytype="NEAR"):
        api=self.require_api()
        return api._postRequest("api.oIBuildup", {"datatype":datatype,"expirytype":expirytype})

    def put_call_ratio(self, expirytype="NEAR"):
        api=self.require_api()
        return api._postRequest("api.putCallRatio", {"expirytype":expirytype})

    def search(self, exchange, query):
        return self.require_api().searchScrip(exchange, query)

    def portfolio(self):
        api=self.require_api()
        return {
            "holdings": api.holding(),
            "positions": api.position(),
            "orders": api.orderBook(),
            "trades": api.tradeBook()
        }


    def commodity_quotes(self):
        api=self.require_api()
        master=self._master()
        wanted=("CRUDEOIL","CRUDEOILM","NATURALGAS","NATGASMINI","GOLD","GOLDM","SILVER","SILVERM","COPPER","ALUMINIUM","ZINC","LEAD","NICKEL","MENTHAOIL","COTTON")
        today=dt.date.today()
        selected=[]
        for name in wanted:
            candidates=[]
            for r in master:
                if r.get("exch_seg")!="MCX" or not r.get("name","").upper().startswith(name): continue
                exp=r.get("expiry","")
                if exp:
                    try:
                        ed=dt.datetime.strptime(exp,"%d%b%Y").date()
                        if ed>=today: candidates.append((ed,r))
                    except Exception:
                        pass
            if candidates:
                candidates.sort(key=lambda x:x[0])
                selected.append(candidates[0][1])
        tokens=[str(r["token"]) for r in selected]
        if not tokens: return {"data":{"fetched":[],"unfetched":[]},"instruments":[]}
        result=api.getMarketData("FULL",{"MCX":tokens})
        by={str(r["symbolToken"]):r for r in result.get("data",{}).get("fetched",[])}
        rows=[]
        for r in selected:
            q=by.get(str(r["token"]))
            if q:
                rows.append({"name":r.get("name"),"tradingSymbol":r.get("symbol"),"token":str(r["token"]),
                             "expiry":r.get("expiry"),"ltp":q.get("ltp"),"open":q.get("open"),
                             "high":q.get("high"),"low":q.get("low"),"close":q.get("close"),
                             "volume":q.get("tradeVolume"),"oi":q.get("opnInterest")})
        return {"data":{"fetched":rows,"unfetched":[]},"instruments":selected}

    def _market_data_full_retry(self, exchange, tokens):
        last=None
        for attempt in range(2):
            try:
                result=self.api.getMarketData("FULL",{exchange:tokens})
                if isinstance(result,dict) and result.get("status") is False:
                    raise RuntimeError(str(result.get("message") or "Angel market-data request failed"))
                return result
            except Exception as e:
                last=e
                if attempt==0:
                    try:
                        self.api=None
                        self.login(api_key=self.active_api_key, client_code=self.active_client_code, pin=self.active_pin, totp=self.active_totp, force=True)
                    except Exception as relogin_error:
                        last=relogin_error
                        break
        raise RuntimeError(str(last))

    def option_chain_rows(self, symbol=None, around=None, count=10):
        self.require_api()
        requested,_=self._symbol_config(symbol)
        cache_key=f"{requested}:{int(count)}"
        cached=self.last_chain_cache.get(cache_key)
        cached_at=self.last_chain_cache_ts.get(cache_key,0)
        if cached and time.time()-cached_at < 8:
            return {**cached,"cached":True,"cache_age_sec":round(time.time()-cached_at,1)}
        try:
            if not self.chain or self.chain_symbol!=requested:
                self.build_chain(requested)
            spot=self.spot(requested)
            atm=around if around is not None else min(self.strikes,key=lambda s:abs(s-spot))
            idx=min(range(len(self.strikes)),key=lambda i:abs(self.strikes[i]-atm))
            count=max(10,min(int(count),250))
            selected=self.strikes[max(0,idx-count):idx+count+1]
            token_map={}
            for strike in selected:
                for typ in ("CE","PE"):
                    item=self.chain.get((strike,typ))
                    if item: token_map[item["token"]]=(strike,typ,item["symbol"])
            rows=[]
            toks=list(token_map)
            with self.ws_lock:
                ws_snapshot={k:v.copy() for k,v in self.ws_quotes.items() if time.time()-v.get("ts",0) < 15}
            for token,item in token_map.items():
                q=ws_snapshot.get(str(token))
                if not q:
                    continue
                strike,typ,sym=item
                rows.append({"strike":strike,"type":typ,"symbol":sym,"token":str(token),
                             "ltp":q.get("ltp"),"open":q.get("open"),"high":q.get("high"),"low":q.get("low"),
                             "close":q.get("close"),"oi":q.get("oi"),"volume":q.get("volume"),
                             "oiChangePct":q.get("oiChangePct")})
            if len(rows) < max(4,int(len(toks)*0.6)):
                rows=[]
                for j in range(0,len(toks),50):
                    result=self._market_data_full_retry(self.chain_exchange,toks[j:j+50])
                    for q in result.get("data",{}).get("fetched",[]) or []:
                        item=token_map.get(str(q.get("symbolToken")))
                        if not item: continue
                        strike,typ,sym=item
                        rows.append({"strike":strike,"type":typ,"symbol":sym,"token":str(q.get("symbolToken")),
                                     "ltp":q.get("ltp"),"open":q.get("open"),"high":q.get("high"),"low":q.get("low"),
                                     "close":q.get("close"),"oi":q.get("opnInterest"),"volume":q.get("tradeVolume"),
                                     "buyQty":q.get("totalBuyQuantity"),"sellQty":q.get("totalSellQuantity"),
                                     "netChange":q.get("netChange"),"priceChange":q.get("netChange")})
            rows.sort(key=lambda r:(float(r["strike"]),0 if r["type"]=="CE" else 1))
            result={"symbol":requested,"exchange":self.chain_exchange,"spot":spot,"atm":atm,"expiry":str(self.expiry),
                    "rows":rows,"cached":False,"source":"Angel One SmartAPI"}
            self.last_chain_cache[cache_key]=result
            self.last_chain_cache_ts[cache_key]=time.time()
            return result
        except Exception as live_error:
            cached=self.last_chain_cache.get(cache_key)
            if cached:
                age=int(time.time()-self.last_chain_cache_ts.get(cache_key,time.time()))
                return {**cached,"cached":True,"cache_age_sec":max(0,age),"source":"Angel One SmartAPI cached last-good chain",
                        "live_error":str(live_error)[:240]}
            raise

    def snapshot(self):
        if self.api is None:
            raise RuntimeError("Angel session is not connected.")
        # Cache reset may clear the instrument chain; rebuild it before
        # calculating ATM so a hard refresh never breaks the dashboard.
        if not self.chain or not self.strikes:
            self.build_chain(self.chain_symbol)
        spot = self.spot()
        atm = min(self.strikes, key=lambda s: abs(s - spot))
        i = self.strikes.index(atm)
        sel=self.strikes[max(0,i-C.N):i+C.N+1]; tok2key={}
        for s in sel:
            for t in ("CE","PE"):
                if (s,t) in self.chain: tok2key[self.chain[(s,t)]["token"]]=(s,t)
        opts={}; toks=list(tok2key)
        with self.ws_lock:
            ws_snapshot={k:v.copy() for k,v in self.ws_quotes.items() if time.time()-v.get("ts",0) < 15}
        for token,k in tok2key.items():
            q=ws_snapshot.get(str(token))
            if q:
                opts[k]={"ltp":float(q.get("ltp",0)),"oi":float(q.get("oi",0)),"vol":float(q.get("volume",0)),"symbol":self.chain[k].get("symbol"),"token":self.chain[k].get("token")}
        if len(opts) < max(4,int(len(toks)*0.6)):
            opts={}
            for j in range(0,len(toks),50):
                r=self._market_data_full_retry(self.chain_exchange,toks[j:j+50])
                for q in r["data"]["fetched"]:
                    k=tok2key.get(q["symbolToken"])
                    if k: opts[k]={"ltp":float(q["ltp"]),"oi":float(q.get("opnInterest",0)),"vol":float(q.get("tradeVolume",0)),"symbol":self.chain[k].get("symbol"),"token":self.chain[k].get("token")}
        previous = self.last_snapshot.get("opts", {}) if isinstance(self.last_snapshot, dict) else {}
        for key, item in opts.items():
            old = previous.get(key) if isinstance(previous, dict) else None
            if isinstance(old, dict):
                if item.get("ltp") is not None and old.get("ltp") is not None:
                    item["ltp_change"] = float(item["ltp"]) - float(old["ltp"])
                if item.get("oi") is not None and old.get("oi") is not None:
                    item["oi_change"] = float(item["oi"]) - float(old["oi"])
                if item.get("vol") is not None and old.get("vol") is not None:
                    item["volume_change"] = float(item["vol"]) - float(old["vol"])
        result = {"ts":time.time(),"symbol":self.chain_symbol or C.SYMBOL,"spot":spot,"atm":atm,"opts":opts,"expiry":str(self.expiry) if self.expiry else None}
        self.last_snapshot = {"ts":result["ts"],"opts":{k:dict(v) for k,v in opts.items()}}
        return result
