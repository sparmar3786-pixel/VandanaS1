import unittest
from quant.option_math import bs_greeks, bs_price, implied_vol, rsi, macd, bollinger

class QuantPrimitiveTests(unittest.TestCase):
    def test_call_put_price_positive(self):
        self.assertGreater(bs_price(100,100,30/365,0.05,0.2,"CE"),0)
        self.assertGreater(bs_price(100,100,30/365,0.05,0.2,"PE"),0)

    def test_greeks_shape(self):
        g=bs_greeks(100,100,30/365,0.05,0.2,"CE")
        for k in ("delta","gamma","theta","vega","rho"):
            self.assertIn(k,g)

    def test_iv_round_trip(self):
        p=bs_price(100,105,30/365,0.05,0.25,"CE")
        iv=implied_vol(p,100,105,30/365,0.05,"CE")
        self.assertIsNotNone(iv)
        self.assertAlmostEqual(iv,0.25,places=3)

    def test_indicators_degrade_gracefully(self):
        xs=list(range(1,40))
        self.assertIsNotNone(rsi(xs,14))
        self.assertIsNotNone(macd(xs))
        self.assertIsNotNone(bollinger(xs,20))

if __name__=="__main__":
    unittest.main()
