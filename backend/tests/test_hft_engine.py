from backend.hft.engine import HFTSignalEngine
from backend.hft.orderbook import Quote, imbalance

def test_imbalance_is_bounded_and_directional():
    assert imbalance(80,20) == 0.6
    assert imbalance(20,80) == -0.6

def test_engine_warms_up_before_emitting_signal():
    e=HFTSignalEngine()
    assert e.on_quote(Quote(100,100.1,80,20))["state"] == "WARMUP"
    assert e.on_quote(Quote(100,100.1,80,20))["state"] == "WARMUP"
    result=e.on_quote(Quote(100.1,100.2,80,20))
    assert result["paper_only"] is True
    assert result["state"] in {"BUY","WAIT","SELL"}

def test_wide_spread_forces_wait():
    e=HFTSignalEngine(max_spread_bps=1)
    for price in (100,100.1,100.2):
        result=e.on_quote(Quote(price,price+1,100,10))
    assert result["state"] == "WAIT"
