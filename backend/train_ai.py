"""Train on logged NSE features:  python train_ai.py   (run after a few days of market-hours logging)"""
import pandas as pd, joblib
from sklearn.ensemble import GradientBoostingClassifier
from sklearn.model_selection import TimeSeriesSplit, cross_val_score
from nse_features import FEATURES

FWD = 10
df = pd.read_csv("data/nse_features.csv")
df["day"] = pd.to_datetime(df["ts"], unit="s").dt.date
df["fwd"] = df.groupby("day")["spot"].transform(lambda s: s.shift(-FWD) / s - 1)
df = df.dropna()
X, y = df[FEATURES].values, (df["fwd"] > 0.0003).astype(int).values
print("rows:", len(df), "| up-rate:", y.mean().round(3))
if len(df) < 1500: print("WARNING: data kam hai (<1500 rows). Aur din collect karein.")
m = GradientBoostingClassifier(n_estimators=150, max_depth=3, learning_rate=0.05, subsample=0.8)
print("TimeSeries CV accuracy:", cross_val_score(m, X, y, cv=TimeSeriesSplit(5)).mean().round(3), "(0.5 = coin flip)")
m.fit(X, y); joblib.dump(m, "data/model.joblib"); print("Saved data/model.joblib")
