"""Turn NSE option-chain into AI features + a rule-based trend fallback."""
import math

FEATURES = ["pcr_oi", "pcr_chg", "chg_imb", "buildup", "dist_sup", "dist_res",
            "maxpain_dist", "iv_skew", "d_imb"]

_DIR = {"LONG_BUILDUP": 1, "SHORT_COVERING": 1, "SHORT_BUILDUP": -1, "LONG_UNWINDING": -1, "NEUTRAL": 0}


def _cls(dp, doi):
    if dp > 0 and doi > 0: return "LONG_BUILDUP"
    if dp > 0 and doi < 0: return "SHORT_COVERING"
    if dp < 0 and doi > 0: return "SHORT_BUILDUP"
    if dp < 0 and doi < 0: return "LONG_UNWINDING"
    return "NEUTRAL"


def _safe(a, b): return a / b if b else 0.0


def compute(ch, prev=None, n=6):
    rows, spot = ch["rows"], ch["spot"]
    atm_i = min(range(len(rows)), key=lambda i: abs(rows[i]["strike"] - spot))
    win = rows[max(0, atm_i - n): atm_i + n + 1]

    ce_oi = sum(r["ce"]["oi"] for r in rows); pe_oi = sum(r["pe"]["oi"] for r in rows)
    ce_chg = sum(r["ce"]["chg_oi"] for r in rows); pe_chg = sum(r["pe"]["chg_oi"] for r in rows)
    pcr_oi = _safe(pe_oi, ce_oi)
    pcr_chg = max(-3, min(3, _safe(pe_chg, ce_chg))) if ce_chg else 0.0
    chg_imb = _safe(pe_chg - ce_chg, abs(pe_chg) + abs(ce_chg))

    s = w = 0.0
    for i, r in enumerate(win):
        prox = 1 / (1 + abs(r["strike"] - rows[atm_i]["strike"]) / max(1, (rows[1]["strike"] - rows[0]["strike"])))
        for typ, sign in (("ce", 1), ("pe", -1)):
            x = r[typ]; base = x["oi"] - x["chg_oi"]
            if base <= 0: continue
            mag = min(abs(x["chg_oi"]) / base, 1.0)
            s += sign * _DIR[_cls(x["chg"], x["chg_oi"])] * mag * prox; w += prox
    buildup = _safe(s, w)

    sup = max(rows, key=lambda r: r["pe"]["oi"])["strike"]
    res = max(rows, key=lambda r: r["ce"]["oi"])["strike"]
    dist_sup = (spot - sup) / spot; dist_res = (res - spot) / spot
    pain = min(rows, key=lambda k: sum(r["ce"]["oi"] * max(k["strike"] - r["strike"], 0) +
                                        r["pe"]["oi"] * max(r["strike"] - k["strike"], 0) for r in rows))["strike"]
    maxpain_dist = (pain - spot) / spot
    a = rows[atm_i]
    iv_skew = (a["pe"]["iv"] - a["ce"]["iv"]) / 100

    d_imb = 0.0
    if prev:
        dce = ce_oi - sum(r["ce"]["oi"] for r in prev["rows"])
        dpe = pe_oi - sum(r["pe"]["oi"] for r in prev["rows"])
        d_imb = _safe(dpe - dce, abs(dpe) + abs(dce))

    f = dict(pcr_oi=pcr_oi, pcr_chg=pcr_chg, chg_imb=chg_imb, buildup=buildup, dist_sup=dist_sup,
             dist_res=dist_res, maxpain_dist=maxpain_dist, iv_skew=iv_skew, d_imb=d_imb)
    f["_support"], f["_resistance"], f["_maxpain"], f["_spot"] = sup, res, pain, spot
    return f


def rule_p_up(f):
    c = lambda x: max(-1.0, min(1.0, x))
    s = (0.25 * c((f["pcr_oi"] - 1) / 0.4) + 0.2 * c(f["chg_imb"]) + 0.25 * c(f["buildup"] * 2)
         + 0.1 * c(f["d_imb"]) + 0.1 * c(f["maxpain_dist"] * 200) + 0.1 * c(-f["iv_skew"] * 10))
    if f["dist_sup"] < 0.003: s += 0.15
    if f["dist_res"] < 0.003: s -= 0.15
    return 0.5 + 0.4 * c(s)
