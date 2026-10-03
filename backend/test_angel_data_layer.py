import unittest
from datetime import datetime

import numpy as np
import pandas as pd

from angel_data_layer import Normalizer, validate, FeatureStore, model_input


class FakeAngel:
    def candles(self, exchange, token, interval, days):
        rows = []
        # Keep the fixture inside NSE cash-market hours across two sessions.
        # 120 bars leaves enough fully-warmed indicator rows for a 60-bar AI window.
        base = pd.Timestamp("2026-09-28 09:15", tz="Asia/Kolkata")
        price = 25000.0
        for i in range(120):
            t = base + pd.Timedelta(days=i // 75, minutes=5 * (i % 75))
            close = price + (i % 7 - 3) * 2.0
            rows.append([t.isoformat(), str(price), str(max(price, close) + 1), str(min(price, close) - 1), str(close), "100"])
            price = close
        return {"data": rows}


class AngelDataLayerTests(unittest.TestCase):
    def test_normalizer_deduplicates_repairs_and_marks_closed(self):
        rows = [
            ["2026-09-28 09:15", "100", "98", "102", "101", "10"],
            ["2026-09-28 09:15", "100", "103", "99", "102", "11"],
        ]
        df = Normalizer.clean(rows, "FIVE_MINUTE", now=pd.Timestamp("2026-09-28 10:00", tz="Asia/Kolkata"))
        self.assertEqual(len(df), 1)
        self.assertEqual(float(df.iloc[0]["high"]), 103.0)
        self.assertEqual(float(df.iloc[0]["low"]), 99.0)
        self.assertTrue(bool(df.iloc[0]["closed"]))

    def test_validation_is_safe_for_empty_data(self):
        df = Normalizer.clean([], "FIVE_MINUTE")
        result = validate(df)
        self.assertFalse(result["ok"])
        self.assertEqual(result["bars"], 0)

    def test_model_input_has_fixed_shape_when_warm(self):
        rows = FakeAngel().candles("NSE", "99926000", "FIVE_MINUTE", 5)["data"]
        df = Normalizer.clean(rows, "FIVE_MINUTE", now=pd.Timestamp("2026-10-01", tz="Asia/Kolkata"))
        fs = FeatureStore(df[df["closed"]])
        x = model_input(fs, win=60)
        self.assertIsNotNone(x)
        self.assertEqual(tuple(x.shape), (1, 60, 6))
        self.assertTrue(np.isfinite(x).all())


if __name__ == "__main__":
    unittest.main()
