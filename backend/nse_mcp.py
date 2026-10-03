"""Small Streamable-HTTP MCP client for the official NSE MCP endpoint."""
import csv
import io
import json
import requests

NSE_MCP_URL = "https://mcp.nseindia.in/cmmkt/mcp"

class NSEMCP:
    def __init__(self, url=NSE_MCP_URL):
        self.url = url
        self.timeout = 12
        self.protocol_versions = ['2025-06-18', '2025-03-26', '2024-11-05']

    def _post(self, payload, session_id=None, protocol_version=None):
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "User-Agent": "NSE-Algo-Signal/1.0",
            "Origin": "https://www.nseindia.com",
            "Referer": "https://www.nseindia.com/",
        }
        if session_id:
            headers["Mcp-Session-Id"] = session_id
        if protocol_version:
            headers["MCP-Protocol-Version"] = protocol_version
        r = requests.post(self.url, json=payload, headers=headers, timeout=self.timeout)
        r.raise_for_status()
        sid = r.headers.get("mcp-session-id") or session_id
        text = r.text.strip()
        # Streamable HTTP may return SSE frames with event:/data: prefixes.
        for line in text.splitlines():
            line = line.strip()
            if line.startswith("data:"):
                raw = line[5:].strip()
                if raw:
                    try:
                        return json.loads(raw), sid
                    except Exception:
                        continue
        if text:
            try:
                return r.json(), sid
            except Exception:
                return {"raw": text[:12000]}, sid
        return {}, sid

    def _session(self):
        last=None
        for version in self.protocol_versions:
            try:
                init, sid = self._post({
                    "jsonrpc":"2.0","id":1,"method":"initialize",
                    "params":{
                        "protocolVersion":version,
                        "capabilities":{},
                        "clientInfo":{"name":"NSE Algo Signal","version":"1.0"}
                    }
                }, protocol_version=version)
                negotiated=((init.get("result") or {}).get("protocolVersion") or version)
                self._post({"jsonrpc":"2.0","method":"notifications/initialized","params":{}}, sid, negotiated)
                return sid, negotiated
            except Exception as e:
                last=e
        raise RuntimeError("NSE MCP initialize failed: " + str(last))

    def tools(self):
        sid, version = self._session()
        result, _ = self._post({"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}, sid, version)
        tools=result.get("result", {}).get("tools", [])
        if not tools:
            raise RuntimeError("NSE MCP connected but returned no tools.")
        return tools

    def call_tool(self, tool_name, arguments=None):
        sid, version = self._session()
        result, _ = self._post({
            "jsonrpc":"2.0","id":int(__import__("time").time()*1000) % 1000000000,
            "method":"tools/call",
            "params":{"name":tool_name,"arguments":arguments or {}}
        }, sid, version)
        return result

    def _tool_arguments(self, tool, symbol):
        props = (tool.get("inputSchema") or {}).get("properties", {})
        required = (tool.get("inputSchema") or {}).get("required", []) or []
        args = {}
        for name in props:
            key = str(name).lower()
            if key in {"symbol","index","indexsymbol","symbolname","underlying","underlyingsymbol","name"}:
                args[name] = symbol
            elif key in {"exchange","exchange_code"}:
                args[name] = "NSE"
            elif key in {"segment","segment_code"}:
                args[name] = "CM"
        if any(req not in args and req in required for req in required):
            return None
        return args

    def context(self, symbol="NIFTY"):
        tools = self.tools()
        data = []
        errors = []
        keywords = ("live", "index", "quote", "price", "breadth", "gainer", "loser", "fresh")
        candidates = [t for t in tools if any(k in str(t.get("name","")).lower() for k in keywords)]
        for tool in candidates[:4]:
            args = self._tool_arguments(tool, symbol.upper())
            if args is None:
                continue
            try:
                result = self.call_tool(tool.get("name"), args)
                data.append({"tool":tool.get("name"),"arguments":args,"result":result})
            except Exception as e:
                errors.append({"tool":tool.get("name"),"error":str(e)[:300]})
        return {
            "connected": True,
            "endpoint": self.url,
            "tool_count": len(tools),
            "tools": [{"name":t.get("name"),"description":t.get("description")} for t in tools],
            "data": data,
            "tool_errors": errors,
            "option_chain_tool_available": any("option" in str(t.get("name","")).lower() and "chain" in str(t.get("name","")).lower() for t in tools),
        }
    def option_chain(self, symbol="NIFTY", expiry=None):
        tools = self.tools()
        candidates = [t for t in tools if "option" in t.get("name","").lower() and "chain" in t.get("name","").lower()]
        if not candidates:
            raise RuntimeError("Official NSE CM-MCP does not expose an option-chain tool in its current tool list.")
        tool = candidates[0]
        props = tool.get("inputSchema", {}).get("properties", {})
        args = {}
        if "symbol" in props: args["symbol"] = symbol
        elif "index" in props: args["index"] = symbol
        if expiry and "expiry" in props: args["expiry"] = expiry
        sid, version = self._session()
        result, _ = self._post({
            "jsonrpc":"2.0","id":4,"method":"tools/call",
            "params":{"name":tool["name"],"arguments":args}
        }, sid, version)
        return tool["name"], result

def flatten(obj, prefix=""):
    rows=[]
    if isinstance(obj, dict):
        for k,v in obj.items():
            rows.extend(flatten(v, f"{prefix}.{k}" if prefix else k))
    elif isinstance(obj, list):
        for i,v in enumerate(obj):
            rows.extend(flatten(v, f"{prefix}[{i}]"))
    else:
        rows.append((prefix, obj))
    return rows

def result_to_csv(result):
    content = result.get("result", result) if isinstance(result, dict) else result
    if isinstance(content, dict) and "content" in content:
        blocks=content["content"]
        for b in blocks:
            if isinstance(b,dict) and b.get("type")=="text":
                try: content=json.loads(b.get("text",""))
                except Exception: content=b.get("text","")
                break
    if isinstance(content, list) and all(isinstance(x,dict) for x in content):
        keys=sorted({k for x in content for k in x.keys()})
        out=io.StringIO(); w=csv.DictWriter(out,fieldnames=keys); w.writeheader(); w.writerows(content)
        return out.getvalue()
    if isinstance(content, dict):
        for key in ("records","data","rows","optionChain","option_chain"):
            val=content.get(key)
            if isinstance(val,list) and all(isinstance(x,dict) for x in val):
                keys=sorted({k for x in val for k in x.keys()})
                out=io.StringIO(); w=csv.DictWriter(out,fieldnames=keys); w.writeheader(); w.writerows(val)
                return out.getvalue()
    out=io.StringIO(); w=csv.writer(out); w.writerow(["field","value"]); w.writerows(flatten(content))
    return out.getvalue()
