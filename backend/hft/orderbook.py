"""In-memory L1/L2 book primitives. No broker calls and no order placement."""
from dataclasses import dataclass
from typing import Optional

@dataclass(frozen=True)
class Quote:
    bid: float
    ask: float
    bid_size: float = 0.0
    ask_size: float = 0.0
    ts: float = 0.0

    @property
    def spread(self) -> float:
        return max(0.0, self.ask - self.bid)

    @property
    def mid(self) -> Optional[float]:
        if self.bid <= 0 or self.ask <= 0 or self.ask < self.bid:
            return None
        return (self.bid + self.ask) / 2.0

    @property
    def microprice(self) -> Optional[float]:
        if self.bid <= 0 or self.ask <= 0 or self.ask < self.bid:
            return None
        total = self.bid_size + self.ask_size
        if total <= 0:
            return self.mid
        return (self.ask * self.bid_size + self.bid * self.ask_size) / total

def imbalance(bid_size: float, ask_size: float) -> float:
    total = float(bid_size) + float(ask_size)
    if total <= 0:
        return 0.0
    return (float(bid_size) - float(ask_size)) / total
