"""Angel One live OI-buildup engine (entry/SL/target) + NSE-trained AI trend filter."""
import csv, os
from collections import deque
import numpy as np
import config as C
import ai_model

NSE_LOG = "data/nse_features.csv"


def classify(dp, doi):
    if dp > 0 and doi > 0: return "LONG_BUILDUP"
    if dp > 0 and doi < 0: return "SHORT_COVERING"
    if dp < 0 and doi > 0: return "SHORT_BUILDUP"
    if dp < 0 and doi < 0: return "LONG_UNWINDING"
    return "NEUTRAL"

CE_DIR = {"LONG_BUILDUP": 1, "SHORT_COVERING": 1, "SHORT_BUILDUP": -1, "LONG_UNWINDING": -1, "NEUTRAL": 0}
PE_DIR = {k: -v for k, v in CE_DIR.items()}


def ema(arr, n):
    a = 2 / (n + 1); e = arr[0]
    for x in arr[1:]: e = a * x + (1 - a) * e
    return e


class Engine:
    def __init__(self):
        self.hist = deque(maxlen=2000)
        self.position = None
        self.nse = None
        self.nse_view = None
        self.last = {"action": "WAIT", "reasons": ["Warming up... data collect ho raha hai"]}

    def set_nse(self, f, ts):
        p, src = ai_model.p_up(f)
        self.nse = f
        self.nse_view = {"trend": ai_model.label(p), "p_up": p, "source": src,
                         "pcr": round(f["pcr_oi"], 2), "support": f["_support"],
                         "resistance": f["_resistance"], "max_pain": f["_maxpain"], "ts": ts}
        os.makedirs("data", exist_ok=True)
        new = not os.path.exists(NSE_LOG)
        with open(NSE_LOG, "a", newline="") as fh:
            w = csv.writer(fh)
            if new: w.writerow(["ts", "spot"] + list(f.keys())[:9])
            w.writerow([ts, f["_spot"]] + [round(f[k], 6) for k in ["pcr_oi","pcr_chg","chg_imb","buildup","dist_sup","dist_res","maxpain_dist","iv_skew","d_imb"]])

    def _base(self, now):
        for s in self.hist:
            if now - s["ts"] <= C.LOOKBACK_SEC: return s
        return None

    def update(self, snap):
        now = snap["ts"]; self.hist.append(snap)
        base = self._base(now)
        if base is None or base is snap or now - base["ts"] < 30:
            return self.last

        score_sum = w_sum = ce_oi = pe_oi = 0.0
        rows = []
        strikes = sorted({k[0] for k in snap["opts"]})
        step = (strikes[1] - strikes[0]) if len(strikes) > 1 else 50
        for (strike, typ), cur in snap["opts"].items():
            old = base["opts"].get((strike, typ))
            if not old or old["oi"] <= 0: continue
            dp, doi = cur["ltp"] - old["ltp"], cur["oi"] - old["oi"]
            cls = classify(dp, doi)
            d = (CE_DIR if typ == "CE" else PE_DIR)[cls]
            prox = 1 / (1 + abs(strike - snap["atm"]) / max(step, 1))
            mag = min(abs(doi) / old["oi"], 0.2) / 0.2
            score_sum += d * mag * prox; w_sum += prox
            if typ == "CE": ce_oi += cur["oi"]
            else: pe_oi += cur["oi"]
            rows.append((strike, typ, cls, round(dp, 2), int(doi)))
        if w_sum == 0: return self.last

        oi_score = score_sum / w_sum
        pcr = pe_oi / ce_oi if ce_oi else 1.0
        pcr_sig = 1 if pcr > 1.2 else -1 if pcr < 0.8 else 0
        spots = np.array([s["spot"] for s in self.hist])
        trend = 0
        if len(spots) >= 21:
            f_, s_ = ema(spots[-60:], 9), ema(spots[-60:], 21)
            trend = 1 if f_ > s_ * 1.0002 else -1 if f_ < s_ * 0.9998 else 0
        score = 0.5 * oi_score + 0.3 * trend + 0.2 * pcr_sig

        atm = snap["atm"]
        reasons = [f"Angel OI score {oi_score:+.2f}", f"PCR(live) {pcr:.2f}",
                   f"EMA trend {'UP' if trend > 0 else 'DOWN' if trend < 0 else 'FLAT'}",
                   f"Score {score:+.2f} (threshold ±{C.THRESH})"]
        reasons += [f"ATM {r[1]}: {r[2]} (Δprice {r[3]}, ΔOI {r[4]})" for r in rows if r[0] == atm]
        nse = self.nse_view
        if nse:
            reasons.append(f"NSE AI: {nse['trend']} (p_up {nse['p_up']}, {nse['source']})")

        if self.position:
            p = self.position
            cur = snap["opts"].get((p["strike"], p["typ"]))
            if cur:
                ltp = cur["ltp"]; reason = None
                p_up = nse["p_up"] if nse else 0.5
                ai_flip = (p["typ"] == "CE" and p_up <= 1 - C.AI_MIN_CONF) or (p["typ"] == "PE" and p_up >= C.AI_MIN_CONF)
                if ltp <= p["sl"]: reason = "STOPLOSS HIT"
                elif ltp >= p["target"]: reason = "TARGET HIT"
                elif (p["typ"] == "CE" and score <= -C.THRESH) or (p["typ"] == "PE" and score >= C.THRESH):
                    reason = "TREND REVERSAL (Angel OI)"
                elif ai_flip: reason = "NSE AI TREND FLIPPED"
                pnl = round((ltp / p["entry"] - 1) * 100, 2)
                if reason:
                    self.last = {"action": "EXIT", "symbol": snap.get("symbol", C.SYMBOL), "optionSymbol": p.get("optionSymbol"), "strike": p["strike"], "type": p["typ"], "ltp": ltp,
                                 "pnl_pct": pnl, "reasons": [reason] + reasons, **self._meta(snap, score)}
                    self.position = None; return self.last
                self.last = {"action": "HOLD", "symbol": snap.get("symbol", C.SYMBOL), "optionSymbol": p.get("optionSymbol"), "strike": p["strike"], "type": p["typ"], "entry": p["entry"],
                             "ltp": ltp, "sl": p["sl"], "target": p["target"], "pnl_pct": pnl,
                             "reasons": reasons, **self._meta(snap, score)}
                return self.last

        if abs(score) >= C.THRESH:
            typ = "CE" if score > 0 else "PE"
            opt = snap["opts"].get((atm, typ))
            block = None
            if nse is None:
                block = "NSE data abhi aaya nahi -> WAIT"
            else:
                conf = nse["p_up"] if typ == "CE" else 1 - nse["p_up"]
                if conf < C.AI_MIN_CONF: block = f"NSE AI confidence {conf:.2f} < {C.AI_MIN_CONF} -> WAIT"
                elif typ == "CE" and 0 <= (nse["resistance"] - snap["spot"]) / snap["spot"] < 0.0015:
                    block = f"Spot resistance {nse['resistance']} ke bahut paas -> CE skip"
                elif typ == "PE" and 0 <= (snap["spot"] - nse["support"]) / snap["spot"] < 0.0015:
                    block = f"Spot support {nse['support']} ke bahut paas -> PE skip"
            if block:
                reasons.append(block)
            elif opt and opt["ltp"] > 0:
                entry = opt["ltp"]
                sl = round(entry * (1 - C.SL_PCT), 2); tgt = round(entry * (1 + C.SL_PCT * C.RR), 2)
                self.position = {"strike": atm, "typ": typ, "entry": entry, "sl": sl, "target": tgt}
                self.last = {"action": f"BUY_{typ}", "symbol": snap.get("symbol", C.SYMBOL), "optionSymbol": opt.get("symbol"), "strike": atm, "type": typ, "ltp": entry, "entry": entry, "sl": sl,
                             "target": tgt, "ai_confidence": round(conf, 3), "reasons": reasons,
                             "exit_rule": "SL / Target / Angel reversal / NSE-AI flip", **self._meta(snap, score)}
                return self.last
        self.last = {"action": "WAIT", "reasons": reasons, **self._meta(snap, score)}
        return self.last

    def _meta(self, snap, score):
        opt = None
        for typ in ("CE","PE"):
            candidate = snap.get("opts", {}).get((snap.get("atm"), typ))
            if candidate:
                opt = candidate
                break
        return {"spot": snap["spot"], "atm": snap["atm"], "score": round(score, 3), "ts": snap["ts"],
                "underlying": C.SYMBOL, "optionSymbol": (opt or {}).get("symbol"),
                "optionToken": (opt or {}).get("token"), "ltp": (opt or {}).get("ltp")}
