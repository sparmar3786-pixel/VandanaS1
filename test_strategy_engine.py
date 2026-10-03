import sys
sys.path.insert(0,"backend")
import unittest
from strategy_engine import validate_strategy,evaluate_strategy,run_backtest,approve_test

S={
 "id":"nifty_sweep_v1","index":"NIFTY","tf":"5m",
 "entry_call":["sweep_low","long_buildup","price>vwap","pcr>1"],
 "entry_put":["sweep_high","short_buildup","price<vwap","pcr<1"],
 "block_if":["short_covering"],"sl":"swing_low","target":"2R",
 "time_filter":"09:30-14:45","version":"v1"
}

class StrategyEngineTests(unittest.TestCase):
 def test_allowlisted_strategy(self):
  self.assertEqual(validate_strategy(S)["id"],"nifty_sweep_v1")

 def test_block_wins(self):
  state={"timestamp":"2026-10-01T10:00:00","data_fresh":True,"short_covering":True,
         "sweep_low":True,"long_buildup":True,"price":100,"vwap":99,"pcr":1.2}
  self.assertEqual(evaluate_strategy(S,state)["decision"],"WAIT")

 def test_call_requires_all_call_blocks(self):
  state={"timestamp":"2026-10-01T10:00:00","data_fresh":True,"short_covering":False,
         "sweep_low":True,"long_buildup":True,"price":100,"vwap":99,"pcr":1.2}
  self.assertEqual(evaluate_strategy(S,state)["decision"],"CALL BUY")

 def test_backtest_next_open(self):
  bars=[]
  for i in range(105):
   bars.append({"timestamp":f"2026-10-01T10:{i%60:02d}:00","open":100+i%2,
                "high":102+i%2,"low":98,"close":101,
                "data_fresh":True,"sweep_low":True,"long_buildup":True,
                "price":100,"vwap":99,"pcr":1.2,"short_covering":False,"swing_low":98})
  result=run_backtest(S,bars)
  self.assertIsInstance(result.metrics["trades"],int)

 def test_approval_needs_100_and_pf(self):
  self.assertFalse(approve_test({"trades":99,"profit_factor":2})["approved"])
  self.assertFalse(approve_test({"trades":100,"profit_factor":1.5})["approved"])

if __name__=="__main__":
 unittest.main()
