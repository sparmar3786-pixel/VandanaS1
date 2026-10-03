"""
trade_verifier.py  -  fast OI engine + independent web/market verifier for AI trade plans

Why the AI plan goes wrong: it writes numbers from memory, not from live data.
Fix: (1) give the AI the REAL numbers, (2) verify every plan against live Angel One
data + a second web source, (3) send failures back to the AI and let it fix the plan.
Only a plan that survives the checks becomes a signal.

Pipeline
  OIEngine   Angel getMarketData(FULL): whole option chain in ONE call (50 tokens), 3s cache,
             OI change vs your own snapshots (this is why OI Lab shows up0/down0: no baseline)
  Web        NSE option chain (2nd source) + Google News RSS (event risk)
  Verifier   13 checks -> CONFIRMED / CAUTION / REJECT / NO_TRADE + corrected plan
  negotiate  AI proposes -> Verifier checks -> feedback to AI -> max 3 rounds
  make_app   FastAPI: /oi/{index}  /verify  /signal/{index}  (your APK reads these)

Install : pip install smartapi-python pyotp pandas numpy requests fastapi uvicorn anthropic
Test    : python trade_verifier.py selftest        (no keys, no internet)
Serve   : uvicorn trade_verifier:app --host 0.0.0.0 --port 8000
Needs   : angel_data_layer.py in the same folder (AngelClient, candles, indicators)
"""
from __future__ import annotations
import json, logging, os, time, xml.etree.ElementTree as ET
from collections import defaultdict, deque
from dataclasses import dataclass, field, asdict
from datetime import date, datetime, timedelta
from typing import Callable, Dict, List, Optional
from zoneinfo import ZoneInfo
import numpy as np
import pandas as pd

log = logging.getLogger("verifier")
IST = ZoneInfo("Asia/Kolkata")
MASTER_URL = "https://margincalculator.angelbroking.com/OpenAPI_Files/files/OpenAPIScripMaster.json"
CACHE = "scrip_master_idx.pkl"

INDEX_CFG = {  # spot token = fallback; real one is looked up in the master by alias
    "NIFTY": dict(seg="NFO", alias=["NIFTY 50", "NIFTY"], spot=("NSE", "99926000"), nse=True),
    "BANKNIFTY": dict(seg="NFO", alias=["NIFTY BANK", "BANKNIFTY"], spot=("NSE", "99926009"), nse=True),
    "FINNIFTY": dict(seg="NFO", alias=["NIFTY FIN SERVICE", "FINNIFTY"], spot=("NSE", "99926037"), nse=True),
    "MIDCPNIFTY": dict(seg="NFO", alias=["NIFTY MID SELECT", "MIDCPNIFTY"], spot=("NSE", "99926074"), nse=True),
    "SENSEX": dict(seg="BFO", alias=["SENSEX"], spot=("BSE", "99919000"), nse=False),
    "BANKEX": dict(seg="BFO", alias=["BANKEX"], spot=None, nse=False),
}


def now_ist() -> datetime:
    return datetime.now(IST)


def market_open(t: Optional[datetime] = None) -> bool:
    t = t or now_ist()
    return t.weekday() < 5 and (9, 15) <= (t.hour, t.minute) <= (15, 30)


# ───────────────────────── Chain model ─────────────────────────
@dataclass
class Chain:
    index: str
    spot: float
    expiry: date
    df: pd.DataFrame        # strike, ce_/pe_ : token ltp oi vol bid ask doi
    ts: datetime
    delta_src: str = "none"  # none | snapshot | nse_day

    def atm(self) -> float:
        return float(self.df.iloc[(self.df.strike - self.spot).abs().argmin()].strike)

    def row(self, k: float):
        r = self.df[self.df.strike == k]
        return None if r.empty else r.iloc[0]

    def pcr(self) -> float:
        return float(self.df.pe_oi.sum() / max(1, self.df.ce_oi.sum()))

    def walls(self):
        up, dn = self.df[self.df.strike >= self.spot], self.df[self.df.strike <= self.spot]
        res = float(up.loc[up.ce_oi.idxmax(), "strike"]) if len(up) else None
        sup = float(dn.loc[dn.pe_oi.idxmax(), "strike"]) if len(dn) else None
        return res, sup

    def max_pain(self) -> float:
        K, ce, pe = self.df.strike.values, self.df.ce_oi.values, self.df.pe_oi.values
        pain = [(np.maximum(k - K, 0) * ce).sum() + (np.maximum(K - k, 0) * pe).sum() for k in K]
        return float(K[int(np.argmin(pain))])

    def to_dict(self, n=7) -> Dict:
        a, d = self.atm(), self.df
        near = d.iloc[max(0, int((d.strike - a).abs().argmin()) - n): int((d.strike - a).abs().argmin()) + n + 1]
        res, sup = self.walls()
        cols = ["strike", "ce_ltp", "pe_ltp", "ce_oi", "pe_oi", "ce_doi", "pe_doi"]
        return {"index": self.index, "spot": round(self.spot, 2), "expiry": str(self.expiry), "ts": self.ts.isoformat(),
                "atm": a, "pcr": round(self.pcr(), 2), "resistance": res, "support": sup, "max_pain": self.max_pain(),
                "call_oi": int(d.ce_oi.sum()), "put_oi": int(d.pe_oi.sum()),
                "call_oi_chg": int(d.ce_doi.sum()), "put_oi_chg": int(d.pe_doi.sum()),
                "oi_change_source": self.delta_src, "market_open": market_open(),
                "strikes": near[cols].round(2).to_dict("records")}


# ───────────────────────── Web (2nd source + news) ─────────────────────────
RISK_WORDS = ["rbi policy", "fed ", "budget", "war", "sebi", "circuit", "crash", "tariff", "election", "ban on", "default"]
BULL, BEAR = ["rally", "surge", "gain", "record high", "buying", "upbeat"], ["fall", "slump", "plunge", "selloff", "selling", "weak", "crash"]


class Web:
    def __init__(self):
        import requests
        self.s, self._warm = requests.Session(), 0.0
        self.s.headers.update({"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124 Safari/537.36",
                               "Accept": "application/json,text/html", "Accept-Language": "en-IN,en;q=0.9"})

    def nse_chain(self, symbol: str) -> Dict:
        if time.time() - self._warm > 240:
            self.s.get("https://www.nseindia.com", timeout=8)
            self._warm = time.time()
        r = self.s.get(f"https://www.nseindia.com/api/option-chain-indices?symbol={symbol}", timeout=8)
        r.raise_for_status()
        return r.json()

    def news(self, query="Nifty OR Sensex OR RBI OR Fed", hours=24) -> List[str]:
        r = self.s.get("https://news.google.com/rss/search", timeout=8,
                       params={"q": query, "hl": "en-IN", "gl": "IN", "ceid": "IN:en"})
        out, cut = [], datetime.now(ZoneInfo("UTC")) - timedelta(hours=hours)
        for it in ET.fromstring(r.content).iter("item"):
            try:
                dt = datetime.strptime(it.findtext("pubDate"), "%a, %d %b %Y %H:%M:%S %Z").replace(tzinfo=ZoneInfo("UTC"))
            except Exception:
                continue
            if dt >= cut:
                out.append(it.findtext("title") or "")
        return out[:40]


# ───────────────────────── Fast OI engine ─────────────────────────
class OIEngine:
    def __init__(self, client, window=12, ttl=3.0, delta_min=15, web: Optional[Web] = None):
        self.c, self.window, self.ttl, self.delta_min, self.web = client, window, ttl, delta_min, web
        self._m, self._day, self._cache = None, None, {}
        self._hist: Dict[str, deque] = defaultdict(lambda: deque(maxlen=900))
        client.min_gap = 1.05                     # getMarketData is limited to ~1 request/second

    def _master(self) -> pd.DataFrame:
        today = date.today()
        if self._m is not None and self._day == today:
            return self._m
        if os.path.exists(CACHE) and date.fromtimestamp(os.path.getmtime(CACHE)) == today:
            df = pd.read_pickle(CACHE)
        else:
            import requests
            df = pd.DataFrame(requests.get(MASTER_URL, timeout=90).json())
            df = df[df.instrumenttype.isin(["OPTIDX", "AMXIDX"])].copy()
            df["strike_f"] = pd.to_numeric(df.strike, errors="coerce") / 100          # master stores strike x100
            df["exp"] = pd.to_datetime(df.expiry, format="%d%b%Y", errors="coerce").dt.date
            df.to_pickle(CACHE)
        self._m, self._day = df, today
        return df

    def _md(self, mode: str, tokens: Dict[str, List[str]]) -> List[Dict]:
        if self.c.api is None:
            self.c.login()
        res = self.c._call(lambda: self.c.api.getMarketData(mode, tokens))
        return (res.get("data") or {}).get("fetched") or []

    def snapshot(self, idx: str) -> Chain:
        hit = self._cache.get(idx)
        if hit and time.time() - hit[0] < self.ttl:
            return hit[1]
        cfg, m = INDEX_CFG[idx], self._master()
        a = m[(m.instrumenttype == "AMXIDX") & (m.symbol.str.upper().isin(cfg["alias"]))]
        sp = (a.iloc[0].exch_seg, a.iloc[0].token) if len(a) else cfg["spot"]
        if not sp:
            raise RuntimeError(f"spot token for {idx} not found in master")
        spot = float(self._md("LTP", {sp[0]: [sp[1]]})[0]["ltp"])
        o = m[(m.instrumenttype == "OPTIDX") & (m.name == idx) & (m.exch_seg == cfg["seg"])]
        exps = sorted(e for e in o.exp.dropna().unique() if e >= date.today())
        if not exps:
            raise RuntimeError(f"no live expiry for {idx}")
        o = o[o.exp == exps[0]]
        ks = np.sort(o.strike_f.unique())
        step = float(np.median(np.diff(ks))) if len(ks) > 1 else 50.0
        atm = round(spot / step) * step
        o = o[(o.strike_f - atm).abs() <= self.window * step]
        toks = list(o.token)
        got: Dict[str, Dict] = {}
        for i in range(0, len(toks), 50):
            for r in self._md("FULL", {cfg["seg"]: toks[i:i + 50]}):
                got[str(r["symbolToken"])] = r
        rows, snap = [], {}
        for k, g in o.groupby("strike_f"):
            row = {"strike": float(k)}
            for side in ("CE", "PE"):
                x = g[g.symbol.str.endswith(side)]
                r = got.get(str(x.iloc[0].token), {}) if len(x) else {}
                d = r.get("depth") or {}
                b, s = (d.get("buy") or [{}])[0], (d.get("sell") or [{}])[0]
                p = side.lower()
                row.update({f"{p}_token": str(x.iloc[0].token) if len(x) else "", f"{p}_ltp": float(r.get("ltp", 0) or 0),
                            f"{p}_oi": float(r.get("opnInterest", 0) or 0), f"{p}_vol": float(r.get("tradeVolume", 0) or 0),
                            f"{p}_bid": float(b.get("price", 0) or 0), f"{p}_ask": float(s.get("price", 0) or 0)})
                snap[row[f"{p}_token"]] = row[f"{p}_oi"]
            rows.append(row)
        df = pd.DataFrame(rows).sort_values("strike").reset_index(drop=True)
        ch = Chain(idx, spot, exps[0], df, now_ist())
        self._deltas(ch, snap)
        self._cache[idx] = (time.time(), ch)
        return ch

    def _deltas(self, ch: Chain, snap: Dict[str, float]):
        h, now = self._hist[ch.index], time.time()
        base = None
        for ts, s in h:                                          # newest snapshot that is >= delta_min old
            if now - ts >= self.delta_min * 60:
                base = s
        if base is None and h and now - h[0][0] > 20:
            base = h[0][1]
        h.append((now, snap))
        for p in ("ce", "pe"):
            ch.df[f"{p}_doi"] = [v - (base or {}).get(t, v) for t, v in zip(ch.df[f"{p}_oi"], ch.df[f"{p}_token"])] if base else 0.0
        if base:
            ch.delta_src = "snapshot"
        elif self.web and INDEX_CFG[ch.index]["nse"]:            # no baseline yet -> use NSE day change
            try:
                js = self.web.nse_chain(ch.index)
                ch_map = {d["strikePrice"]: d for d in js["records"]["data"]}
                for p, key in (("ce", "CE"), ("pe", "PE")):
                    ch.df[f"{p}_doi"] = [float((ch_map.get(k, {}).get(key) or {}).get("changeinOpenInterest", 0)) for k in ch.df.strike]
                ch.delta_src = "nse_day"
            except Exception as e:
                log.warning("NSE delta fallback failed: %s", e)


# ───────────────────────── Verifier ─────────────────────────
@dataclass
class Check:
    name: str
    ok: Optional[bool]       # None = could not be verified (excluded from score)
    weight: float
    detail: str
    hard: bool = False       # hard fail = automatic REJECT


@dataclass
class Verdict:
    status: str
    score: float
    plan: Dict
    spot: float
    checks: List[Check]
    suggested: Optional[Dict] = None
    feedback: List[str] = field(default_factory=list)
    market_open: bool = True

    def to_dict(self):
        return {**asdict(self), "message": message(self)}


def _tick(x: float) -> float:
    return round(round(x / 0.05) * 0.05, 2)


class Verifier:
    def __init__(self, oi, web: Optional[Web] = None, trend_fn: Optional[Callable[[str], int]] = None):
        self.oi, self.web, self.trend_fn = oi, web, trend_fn

    def verify(self, plan: Dict) -> Verdict:
        idx, side = plan.get("index", "NIFTY"), str(plan.get("side", "")).upper()
        ch = self.oi.snapshot(idx)
        if side == "NONE":
            return Verdict("NO_TRADE", 0, plan, ch.spot, [], feedback=["planner found no edge"], market_open=market_open())
        C: List[Check] = []
        add = lambda n, ok, w, d, hard=False: C.append(Check(n, ok, w, d, hard))
        k, e, sl, t1 = (float(plan.get(x) or 0) for x in ("strike", "entry", "sl", "t1"))
        risk, rew = e - sl, t1 - e
        rr = rew / risk if risk > 0 else 0
        add("structure", side in ("CE", "PE") and 0 < sl < e < t1, 0, "option buying needs SL < entry < T1", True)
        far = abs(k - ch.spot) / ch.spot
        add("strike_vs_spot", far <= .04, 0, f"strike {k:g} is {far:.1%} away from live spot {ch.spot:.2f}", True)
        r = ch.row(k)
        add("strike_exists", r is not None, 0, f"{idx} {k:g} {'found' if r is not None else 'not in live chain'}", True)
        add("risk_reward", rr >= 1.5, 2, f"RR {rr:.2f} (need >= 1.5)")
        add("sl_size", bool(e) and .05 <= risk / e <= .30, 1, f"SL is {risk / e:.0%} of premium (ideal 5-30%)" if e else "no entry")
        ltp = 0.0
        if r is not None and side in ("CE", "PE"):
            p = side.lower()
            ltp = float(r[f"{p}_ltp"])
            dev = abs(e - ltp) / ltp if ltp else 1
            add("entry_vs_ltp", dev <= .03, 2, f"entry {e} vs live LTP {ltp} ({dev:.1%} off)")
            add("entry_not_stale", dev <= .10, 0, f"entry is {dev:.0%} away from live LTP {ltp}", True)
            bid, ask, vol = float(r[f"{p}_bid"]), float(r[f"{p}_ask"]), float(r[f"{p}_vol"])
            spread = (ask - bid) / ltp if (ask and bid and ltp) else None
            add("liquidity", (vol > 0 or not market_open()) and (spread is None or spread <= .03), 2,
                f"vol {vol:,.0f}, OI {r[f'{p}_oi']:,.0f}, spread {'n/a' if spread is None else f'{spread:.1%}'}")
        near = ch.df[(ch.df.strike - ch.atm()).abs() <= 5 * (ch.df.strike.diff().median() or 50)]
        bull = float(near.pe_doi.sum() - near.ce_doi.sum())
        if ch.delta_src == "none":
            add("oi_alignment", None, 3, "no OI baseline yet (wait one snapshot or enable NSE fallback)")
        else:
            good = bull > 0 if side == "CE" else bull < 0
            add("oi_alignment", good, 3, f"near-ATM put OI chg {near.pe_doi.sum():,.0f} vs call {near.ce_doi.sum():,.0f} "
                f"({'supports' if good else 'against'} {side}); PCR {ch.pcr():.2f}")
        res, sup = ch.walls()
        if side == "CE" and res:
            add("oi_wall", res > ch.spot * 1.004 and k <= res, 2, f"call wall (resistance) {res:g}, spot {ch.spot:.0f}")
        elif side == "PE" and sup:
            add("oi_wall", sup < ch.spot * .996 and k >= sup, 2, f"put wall (support) {sup:g}, spot {ch.spot:.0f}")
        if self.trend_fn:
            try:
                t = self.trend_fn(idx)
                add("trend_5m", t == (1 if side == "CE" else -1), 2, f"5m trend {'up' if t > 0 else 'down' if t < 0 else 'flat'}")
            except Exception as ex:
                add("trend_5m", None, 2, f"trend unavailable: {ex}")
        self._web_checks(idx, side, ch, k, add)
        mo, t = market_open(), now_ist()
        add("time_window", None if not mo else (t.hour, t.minute) < (15, 15), 1,
            "market closed - using last session data" if not mo else "avoid entries after 15:15")
        add("expiry_day", (ch.expiry - date.today()).days >= 1, 1, f"expiry {ch.expiry} (theta is brutal on expiry day)")

        sc = [c for c in C if c.weight > 0 and c.ok is not None]
        score = sum(c.weight for c in sc if c.ok) / max(1e-9, sum(c.weight for c in sc))
        hard = any(c.hard and c.ok is False for c in C)
        status = "REJECT" if hard else "CONFIRMED" if score >= .75 else "CAUTION" if score >= .55 else "REJECT"
        fb = [f"{c.name}: {c.detail}" for c in C if c.ok is False]
        v = Verdict(status, round(score, 3), plan, ch.spot, C, feedback=fb, market_open=mo)
        if status != "CONFIRMED":
            v.suggested = self._suggest(plan, ch, side, ltp if ltp else None)
        return v

    def _web_checks(self, idx, side, ch, k, add):
        if not self.web:
            return
        if INDEX_CFG[idx]["nse"]:
            try:
                js = self.web.nse_chain(idx)
                nspot = float(js["records"]["underlyingValue"])
                diff = abs(nspot - ch.spot) / ch.spot
                row = next((d for d in js["records"]["data"] if d["strikePrice"] == k), {})
                x = (row.get(side) or {}).get("openInterest")
                mine = ch.row(k)
                oi_diff = abs(x - mine[f"{side.lower()}_oi"]) / x if (x and mine is not None) else 0
                add("web_crosscheck", diff <= .0025 and oi_diff <= .15, 2,
                    f"NSE spot {nspot:.2f} vs Angel {ch.spot:.2f} ({diff:.2%}); strike OI diff {oi_diff:.0%}")
            except Exception as ex:
                add("web_crosscheck", None, 2, f"NSE unreachable: {type(ex).__name__}")
        try:
            heads = [h.lower() for h in self.web.news()]
            risk = [h for h in heads if any(w in h for w in RISK_WORDS)]
            bu, be = sum(any(w in h for w in BULL) for h in heads), sum(any(w in h for w in BEAR) for h in heads)
            against = (side == "CE" and be >= 3 * max(1, bu)) or (side == "PE" and bu >= 3 * max(1, be))
            add("news_risk", len(risk) < 4 and not against, 1,
                f"{len(heads)} headlines/24h, {len(risk)} event-risk, bull {bu} / bear {be}")
        except Exception as ex:
            add("news_risk", None, 1, f"news unavailable: {type(ex).__name__}")

    def _suggest(self, plan, ch: Chain, side, ltp):
        if side not in ("CE", "PE"):
            return None
        k = float(plan.get("strike") or 0)
        if ch.row(k) is None or abs(k - ch.spot) / ch.spot > .04:
            k = ch.atm()
        r = ch.row(k)
        p = float(r[f"{side.lower()}_ltp"]) if r is not None else 0
        if p <= 0:
            return None
        risk = p * .15
        return {"index": ch.index, "side": side, "strike": k, "entry": _tick(p), "sl": _tick(p - risk),
                "t1": _tick(p + 1.5 * risk), "t2": _tick(p + 2.5 * risk), "basis": "live LTP, SL 15%, RR 1:1.5 / 1:2.5"}


def message(v: Verdict) -> str:
    ic = {"CONFIRMED": "✅", "CAUTION": "⚠️", "REJECT": "❌", "NO_TRADE": "⏸"}[v.status]
    p = v.plan
    if v.status == "NO_TRADE":
        return f"{ic} NO TRADE - AI ko koi edge nahi mila."
    t = f"{ic} {p.get('index')} {p.get('side')} {p.get('strike')} - {v.status} ({v.score:.0%})\nSpot {v.spot:.2f}"
    if v.status in ("CONFIRMED", "CAUTION"):
        t += f"\nEntry {p.get('entry')} | SL {p.get('sl')} | T1 {p.get('t1')}" + (f" | T2 {p.get('t2')}" if p.get("t2") else "")
    if v.status == "CAUTION":
        t += "\nQuantity aadhi rakho."
    if v.feedback:
        t += "\nProblem:\n- " + "\n- ".join(v.feedback[:4])
    if v.suggested and v.status != "CONFIRMED":
        s = v.suggested
        t += f"\nSudhra hua plan: {s['side']} {s['strike']:g} Entry {s['entry']} SL {s['sl']} T1 {s['t1']}"
    if not v.market_open:
        t += "\n(Market band hai: live numbers pichhle session ke hain)"
    return t


# ───────────────────────── AI <-> verifier conversation ─────────────────────────
SYSTEM = ("You plan option-BUYING trades on Indian index options. Use ONLY the numbers in the data given; never invent "
          "prices. Entry must be near the LTP of that strike. Reply with ONLY JSON: "
          '{"index":"","side":"CE|PE|NONE","strike":0,"entry":0,"sl":0,"t1":0,"t2":0}. If there is no clear edge, side=NONE.')


class ClaudePlanner:
    """Plugs Claude in as the planner. Set ANTHROPIC_API_KEY."""

    def __init__(self, model="claude-sonnet-5-5"):
        import anthropic
        self.cl, self.model = anthropic.Anthropic(), model

    def propose(self, summary: Dict, feedback: Optional[Dict]) -> Dict:
        msg = f"LIVE DATA:\n{json.dumps(summary)}\n"
        msg += (f"Your last plan was checked and failed:\n{json.dumps(feedback)}\nReturn a corrected plan."
                if feedback else "Create one plan.")
        r = self.cl.messages.create(model=self.model, max_tokens=400, system=SYSTEM,
                                    messages=[{"role": "user", "content": msg}])
        t = r.content[0].text
        return json.loads(t[t.find("{"): t.rfind("}") + 1])


def negotiate(planner, ver: Verifier, index: str, rounds=3, trend: Optional[int] = None) -> Dict:
    feedback, v, log_ = None, None, []
    for i in range(rounds):
        summary = ver.oi.snapshot(index).to_dict()
        summary["trend_5m"] = trend
        plan = planner.propose(summary, feedback)
        plan.setdefault("index", index)
        v = ver.verify(plan)
        log_.append({"round": i + 1, "plan": plan, "status": v.status, "score": v.score})
        if v.status in ("CONFIRMED", "NO_TRADE"):
            break
        feedback = {"status": v.status, "problems": v.feedback, "suggested": v.suggested}
    d = v.to_dict()
    d["rounds"], d["history"] = len(log_), log_
    d["signal"] = v.status == "CONFIRMED"       # only this may trigger an alert / order
    return d


def notify_telegram(text: str):
    import requests
    requests.post(f"https://api.telegram.org/bot{os.environ['TG_TOKEN']}/sendMessage",
                  json={"chat_id": os.environ["TG_CHAT"], "text": text}, timeout=10)


def make_trend_fn(client) -> Callable[[str], int]:
    """5m trend: EMA9/21 + Supertrend must agree (uses angel_data_layer)."""
    from angel_data_layer import FeatureStore
    def fn(idx: str) -> int:
        cfg = INDEX_CFG[idx]
        ex, tok = cfg["spot"] or ("BSE", "")
        df = client.candles(ex, tok, "FIVE_MINUTE", datetime.now() - timedelta(days=6), datetime.now())
        fs = FeatureStore(df[df.closed])
        e9, e21, st = fs.get("ema", n=9), fs.get("ema", n=21), fs.get("supertrend", n=10, m=3.0)["dir"]
        up = e9.iloc[-1] > e21.iloc[-1] and st.iloc[-1] > 0
        dn = e9.iloc[-1] < e21.iloc[-1] and st.iloc[-1] < 0
        return 1 if up else -1 if dn else 0
    return fn


# ───────────────────────── API for the app ─────────────────────────
def make_app(oi: OIEngine, ver: Verifier, planner=None):
    from fastapi import FastAPI, HTTPException
    app = FastAPI(title="NSE AI Terminal backend")

    @app.get("/oi/{index}")
    def oi_ep(index: str):
        if index.upper() not in INDEX_CFG:
            raise HTTPException(404, "unknown index")
        return oi.snapshot(index.upper()).to_dict()

    @app.post("/verify")
    def verify_ep(plan: Dict):
        return ver.verify(plan).to_dict()

    @app.get("/signal/{index}")
    def signal_ep(index: str):
        if planner is None:
            raise HTTPException(503, "planner not configured")
        return negotiate(planner, ver, index.upper())
    return app


if os.environ.get("ANGEL_API_KEY"):          # `uvicorn trade_verifier:app`
    from angel_data_layer import AngelClient
    _c = AngelClient(os.environ["ANGEL_API_KEY"], os.environ["ANGEL_CLIENT"], os.environ["ANGEL_PIN"], os.environ["ANGEL_TOTP_SECRET"])
    _web = Web()
    _oi = OIEngine(_c, web=_web)
    _ver = Verifier(_oi, _web, make_trend_fn(_c))
    app = make_app(_oi, _ver, ClaudePlanner() if os.environ.get("ANTHROPIC_API_KEY") else None)


# ───────────────────────── self-test (offline) ─────────────────────────
def _fake_chain(idx, spot, step, expiry_days=4) -> Chain:
    ks = np.arange(round(spot / step) * step - 12 * step, round(spot / step) * step + 13 * step, step)
    rng = np.random.default_rng(3)
    rows = []
    for k in ks:
        d = abs(k - spot)
        ce, pe = max(spot - k, 0) + 0.8 * step * np.exp(-d / (4 * step)), max(k - spot, 0) + 0.8 * step * np.exp(-d / (4 * step))
        wall_c, wall_p = 6 if k == ks[19] else 1, 6 if k == ks[6] else 1
        near = d <= 4 * step
        rows.append({"strike": float(k), "ce_token": f"c{k}", "pe_token": f"p{k}", "ce_ltp": round(ce, 2), "pe_ltp": round(pe, 2),
                     "ce_oi": 1e5 * wall_c * (1 + rng.random()), "pe_oi": 1e5 * wall_p * (1 + rng.random()),
                     "ce_vol": 5e4, "pe_vol": 5e4, "ce_bid": round(ce * .995, 2), "ce_ask": round(ce * 1.005, 2),
                     "pe_bid": round(pe * .995, 2), "pe_ask": round(pe * 1.005, 2),
                     "ce_doi": -3e4 if near else 0, "pe_doi": 5e4 if near else 0})
    return Chain(idx, spot, date.today() + timedelta(days=expiry_days), pd.DataFrame(rows), now_ist(), "snapshot")


class _FakeOI:
    def __init__(self):
        self.c = {"NIFTY": _fake_chain("NIFTY", 24650, 50), "BANKNIFTY": _fake_chain("BANKNIFTY", 61356.13, 100)}

    def snapshot(self, idx):
        return self.c[idx]


class _DemoPlanner:        # round 1 = the wrong plan from your screenshot, round 2 = fixed using feedback
    def propose(self, summary, feedback):
        if not feedback:
            return {"index": summary["index"], "side": "CE", "strike": 24700, "entry": 102.3, "sl": 94.5, "t1": 112.4}
        return {**feedback["suggested"], "index": summary["index"]}


def selftest():
    oi = _FakeOI()
    ver = Verifier(oi, None, lambda i: 1)
    ch = oi.snapshot("NIFTY")
    r = ch.row(24700)
    good = {"index": "NIFTY", "side": "CE", "strike": 24700, "entry": float(r.ce_ltp), "sl": round(float(r.ce_ltp) * .85, 2),
            "t1": round(float(r.ce_ltp) * 1.25, 2)}
    print("--- plan that matches live data ---")
    print(message(ver.verify(good)))
    print("\n--- screenshot plan (CE 24700) on an index whose spot is 61356 ---")
    bad = {"index": "BANKNIFTY", "side": "CE", "strike": 24700, "entry": 102.3, "sl": 94.5, "t1": 112.4}
    print(message(ver.verify(bad)))
    print("\n--- AI <-> verifier conversation ---")
    out = negotiate(_DemoPlanner(), ver, "NIFTY")
    print(out["message"])
    print("rounds:", out["rounds"], "| signal:", out["signal"], "|", [(h["round"], h["status"]) for h in out["history"]])


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    selftest()