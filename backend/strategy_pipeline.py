"""JSON strategy lifecycle: validate -> train -> bounded tuning -> unseen test -> lock.
No arbitrary AI-generated code is executed.
"""
from __future__ import annotations
from strategy_engine import run_backtest, approve_test, validate_strategy
from strategy_store import save_version

MAX_ROUNDS=5

def split_train_test(bars):
    n=len(bars); cut=int(n*0.60)
    return bars[:cut],bars[cut:]

def evaluate_candidate(strategy, bars, brokerage=0.0, slippage=0.0):
    validate_strategy(strategy)
    train,test=split_train_test(bars)
    train_result=run_backtest(strategy,train,brokerage,slippage)
    test_result=run_backtest(strategy,test,brokerage,slippage)
    approval=approve_test(test_result.metrics,
                          min_trades=100,
                          min_profit_factor=1.5)
    record=save_version(strategy,train_result.metrics,test_result.metrics,approval)
    return {"strategy":strategy,"train":train_result.metrics,
            "test":test_result.metrics,"approval":approval,"lock":record}

def ai_verdict_schema():
    return {"verdict":"PASS|FAIL","overfit_risk":"LOW|MEDIUM|HIGH",
            "weak_points":[],"fix":[],"engine_override":False}

def ai_evidence_payload(engine_result: dict) -> dict:
    """Only compact engine evidence is sent to AI; raw chain is intentionally excluded."""
    return {"engine_decision":engine_result.get("decision","WAIT"),
            "metrics":engine_result.get("metrics",{}),
            "sample_trades":engine_result.get("trades",[])[:30],
            "data_quality":engine_result.get("data_quality",{}),
            "candidate":engine_result.get("candidate",{})}

def aggregate_ai_verdicts(verdicts: list[dict], engine_decision: str) -> dict:
    verdicts=[v for v in verdicts if isinstance(v,dict)]
    passes=sum(1 for v in verdicts if str(v.get("verdict","")).upper()=="PASS")
    blocks=sum(1 for v in verdicts if bool(v.get("opposite_side_block")) or str(v.get("overfit_risk","")).upper()=="HIGH")
    consensus=passes>=4 and len(verdicts)>=4
    downgraded=blocks>0 or not consensus
    final="WAIT" if downgraded and engine_decision in {"CALL BUY","PUT BUY"} else engine_decision
    return {"engine_decision":engine_decision,"ai_passes":passes,
            "ai_total":len(verdicts),"downgraded":downgraded,
            "final":final,"ai_can_only_downgrade":True}
