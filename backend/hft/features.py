"""Deterministic microstructure features used by the HFT research model."""
from collections import deque
from dataclasses import dataclass
from math import log
from typing import Optional
from .orderbook import Quote, imbalance

@dataclass(frozen=True)
class Features:
    mid: float
    microprice: float
    spread: float
    imbalance: float
    momentum: float
    volatility: float
    spread_bps: float

class FeatureEngine:
    def __init__(self, max_prices: int = 256):
        self.prices = deque(maxlen=max_prices)

    def update(self, q: Quote) -> Optional[Features]:
        mid = q.mid
        micro = q.microprice
        if mid is None or micro is None:
            return None
        self.prices.append(mid)
        if len(self.prices) < 3:
            return None
        p=list(self.prices)
        returns=[log(p[i]/p[i-1]) for i in range(1,len(p)) if p[i-1] > 0]
        momentum=(p[-1]/p[-3])-1.0 if p[-3] > 0 else 0.0
        vol=(sum((x-sum(returns)/len(returns))**2 for x in returns)/len(returns))**0.5 if returns else 0.0
        return Features(mid,micro,q.spread,imbalance(q.bid_size,q.ask_size),momentum,vol,(q.spread/mid)*10000 if mid else 0.0)
