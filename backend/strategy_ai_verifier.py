"""Six-provider evidence verifier. It cannot create or modify a trade candidate."""
from __future__ import annotations
import concurrent.futures, json, os, time
from ai_orchestrator import PROVIDERS, _openai, _openai_compat, _anthropic, _gemini

ROLE_LENSES={
 "gpt56-luna":"candidate/evidence consistency",
 "claude-sonnet":"contradictions and missing evidence",
 "gpt56-sol":"independent rule/metric validation",
 "deepseek":"quantitative metrics and OI consistency",
 "gemini-flash":"price structure and regime consistency",
 "grok-4":"risk, failure conditions and WAIT downgrade",
}
SYSTEM="""You are an evidence auditor inside a paper-trading strategy engine.
Never invent market data. Never create a new signal. Never change entry, SL, target, strike or strategy rules.
The engine owns the decision. You may only PASS or FAIL the supplied candidate and flag risks.
Do not infer hidden orders, guarantees, or win rates.
Return ONLY valid JSON with:
{"verdict":"PASS|FAIL","overfit_risk":"LOW|MEDIUM|HIGH","weak_points":[],"fix":[],"opposite_side_block":false}
"""

def _evidence(payload:dict)->dict:
    return {
      "engine_decision":payload.get("engine_decision","WAIT"),
      "candidate":payload.get("candidate",{}),
      "data_quality":payload.get("data_quality",{}),
      "train_metrics":payload.get("train_metrics",payload.get("metrics",{})),
      "out_of_sample_summary":payload.get("test_metrics",{}),
      "strategy_id":payload.get("strategy_id"),
      "strategy_version":payload.get("strategy_version"),
    }

def _prompt(provider,payload):
    import json
    return SYSTEM+"\nLens: "+ROLE_LENSES.get(provider["id"],"independent audit")+"\nEvidence:\n"+json.dumps(_evidence(payload),ensure_ascii=False,separators=(",",":"),default=str)[:18000]

def _call(p,payload):
    base={"id":p["id"],"name":p["name"],"model":p["model"],"lens":ROLE_LENSES.get(p["id"]),"status":"not_configured"}
    if not os.getenv(p["env"]): return base
    started=time.monotonic()
    try:
        prompt=_prompt(p,payload)
        if p["kind"]=="openai": raw=_openai(p,prompt)
        elif p["kind"]=="anthropic": raw=_anthropic(p,prompt)
        elif p["kind"]=="gemini": raw=_gemini(p,prompt)
        else: raw=_openai_compat(p,prompt)
        try:
            data=json.loads(raw.strip())
            verdict=str(data.get("verdict","FAIL")).upper()
            risk=str(data.get("overfit_risk","HIGH")).upper()
            return {**base,"status":"ok","verdict":verdict if verdict in {"PASS","FAIL"} else "FAIL",
                    "overfit_risk":risk if risk in {"LOW","MEDIUM","HIGH"} else "HIGH",
                    "weak_points":list(data.get("weak_points",[]))[:5],
                    "fix":list(data.get("fix",[]))[:5],
                    "opposite_side_block":bool(data.get("opposite_side_block",False)),
                    "elapsed_ms":round((time.monotonic()-started)*1000)}
        except Exception as e:
            return {**base,"status":"invalid_json","error":str(e)[:160]}
    except Exception as e:
        return {**base,"status":"error","error":str(e)[:300]}

def verify_engine_result(payload:dict)->dict:
    engine_decision=str(payload.get("engine_decision","WAIT")).upper()
    if engine_decision not in {"CALL BUY","PUT BUY","WAIT","NO QUALIFYING TRADE"}:
        engine_decision="WAIT"
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(PROVIDERS)) as ex:
        results=list(ex.map(lambda p:_call(p,payload),PROVIDERS))
    ok=[r for r in results if r.get("status")=="ok"]
    passes=sum(r.get("verdict")=="PASS" for r in ok)
    blocks=any(r.get("opposite_side_block") for r in ok)
    high_risk=any(r.get("overfit_risk")=="HIGH" for r in ok)
    consensus=len(ok)>=4 and passes>=4 and not blocks and not high_risk
    final="WAIT" if engine_decision in {"CALL BUY","PUT BUY"} and not consensus else engine_decision
    return {"engine_decision":engine_decision,"final":final,
            "ai_can_only_downgrade":True,"consensus":consensus,
            "passes":passes,"successful":len(ok),"total":len(results),
            "opposite_side_block":blocks,"high_overfit_risk":high_risk,
            "providers":results,
            "raw_market_data_sent_to_ai":False,
            "test_candles_sent_to_ai":False,
            "test_trades_sent_to_ai":False}
