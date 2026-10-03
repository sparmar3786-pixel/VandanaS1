"""Deterministic quantitative primitives for indicators, Greeks, IV and statistics.

All functions are side-effect free and degrade gracefully on short/invalid input.
They never call AI, trade, place orders, or invent missing market values.
"""
from __future__ import annotations
import math
from typing import Iterable, Optional, Sequence
import numpy as np
import pandas as pd
from scipy.stats import norm

try:
    from scipy.optimize import brentq
except Exception:  # pragma: no cover
    brentq = None

def norm_cdf(x: float) -> float: return float(norm.cdf(x))
def norm_pdf(x: float) -> float: return float(norm.pdf(x))

def bs_price(S: float, K: float, T: float, r: float, sigma: float, option_type: str = "CE") -> float:
    if S <= 0 or K <= 0:
        return float("nan")
    if T <= 0 or sigma <= 0:
        return float(max(S - K, 0.0) if option_type.upper() == "CE" else max(K - S, 0.0))
    d1=(math.log(S/K)+(r+0.5*sigma*sigma)*T)/(sigma*math.sqrt(T))
    d2=d1-sigma*math.sqrt(T)
    if option_type.upper()=="CE":
        return float(S*norm.cdf(d1)-K*math.exp(-r*T)*norm.cdf(d2))
    return float(K*math.exp(-r*T)*norm.cdf(-d2)-S*norm.cdf(-d1))

def bs_greeks(S: float,K: float,T: float,r: float,sigma: float,option_type: str="CE",q: float=0.0)->dict[str,float]:
    out={"delta":0.0,"gamma":0.0,"theta":0.0,"vega":0.0,"rho":0.0}
    if S<=0 or K<=0 or sigma<=0 or T<=0:
        if S>0 and K>0:
            out["delta"] = (1.0 if S>K else 0.0) if option_type.upper()=="CE" else (-1.0 if S<K else 0.0)
        return out
    sqrtT=math.sqrt(T)
    d1=(math.log(S/K)+(r-q+0.5*sigma*sigma)*T)/(sigma*sqrtT)
    d2=d1-sigma*sqrtT
    pdf=norm.pdf(d1); disc=math.exp(-r*T); disc_q=math.exp(-q*T)
    out["gamma"]=float(disc_q*pdf/(S*sigma*sqrtT))
    out["vega"]=float(S*disc_q*pdf*sqrtT/100.0)
    if option_type.upper()=="CE":
        out["delta"]=float(disc_q*norm.cdf(d1))
        out["theta"]=float((-(S*disc_q*pdf*sigma)/(2*sqrtT)-r*K*disc*norm.cdf(d2)+q*S*disc_q*norm.cdf(d1))/365.0)
        out["rho"]=float(K*T*disc*norm.cdf(d2)/100.0)
    else:
        out["delta"]=float(-disc_q*norm.cdf(-d1))
        out["theta"]=float((-(S*disc_q*pdf*sigma)/(2*sqrtT)+r*K*disc*norm.cdf(-d2)-q*S*disc_q*norm.cdf(-d1))/365.0)
        out["rho"]=float(-K*T*disc*norm.cdf(-d2)/100.0)
    return out

def implied_vol(price:float,S:float,K:float,T:float,r:float,option_type:str="CE",lo:float=1e-4,hi:float=5.0)->Optional[float]:
    if brentq is None or price<=0 or S<=0 or K<=0 or T<=0: return None
    f=lambda sig: bs_price(S,K,T,r,sig,option_type)-price
    try:
        flo,fhi=f(lo),f(hi)
        if not math.isfinite(flo) or not math.isfinite(fhi) or flo*fhi>0: return None
        return float(brentq(f,lo,hi,maxiter=100))
    except Exception: return None

def probability_of_profit(S:float,K:float,T:float,r:float,sigma:float,option_type:str="CE")->float:
    if S<=0 or K<=0 or T<=0 or sigma<=0: return 0.0
    d2=(math.log(S/K)+(r-0.5*sigma*sigma)*T)/(sigma*math.sqrt(T))
    return float(norm.cdf(d2) if option_type.upper()=="CE" else norm.cdf(-d2))

def _series(x:Iterable[float])->pd.Series: return pd.Series(list(x),dtype="float64")

def ema(values:Sequence[float],span:int)->Optional[float]:
    s=_series(values).dropna()
    return float(s.ewm(span=span,adjust=False).mean().iloc[-1]) if len(s)>=2 else None

def sma(values:Sequence[float],window:int)->Optional[float]:
    s=_series(values).dropna()
    return float(s.rolling(window).mean().iloc[-1]) if len(s)>=window else None

def vwap(prices:Sequence[float],volumes:Sequence[float])->Optional[float]:
    p=_series(prices); v=_series(volumes).fillna(0.0)
    return None if len(p)==0 or v.sum()<=0 else float((p*v).sum()/v.sum())

def rsi(values:Sequence[float],period:int=14)->Optional[float]:
    s=_series(values).dropna()
    if len(s)<=period:return None
    d=s.diff(); gain=d.clip(lower=0.0); loss=-d.clip(upper=0.0)
    ag=gain.ewm(alpha=1/period,adjust=False).mean().iloc[-1]
    al=loss.ewm(alpha=1/period,adjust=False).mean().iloc[-1]
    return 100.0 if al==0 else float(100.0-100.0/(1.0+ag/al))

def macd(values:Sequence[float],fast:int=12,slow:int=26,signal:int=9)->Optional[dict[str,float]]:
    s=_series(values).dropna()
    if len(s)<slow+signal:return None
    ef=s.ewm(span=fast,adjust=False).mean(); es=s.ewm(span=slow,adjust=False).mean()
    ml=ef-es; sl=ml.ewm(span=signal,adjust=False).mean(); h=ml-sl
    return {"macd":float(ml.iloc[-1]),"signal":float(sl.iloc[-1]),"hist":float(h.iloc[-1]),"prev_hist":float(h.iloc[-2])}

def true_range(high:Sequence[float],low:Sequence[float],close:Sequence[float])->pd.Series:
    h,l,c=_series(high),_series(low),_series(close); pc=c.shift(1)
    return pd.concat([(h-l),(h-pc).abs(),(l-pc).abs()],axis=1).max(axis=1)

def atr(high:Sequence[float],low:Sequence[float],close:Sequence[float],period:int=14)->Optional[float]:
    tr=true_range(high,low,close).dropna()
    return float(tr.ewm(alpha=1/period,adjust=False).mean().iloc[-1]) if len(tr)>=period else None

def bollinger(values:Sequence[float],period:int=20,k:float=2.0)->Optional[dict[str,float]]:
    s=_series(values).dropna()
    if len(s)<period:return None
    mid=float(s.rolling(period).mean().iloc[-1]); sd=float(s.rolling(period).std(ddof=0).iloc[-1])
    upper,lower=mid+k*sd,mid-k*sd; width=(upper-lower)/mid if mid else 0.0
    return {"mid":mid,"upper":float(upper),"lower":float(lower),"width":float(width),"bandwidth_pct":float(width*100)}

def zscore(value:float,values:Sequence[float])->Optional[float]:
    s=_series(values).dropna()
    if len(s)<2:return None
    mu,sd=float(s.mean()),float(s.std(ddof=0))
    return 0.0 if sd==0 else float((value-mu)/sd)

def rolling_zscore(values:Sequence[float],window:int=20)->Optional[float]:
    s=_series(values).dropna()
    if len(s)<window+1:return None
    mu=float(s.rolling(window).mean().iloc[-1]); sd=float(s.rolling(window).std(ddof=0).iloc[-1])
    return 0.0 if sd==0 or math.isnan(sd) else float((s.iloc[-1]-mu)/sd)

def percentile_rank(value:float,values:Sequence[float])->Optional[float]:
    s=_series(values).dropna()
    return None if len(s)<3 else float((s<=value).mean()*100.0)

def rolling_correlation(a:Sequence[float],b:Sequence[float],window:int=20)->Optional[float]:
    sa,sb=_series(a),_series(b); n=min(len(sa),len(sb))
    if n<window+1:return None
    corr=sa.iloc[-n:].rolling(window).corr(sb.iloc[-n:]).iloc[-1]
    return None if corr is None or math.isnan(corr) else float(corr)

def beta(asset_returns:Sequence[float],bench_returns:Sequence[float])->Optional[float]:
    a,b=_series(asset_returns).dropna(),_series(bench_returns).dropna(); n=min(len(a),len(b))
    if n<3:return None
    a,b=a.iloc[-n:].to_numpy(),b.iloc[-n:].to_numpy(); var=float(np.var(b))
    return None if var==0 else float(np.cov(a,b)[0,1]/var)

def realized_vol(returns:Sequence[float],window:int=20)->Optional[float]:
    r=_series(returns).dropna()
    return None if len(r)<window else float(r.iloc[-window:].std(ddof=0)*math.sqrt(252))

def returns_from_prices(prices:Sequence[float])->np.ndarray:
    s=_series(prices).dropna(); return s.pct_change().dropna().to_numpy()

def safe_pct_change(new:Optional[float],old:Optional[float])->Optional[float]:
    return None if new is None or old is None or old==0 else float((new-old)/abs(old)*100.0)

def clamp(value:float,lo:float=0.0,hi:float=1.0)->float: return float(max(lo,min(hi,value)))
def logistic(x:float,k:float=1.0)->float:
    try:return float(1.0/(1.0+math.exp(-k*x)))
    except OverflowError:return 0.0 if x<0 else 1.0
