"""FastAPI router for deterministic JSON strategies and six-AI evidence verification."""
from __future__ import annotations
from typing import Any
from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel
import config as C
from strategy_engine import evaluate_strategy, run_backtest, validate_strategy, approve_test
from strategy_store import get_version, save_version
from strategy_pipeline import split_train_test
from strategy_ai_verifier import verify_engine_result

router=APIRouter(prefix="/v1/strategy",tags=["strategy"])

class EvaluateRequest(BaseModel):
    strategy:dict
    state:dict

class BacktestRequest(BaseModel):
    strategy:dict
    bars:list[dict]
    brokerage:float=0.0
    slippage:float=0.0

class VerifyRequest(BaseModel):
    engine_result:dict

class LockRequest(BaseModel):
    strategy:dict
    train_metrics:dict={}
    test_metrics:dict={}
    approval:dict

def _auth(token):
    if token!=C.API_TOKEN: raise HTTPException(401,"bad token")

@router.get("/blocks")
def blocks(x_token:str=Header(None)):
    _auth(x_token)
    from strategy_engine import ALLOWED_BLOCKS
    return {"blocks":sorted(ALLOWED_BLOCKS),"ai_may_select_only":True,"arbitrary_code":False}

@router.post("/validate")
def validate(body:EvaluateRequest,x_token:str=Header(None)):
    _auth(x_token)
    try: return {"valid":True,"strategy":validate_strategy(body.strategy)}
    except Exception as e: raise HTTPException(400,str(e))

@router.post("/evaluate")
def evaluate(body:EvaluateRequest,x_token:str=Header(None)):
    _auth(x_token)
    try: return evaluate_strategy(body.strategy,body.state)
    except Exception as e: raise HTTPException(400,str(e))

@router.post("/backtest")
def backtest(body:BacktestRequest,x_token:str=Header(None)):
    _auth(x_token)
    try:
        validate_strategy(body.strategy)
        train,test=split_train_test(body.bars)
        tr=run_backtest(body.strategy,train,body.brokerage,body.slippage)
        te=run_backtest(body.strategy,test,body.brokerage,body.slippage)
        approval=approve_test(te.metrics)
        return {"train":{"metrics":tr.metrics,"trades":tr.trades[:30]},
                "test":{"metrics":te.metrics,"trades":te.trades[:30]},
                "approval":approval,"lookahead_safe":True,
                "test_seen_by_ai":False}
    except Exception as e: raise HTTPException(400,str(e))

@router.post("/ai-verify")
def ai_verify(body:VerifyRequest,x_token:str=Header(None)):
    _auth(x_token)
    try: return verify_engine_result(body.engine_result)
    except Exception as e: raise HTTPException(500,str(e))

@router.post("/lock")
def lock(body:LockRequest,x_token:str=Header(None)):
    _auth(x_token)
    if not body.approval.get("approved"): raise HTTPException(400,"strategy is not approved by engine metrics")
    try:
        return save_version(body.strategy,body.train_metrics,body.test_metrics,body.approval)
    except Exception as e: raise HTTPException(400,str(e))

@router.get("/version/{strategy_id}/{version}")
def version(strategy_id:str,version:str,x_token:str=Header(None)):
    _auth(x_token)
    value=get_version(strategy_id,version)
    if value is None: raise HTTPException(404,"strategy version not found")
    return value
