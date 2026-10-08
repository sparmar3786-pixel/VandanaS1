"""Small deterministic baseline scorer. Replace with a trained model only after walk-forward validation."""
from dataclasses import dataclass
from .features import Features

@dataclass(frozen=True)
class Prediction:
    p_up: float
    p_down: float
    confidence: float
    reason: str

def score(f: Features, min_confidence: float = 0.60) -> Prediction:
    raw = 3.0*f.imbalance + 12.0*f.momentum - 2.0*f.volatility
    p_up = 1.0/(1.0 + pow(2.718281828,-raw))
    p_down = 1.0-p_up
    conf=max(p_up,p_down)
    direction="UP" if p_up >= p_down else "DOWN"
    reason=f"imbalance={f.imbalance:.3f}, momentum={f.momentum:.5f}, spread_bps={f.spread_bps:.2f}"
    return Prediction(p_up,p_down,conf,reason)
