"""Server-side multi-provider AI validation for the trading terminal.
API keys stay on the backend; the APK never receives provider secrets.
"""
from __future__ import annotations
import concurrent.futures
import os
import re
import time
import requests
from openai import OpenAI
from quant.live import build_quant_evidence
import json
import hashlib
import threading

TIMEOUT = int(os.getenv("AI_TIMEOUT_SEC", "15"))
AI_CACHE_SEC = int(os.getenv("AI_CACHE_SEC", "45"))
NSE_SITE_URL = os.getenv("NSE_SITE_URL", "https://www.nseindia.com/option-chain")
_ai_cache = {}
_ai_cache_lock = threading.Lock()

PROVIDERS = [
    {"id":"gpt56-luna","name":"GPT-5.6 Luna","env":"OPENAI_API_KEY","kind":"openai","model":os.getenv("OPENAI_LUNA_MODEL","gpt-5.6-luna")},
    {"id":"claude-sonnet","name":"Claude Sonnet 4.6","env":"ANTHROPIC_API_KEY","kind":"anthropic","model":os.getenv("ANTHROPIC_MODEL","claude-sonnet-4-6")},
    {"id":"gpt56-sol","name":"GPT-5.6 Sol","env":"OPENAI_API_KEY","kind":"openai","model":os.getenv("OPENAI_SOL_MODEL","gpt-5.6-sol")},
    {"id":"deepseek","name":"DeepSeek Chat","env":"DEEPSEEK_API_KEY","kind":"openai_compat","model":os.getenv("DEEPSEEK_MODEL","deepseek-chat"),"base":"https://api.deepseek.com/v1/chat/completions"},
    {"id":"gemini-flash","name":"Gemini 2.5 Flash","env":"GEMINI_API_KEY","kind":"gemini","model":os.getenv("GEMINI_MODEL","gemini-2.5-flash")},
    {"id":"grok-4","name":"Grok 4","env":"XAI_API_KEY","kind":"openai_compat","model":os.getenv("XAI_MODEL","grok-4"),"base":"https://api.x.ai/v1/chat/completions"},
]

ROLE_PROMPTS = {
    "gpt56-luna":"live data collection and candidate extraction",
    "claude-sonnet":"verification, contradiction and evidence audit",
    "gpt56-sol":"independent final validation of the supplied numbers",
    "deepseek":"quantitative/OI/Greeks mathematical cross-check",
    "gemini-flash":"market structure and chart-context cross-check",
    "grok-4":"risk audit, failure conditions and WAIT override",
}

SYSTEM = """You are a market-data validation component inside an Indian index options terminal.
Use ONLY the supplied market payload. Do not invent news, prices, OI, Greeks or trades.
Do not claim hidden institutional orders. Do not promise returns or a win rate.
The engine's final decision remains CALL BUY / PUT BUY / WAIT / NO QUALIFYING TRADE.
Return concise evidence, contradictions, missing-data warnings and a recommendation state."""

def _nse_site_evidence(payload):
    """Read-only official NSE page metadata used as external evidence for AI.
    Numeric market values continue to come from the server-side NSE/Angel adapters;
    this fetch only confirms the current official NSE page and timestamp text.
    """
    symbol="NIFTY"
    if isinstance(payload,dict):
        terminal=payload.get("terminal") or {}
        market=terminal.get("market") if isinstance(terminal,dict) else {}
        symbol=str((market or {}).get("symbol") or payload.get("symbol") or "NIFTY").upper()
    url=NSE_SITE_URL
    try:
        r=requests.get(url,headers={"User-Agent":"Mozilla/5.0","Accept":"text/html,application/xhtml+xml"},timeout=8)
        r.raise_for_status()
        html=r.text
        m=re.search(r"Underlying Index[^<]{0,120}?(NIFTY[^<]{0,80})",html,re.I)
        asof=re.search(r"As on[^<]{0,120}",html,re.I)
        return {"connected":True,"url":url,"symbol":symbol,"http_status":r.status_code,
                "page_timestamp":(asof.group(0).strip() if asof else ""),
                "page_hint":(m.group(1).strip() if m else ""),
                "note":"Official NSE page metadata only; option values come from server-side market adapters."}
    except Exception as e:
        return {"connected":False,"url":url,"symbol":symbol,"error":str(e)[:200],
                "note":"NSE web metadata unavailable; server-side NSE adapter remains the primary source."}

def _prompt(provider, payload):
    role = ROLE_PROMPTS[provider["id"]]
    return (SYSTEM + "\nYour role: " + role + ".\n"
            + "Return exactly these headings: STATE, EVIDENCE, RISKS, MISSING_DATA, OVERRIDE.\n"
            + "STATE must be CALL BUY, PUT BUY, WAIT, or NO QUALIFYING TRADE.\n"
            + "Payload:\n" + _compact(payload))

def _compact(payload):
    import json
    return json.dumps(payload, ensure_ascii=False, separators=(",",":"), default=str)[:30000]

def _openai(p, text):
    if p["id"] == "gpt56-luna":
        client = OpenAI(api_key=os.environ[p["env"]])
        stream = client.responses.create(
            model=p["model"],
            service_tier="default",
            input=[{"role":"system","content":SYSTEM},{"role":"user","content":text}],
            text={"format":{"type":"text"},"verbosity":"medium"},
            reasoning={"effort":"medium","mode":"standard","summary":"auto"},
            tools=[],
            stream=True,
            store=True,
            include=["reasoning.encrypted_content","web_search_call.action.sources"],
            max_output_tokens=700,
        )
        chunks=[]
        for event in stream:
            event_type=getattr(event,"type","")
            if event_type in ("response.output_text.delta","response.refusal.delta"):
                chunks.append(getattr(event,"delta","") or "")
            elif event_type == "error":
                raise RuntimeError(getattr(event,"message","OpenAI streaming error"))
            elif event_type == "response.failed":
                response=getattr(event,"response",None)
                raise RuntimeError(getattr(getattr(response,"error",None),"message",str(response)))
        return "".join(chunks).strip()
    r=requests.post("https://api.openai.com/v1/responses",
        headers={"Authorization":"Bearer "+os.environ[p["env"]],"Content-Type":"application/json"},
        json={"model":p["model"],"input":[{"role":"system","content":SYSTEM},{"role":"user","content":text}],"max_output_tokens":700},
        timeout=TIMEOUT)
    r.raise_for_status(); d=r.json()
    if d.get("output_text"): return d["output_text"]
    out=[]
    for item in d.get("output",[]):
        for c in item.get("content",[]) if isinstance(item,dict) else []:
            if isinstance(c,dict) and c.get("text"): out.append(c["text"])
    return "\n".join(out).strip()

def _openai_compat(p, text):
    r=requests.post(p["base"],
        headers={"Authorization":"Bearer "+os.environ[p["env"]],"Content-Type":"application/json"},
        json={"model":p["model"],"messages":[{"role":"system","content":SYSTEM},{"role":"user","content":text}],"temperature":0.1,"max_tokens":700},
        timeout=TIMEOUT)
    r.raise_for_status(); return (((r.json().get("choices") or [{}])[0].get("message") or {}).get("content") or "").strip()

def _anthropic(p, text):
    r=requests.post("https://api.anthropic.com/v1/messages",
        headers={"x-api-key":os.environ[p["env"]],"anthropic-version":"2023-06-01","content-type":"application/json"},
        json={"model":p["model"],"max_tokens":700,"system":SYSTEM,"messages":[{"role":"user","content":text}]},
        timeout=TIMEOUT)
    r.raise_for_status()
    return "\n".join(x.get("text","") for x in r.json().get("content",[]) if isinstance(x,dict)).strip()

def _gemini(p, text):
    key=os.environ[p["env"]]
    url=f"https://generativelanguage.googleapis.com/v1beta/models/{p['model']}:generateContent?key={key}"
    r=requests.post(url,headers={"Content-Type":"application/json"},
        json={"systemInstruction":{"parts":[{"text":SYSTEM}]},"contents":[{"parts":[{"text":text}]}],"generationConfig":{"temperature":0.1,"maxOutputTokens":700}},
        timeout=TIMEOUT)
    r.raise_for_status(); d=r.json()
    return "\n".join(x.get("text","") for x in (((d.get("candidates") or [{}])[0].get("content") or {}).get("parts") or []) if isinstance(x,dict)).strip()

def _run_one(p, payload):
    base={"id":p["id"],"name":p["name"],"model":p["model"],"role":ROLE_PROMPTS[p["id"]]}
    if not os.getenv(p["env"]):
        return {**base,"status":"not_configured","text":"","error":"Provider API key is not configured on the server.","elapsed_ms":0}
    started=time.monotonic()
    try:
        text=_prompt(p,payload)
        if p["kind"]=="openai": answer=_openai(p,text)
        elif p["kind"]=="anthropic": answer=_anthropic(p,text)
        elif p["kind"]=="gemini": answer=_gemini(p,text)
        else: answer=_openai_compat(p,text)
        return {**base,"status":"ok","text":answer,"elapsed_ms":round((time.monotonic()-started)*1000)}
    except Exception as e:
        return {**base,"status":"error","text":"","error":str(e)[:300],"elapsed_ms":round((time.monotonic()-started)*1000)}

def _state_from_text(text):
    if not text:
        return ""
    m=re.search(r"(?im)^\s*STATE\s*:\s*(CALL BUY|PUT BUY|WAIT|NO QUALIFYING TRADE)\b", text)
    if m:
        return m.group(1).upper()
    first=text.splitlines()[0].strip().upper() if text.splitlines() else ""
    return first if first in {"CALL BUY","PUT BUY","WAIT","NO QUALIFYING TRADE"} else ""

def provider_status():
    return [{"id":p["id"],"name":p["name"],"model":p["model"],"configured":bool(os.getenv(p["env"])),
             "env":p["env"]} for p in PROVIDERS]

def _probe_one(p):
    """Live provider connectivity probe. Never returns or logs the API key."""
    base={"id":p["id"],"name":p["name"],"model":p["model"],"env":p["env"]}
    key=os.getenv(p["env"])
    if not key:
        return {**base,"status":"not_configured","live":False,"error":"API key is not configured on the server."}
    started=time.monotonic()
    probe_text="Reply with exactly: OK"
    try:
        if p["kind"]=="openai":
            r=requests.post("https://api.openai.com/v1/responses",
                headers={"Authorization":"Bearer "+key,"Content-Type":"application/json"},
                json={"model":p["model"],"input":probe_text,"max_output_tokens":8},
                timeout=min(TIMEOUT,10))
            r.raise_for_status()
        elif p["kind"]=="anthropic":
            r=requests.post("https://api.anthropic.com/v1/messages",
                headers={"x-api-key":key,"anthropic-version":"2023-06-01","content-type":"application/json"},
                json={"model":p["model"],"max_tokens":8,"messages":[{"role":"user","content":probe_text}]},
                timeout=min(TIMEOUT,10))
            r.raise_for_status()
        elif p["kind"]=="gemini":
            url=f"https://generativelanguage.googleapis.com/v1beta/models/{p['model']}:generateContent?key={key}"
            r=requests.post(url,headers={"Content-Type":"application/json"},
                json={"contents":[{"parts":[{"text":probe_text}]}],"generationConfig":{"maxOutputTokens":8}},
                timeout=min(TIMEOUT,10))
            r.raise_for_status()
        else:
            r=requests.post(p["base"],
                headers={"Authorization":"Bearer "+key,"Content-Type":"application/json"},
                json={"model":p["model"],"messages":[{"role":"user","content":probe_text}],"temperature":0,"max_tokens":8},
                timeout=min(TIMEOUT,10))
            r.raise_for_status()
        return {**base,"status":"ok","live":True,"error":"","http_status":r.status_code,
                "elapsed_ms":round((time.monotonic()-started)*1000)}
    except Exception as e:
        return {**base,"status":"error","live":False,"error":str(e)[:300],
                "elapsed_ms":round((time.monotonic()-started)*1000)}

def provider_live_status():
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(PROVIDERS)) as ex:
        results=list(ex.map(_probe_one,PROVIDERS))
    return {
        "providers":results,
        "configured":sum(1 for x in results if x["status"] != "not_configured"),
        "live":sum(1 for x in results if x.get("live")),
        "total":len(results),
        "six_ai_live":all(x.get("live") for x in results),
        "checked_at":time.time()
    }

def _local_fallback(payload):
    """Deterministic offline/local validation using ONLY Build-156 payload data.
    This is intentionally not presented as a six-provider consensus result.
    """
    import json
    terminal=payload.get("terminal") if isinstance(payload,dict) else {}
    signal=payload.get("signal") if isinstance(payload,dict) else {}
    if not isinstance(terminal,dict): terminal={}
    if not isinstance(signal,dict): signal={}
    if not signal and isinstance(terminal.get("signals"),dict): signal=terminal.get("signals")
    action=str(signal.get("action") or "WAIT").upper().replace("_"," ").strip()
    if action not in {"CALL BUY","PUT BUY","WAIT","NO QUALIFYING TRADE"}: action="WAIT"
    market_open=bool(terminal.get("market_open"))
    spot=signal.get("spot", signal.get("ltp"))
    ltp=signal.get("ltp")
    strike=signal.get("strike")
    entry=signal.get("entry")
    sl=signal.get("sl")
    target=signal.get("target")
    reasons=[]
    for label,value in (("spot",spot),("LTP",ltp),("strike",strike),("entry",entry),("SL",sl),("target",target)):
        if value not in (None,""): reasons.append(label+"="+str(value))
    oi=terminal.get("oi_lab") if isinstance(terminal.get("oi_lab"),dict) else {}
    chain=terminal.get("option_chain")
    if isinstance(chain,list) and chain: reasons.append("option-chain rows="+str(len(chain)))
    if oi: reasons.append("OI evidence supplied")
    if not reasons: reasons.append("No numeric market evidence was supplied in the Build-156 snapshot.")
    freshness="market open/current snapshot" if market_open else "last available/off-market snapshot"
    text=("LOCAL NSE AI FALLBACK\\nSTATE: "+action+"\\nEVIDENCE: "+"; ".join(reasons)+"\\n"
          +"RISKS: Local fallback is not six-provider cross-verification.\\n"
          +"MISSING_DATA: Only fields present in the supplied snapshot are used.\\n"
          +"OVERRIDE: No external AI consensus; use WAIT when the engine payload is insufficient.\\n"
          +"SOURCE: Build-156 terminal payload ("+freshness+").")
    return {"id":"local-nse-ai","name":"NSE Local AI Fallback","model":"build-156-local","role":"offline evidence summarization","status":"ok_local","text":text,"final":action,"cross_verified":False,"error":"","elapsed_ms":0}

def validate_all(payload):
    payload=dict(payload or {})
    payload["quant_evidence"] = build_quant_evidence(payload)
    payload["nse_official_site"]=_nse_site_evidence(payload)
    payload.setdefault("ai_sources",{})["nse_official_site"]=NSE_SITE_URL
    raw=json.dumps(payload,ensure_ascii=False,sort_keys=True,separators=(",",":"),default=str)
    cache_key=hashlib.sha256(raw.encode("utf-8")).hexdigest()
    now=time.monotonic()
    with _ai_cache_lock:
        cached=_ai_cache.get(cache_key)
        if cached and now-cached["ts"] < AI_CACHE_SEC:
            return {**cached["result"],"cached":True,"cache_age_sec":round(now-cached["ts"],1)}
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(PROVIDERS)) as ex:
        results=list(ex.map(lambda p:_run_one(p,payload),PROVIDERS))
    ok=[r for r in results if r["status"]=="ok"]
    states=[_state_from_text(r.get("text","")) for r in ok]
    states=[s for s in states if s]
    configured=sum(1 for p in PROVIDERS if os.getenv(p["env"]))
    local=_local_fallback(payload)
    final=local["final"]
    cross_verified=False
    reason="Local NSE AI fallback is active using the supplied Build-156 market snapshot."
    if not configured:
        reason="Six-provider keys are not configured; local NSE AI fallback is analyzing the supplied Build-156 snapshot."
    elif not ok:
        reason="Configured AI providers returned no successful response; local NSE AI fallback analyzed the supplied Build-156 snapshot."
    elif len(states) < 2:
        final=states[0] if len(states)==1 else local["final"]
        reason="Only one or fewer provider states were available; local NSE AI fallback remains active. Six-provider consensus is not verified."
    elif len(set(states)) == 1 and states[0] in {"CALL BUY","PUT BUY"}:
        final=states[0]
        cross_verified=True
        reason="All " + str(len(states)) + " successful AI responses agree."
    elif len(set(states)) == 1 and states[0] == "NO QUALIFYING TRADE":
        final="NO QUALIFYING TRADE"
        cross_verified=True
        reason="All " + str(len(states)) + " successful AI responses found no qualifying trade."
    else:
        final="WAIT"
        reason="AI responses are not fully aligned; conflicting or WAIT evidence forces WAIT."
    result={
        "final":final,
        "providers":results,
        "configured":configured,
        "successful":len(ok),
        "parsed_states":len(states),
        "total":len(results),
        "cross_verified":cross_verified,
        "reason":reason,
        "local_fallback":local,
        "quant_evidence":payload.get("quant_evidence",{}),
        "mode":"six_provider_consensus" if cross_verified else "local_nse_fallback",
        "sources":{"ai_api":"server-side provider API keys","nse_official_site":payload.get("nse_official_site"),"nse_mcp":"https://mcp.nseindia.in/cmmkt/mcp"},
        "cached":False,
    }
    with _ai_cache_lock:
        _ai_cache[cache_key]={"ts":time.monotonic(),"result":result}
    return result
