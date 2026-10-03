import unittest
from trade_verifier import _FakeOI, Verifier, negotiate

class TradeVerifierRegressionTest(unittest.TestCase):
    def test_invalid_strike_is_rejected(self):
        oi = _FakeOI()
        ver = Verifier(oi, None, lambda i: 1)
        plan = {"index": "BANKNIFTY", "side": "CE", "strike": 24700, "entry": 102.3, "sl": 94.5, "t1": 112.4}
        verdict = ver.verify(plan)
        self.assertEqual(verdict.status, "REJECT")
        self.assertTrue(any(c.name == "strike_exists" and c.ok is False for c in verdict.checks))

    def test_ai_feedback_can_correct_plan(self):
        class Planner:
            def propose(self, summary, feedback):
                if not feedback:
                    return {"index": summary["index"], "side": "CE", "strike": 24700, "entry": 102.3, "sl": 94.5, "t1": 112.4}
                return {**feedback["suggested"], "index": summary["index"]}
        out = negotiate(Planner(), Verifier(_FakeOI(), None, lambda i: 1), "NIFTY")
        self.assertTrue(out["signal"])
        self.assertEqual(out["history"][0]["status"], "REJECT")
        self.assertEqual(out["history"][-1]["status"], "CONFIRMED")

if __name__ == "__main__":
    unittest.main()
