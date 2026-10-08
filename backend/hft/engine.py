"""Paper-only HFT-style signal engine.

It consumes normalized quotes and emits research signals. It intentionally has
no order-placement capability; execution must remain behind a separately
reviewed broker/risk adapter.
"""
from dataclasses import asdict
from typing import Optional
from .orderbook import Quote
from .features import FeatureEngine
from .model import score

class HFTSignalEngine:
    def __init__(self, max_spread_bps: float = 8.0, min_confidence: float = 0.60):
        self.features=FeatureEngine()
        self.max_spread_bps=max_spread_bps
        self.min_confidence=min_confidence
        self.last={"state":"WARMUP"}

    def on_quote(self, q: Quote) -> dict:
        f=self.features.update(q)
        if f is None:
            self.last={"state":"WARMUP","reason":"Need at least 3 valid mid-price observations."}
            return self.last
        pred=score(f,self.min_confidence)
        state="WAIT"
        if f.spread_bps <= self.max_spread_bps and pred.confidence >= self.min_confidence:
            state="BUY" if pred.p_up > pred.p_down else "SELL"
        self.last={"state":state,"paper_only":True,"prediction":asdict(pred),"features":asdict(f)}
        return self.last
