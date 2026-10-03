from datetime import datetime, timezone

from backend.strategy_377 import STRATEGY_377, evaluate_live
from backend.strategy_engine import _clock, validate_strategy


def test_strategy_377_schema():
    validated = validate_strategy(STRATEGY_377)
    assert validated["id"] == "strategy_377"
    assert validated["name"] == "Strategy 377"
    assert validated["version"] == "377.1"


def test_strategy_engine_accepts_epoch_time():
    stamp = datetime(2026, 10, 3, 10, 0, tzinfo=timezone.utc).timestamp()
    assert _clock(stamp) == "15:30"


def test_strategy_377_returns_evidence():
    payload = {
        "timestamp": datetime(2026, 10, 3, 10, 0, tzinfo=timezone.utc).timestamp(),
        "current_engine_state": {"index_ltp": 25000},
        "trend": "UP",
        "spot": 25000,
        "support": 24900,
        "resistance": 25300,
        "pcr": 1.15,
        "highest_ce_oi": [{"volume": 1000}],
        "highest_pe_oi": [{"volume": 1000}],
        "what_is_changing": [
            {"classification": "LONG_BUILDUP"},
        ],
    }
    result = evaluate_live(payload)
    assert result["strategy"]["name"] == "Strategy 377"
    assert "evaluation" in result
    assert result["paper_only"] is True
