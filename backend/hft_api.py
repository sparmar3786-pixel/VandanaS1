"""FastAPI endpoints for the paper-only HFT research engine."""
from fastapi import APIRouter, Header
from pydantic import BaseModel
from hft.engine import HFTSignalEngine
from hft.orderbook import Quote

router=APIRouter(prefix="/v1/hft", tags=["hft"])
engine=HFTSignalEngine()

class QuoteRequest(BaseModel):
    bid: float
    ask: float
    bid_size: float = 0.0
    ask_size: float = 0.0
    ts: float = 0.0

@router.get("/status")
def status():
    return {"enabled":True,"paper_only":True,"orders_enabled":False,"last":engine.last}

@router.post("/quote")
def quote(body: QuoteRequest):
    return engine.on_quote(Quote(body.bid,body.ask,body.bid_size,body.ask_size,body.ts))
