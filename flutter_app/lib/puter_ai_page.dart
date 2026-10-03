import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:webview_flutter/webview_flutter.dart';

class PuterAiPage extends StatefulWidget {
  final String backendUrl;
  final String apiToken;
  final Map<String, dynamic>? initialSnapshot;
  final String symbol;
  const PuterAiPage({super.key, required this.backendUrl, required this.apiToken, this.initialSnapshot, this.symbol = "NIFTY"});
  @override State<PuterAiPage> createState() => _PuterAiPageState();
}

class _PuterAiPageState extends State<PuterAiPage> {
  late final WebViewController controller;
  Timer? autoTimer;
  bool ready=false, running=false, auto=true;
  Map<String,dynamic> snapshot={};
  String status='Starting live AI bridge...';
  String get symbol => widget.symbol.toUpperCase();
  @override void initState(){
    super.initState();
    snapshot=widget.initialSnapshot ?? <String,dynamic>{};
    controller=WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFF8F5FA))
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) { if(mounted) setState(()=>status='Loading Puter.js...'); },
        onPageFinished: (_) async {
          ready=true;
          if(mounted) setState(()=>status='Live AI bridge ready');
          await _pushSnapshot(snapshot);
          autoTimer?.cancel();
          autoTimer=Timer.periodic(const Duration(seconds:60),(_)=>runValidation());
        },
        onWebResourceError:(e){if(mounted)setState(()=>status='Puter network error: '+e.description);},
      ))
      ..loadHtmlString(_html());
  }
  @override void dispose(){autoTimer?.cancel();super.dispose();}
  Future<void> _pushSnapshot(Map<String,dynamic>? value) async {
    if(!ready || value==null) return;
    final b64=base64Encode(utf8.encode(jsonEncode(value)));
    try{await controller.runJavaScript("window.setSnapshot('"+b64+"');");}catch(_){ }
  }
  Future<void> refreshContext() async {
    try{
      final base=widget.backendUrl.replaceFirst(RegExp(r'/+$'),'');
      final r=await http.get(Uri.parse(base+'/v1/ai/context?index='+Uri.encodeQueryComponent(symbol)),headers:<String,String>{'x-token':widget.apiToken}).timeout(const Duration(seconds:18));
      if(r.statusCode==200){
        final d=jsonDecode(r.body);
        if(d is Map<String,dynamic>){snapshot=d;await _pushSnapshot(d);}
      }
    }catch(_){ }
  }
  Future<void> runValidation() async {
    if(running || !ready)return;
    running=true;
    if(mounted)setState(()=>status='Collecting Angel API + NSE MCP + Internet evidence...');
    await refreshContext();
    try{await controller.runJavaScript('window.runSixAI();');}catch(e){if(mounted)setState(()=>status='AI bridge error: '+e.toString());}
    running=false;
  }
  String _html()=>r'''
<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
<script src="https://js.puter.com/v2/"></script>
<style>
*{box-sizing:border-box}body{margin:0;background:#f8f5fa;color:#17131d;font-family:Arial,sans-serif}.wrap{padding:14px}.hero{background:#eee7ff;border:1px solid #d7c7ff;border-radius:18px;padding:16px}.h1{font-size:23px;font-weight:800}.sub{font-size:13px;color:#665f70;margin-top:5px}.row{display:flex;gap:8px;flex-wrap:wrap;margin-top:12px}button{border:0;border-radius:24px;padding:12px 15px;font-weight:700;background:#6946b9;color:white}button.alt{background:#e4dff0;color:#322c3a}.status{margin:12px 0;font-size:13px}.live{color:#16834d;font-weight:700}.warn{color:#d98200}.err{color:#c0392b}.sources{display:grid;grid-template-columns:repeat(3,1fr);gap:7px;margin-top:12px}.src{background:#fff;border-radius:12px;padding:10px;font-size:11px}.src b{display:block;font-size:12px;margin-bottom:4px}.card{background:#fff;border-radius:16px;margin:10px 0;padding:14px;box-shadow:0 2px 7px #00000018}.head{display:flex;justify-content:space-between;gap:8px}.name{font-size:17px;font-weight:800}.badge{font-size:11px;padding:5px 9px;border-radius:15px;background:#eee}.meta{font-size:11px;color:#777;margin-top:4px}.result{white-space:pre-wrap;font:13px/1.45 Arial;margin:10px 0}.consensus{background:#eee7ff;border-radius:16px;padding:14px;margin-top:10px}.pill{display:inline-block;padding:6px 9px;border-radius:16px;background:#eee;margin:3px;font-size:11px;font-weight:700}.data{font-size:12px;color:#4f4857;margin-top:10px;line-height:1.45}
</style></head><body><div class="wrap">
<div class="hero"><div class="h1">6-AI • LIVE WORKING MODE</div><div class="sub">Angel API + official NSE MCP + Internet evidence • paper-only strategy validation</div>
<div class="row"><button id="run">RUN 6-AI VALIDATION</button><button class="alt" id="auto">AUTO: ON</button><button class="alt" id="login">PUTER SIGN IN</button></div>
<div id="status" class="status warn">Waiting for live context...</div><div id="sources" class="sources"><div class="src"><b>ANGEL API</b><span id="s1">checking</span></div><div class="src"><b>NSE MCP</b><span id="s2">checking</span></div><div class="src"><b>INTERNET</b><span id="s3">checking</span></div></div>
</div><div id="consensus" class="consensus">Final validation: WAIT until all available evidence is reconciled.</div><div id="data" class="data"></div><div id="cards"></div></div>
<script>
const AI=[
{label:'GPT-5.6 Luna',ids:['openai/gpt-5.6-luna','gpt-5.6-luna'],web:true},
{label:'Claude Sonnet 4.6',ids:['claude-sonnet-4-6','anthropic/claude-sonnet-4-6']},
{label:'GPT-5.6 Sol',ids:['openai/gpt-5.6-sol','gpt-5.6-sol'],web:true},
{label:'DeepSeek Chat',ids:['deepseek-chat','deepseek/deepseek-chat']},
{label:'Gemini 2.5 Flash',ids:['gemini-2.5-flash','google/gemini-2.5-flash']},
{label:'Grok 4',ids:['grok-4','xai/grok-4']}];
let snapshot={};let catalog=[];let running=false;let auto=true;
function esc(s){return String(s??'').replace(/[&<>\"]/g,function(m){return {'&':'&amp;','<':'&lt;','>':'&gt;','\"':'&quot;'}[m]})}
function textOf(r){if(typeof r==='string')return r;let x=r&&r.message&&r.message.content;if(Array.isArray(x))return x.map(function(v){return v&&v.text?v.text:''}).join('\n');return String(x??r?.text??JSON.stringify(r));}
function stateOf(t){let m=String(t).match(/(?:STATE|state)\s*[:=]\s*(CALL BUY|PUT BUY|WAIT|NO QUALIFYING TRADE)/i);return m?m[1].toUpperCase():'WAIT'}
window.setSnapshot=function(v){try{snapshot=JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(v),function(c){return c.charCodeAt(0)})));renderSourceStatus();}catch(e){}};
function renderSourceStatus(){let s=snapshot.three_sources||{};let a=s.angel_api||{},m=s.nse_mcp||{},n=s.nse_internet||{};document.getElementById('s1').textContent=a.connected?'CONNECTED':'NOT CONNECTED';document.getElementById('s2').textContent=m.connected?'CONNECTED':'UNAVAILABLE';document.getElementById('s3').textContent=n.connected?'CONNECTED':'UNAVAILABLE';let me=snapshot.market_evidence||{};document.getElementById('data').textContent='Symbol: '+(me.index||snapshot?.terminal?.market?.symbol||'NIFTY')+' • Spot/LTP: '+(me.spot??snapshot?.terminal?.market?.spot??'-')+' • ATM: '+(me.atm??snapshot?.terminal?.market?.atm??'-')+' • PCR: '+(me.pcr??'-')+' • Support: '+(me.top_pe_oi?.[0]?.strike??'-')+' • Resistance: '+(me.top_ce_oi?.[0]?.strike??'-');}
function render(){document.getElementById('cards').innerHTML=AI.map(function(a,i){return '<div class="card"><div class="head"><div class="name">'+(i+1)+' • '+esc(a.label)+'</div><div class="badge" id="b'+i+'">READY</div></div><div class="meta" id="m'+i+'">'+esc(a.ids[0])+'</div><div class="result" id="r'+i+'">Waiting...</div></div>'}).join('')}
render();
async function signIn(){try{await puter.auth.signIn({attempt_temp_user_creation:true});document.getElementById('status').innerHTML='<span class="live">● Puter authenticated</span>';}catch(e){document.getElementById('status').textContent='Sign-in: '+(e?.msg||e?.message||e);}}
async function models(){try{catalog=await puter.ai.listModels();}catch(e){catalog=[]}}
function modelFor(a){const ids=catalog.map(function(x){return String(x.id||'')});for(const id of a.ids){const exact=ids.find(function(x){return x===id});if(exact)return exact}for(const id of a.ids){const base=id.split('/').pop().toLowerCase();const hit=ids.find(function(x){return x.toLowerCase().includes(base)});if(hit)return hit}return null}
async function internetPacket(){try{const internetModel=modelFor(AI[0]);if(!internetModel)return 'Internet AI model unavailable.';const p='Search current Indian market information for '+((snapshot.market_evidence||{}).index||'NIFTY')+' and current option-market context. Use reliable sources, prefer official NSE and reputable financial news. Return only a compact evidence list with source names, timestamps if available, and facts. Do not give a trade recommendation.';const r=await puter.ai.chat(p,{model:internetModel,tools:[{type:'web_search'}],max_tokens:700,temperature:0.1});return textOf(r);}catch(e){return 'Internet search unavailable: '+(e?.message||e)}}
function promptFor(a,web){return 'You are '+a.label+', one of six independent validators inside an Indian index-options paper terminal. Reconcile THREE SOURCE GROUPS: (1) Angel One API live payload, (2) official NSE MCP payload, (3) Internet evidence. Never invent values. High OI is an OI concentration/potential writer zone, not proof of a seller.\nReturn these headings exactly in simple Hindi: क्या हो रहा है, पॉज़िटिव, नेगेटिव, दिक्कत-रिस्क, अब क्या देखें. Also include STATE as CALL BUY, PUT BUY, WAIT, or NO QUALIFYING TRADE on a separate line. If sources conflict or are stale, use WAIT. No order placement and no guaranteed win rate.\nANGEL/API + ENGINE + STRATEGY CONTEXT:\n'+JSON.stringify(snapshot).slice(0,26000)+'\nINTERNET EVIDENCE:\n'+web.slice(0,9000);}
async function one(a,i,web){const b=document.getElementById('b'+i),r=document.getElementById('r'+i),m=document.getElementById('m'+i);b.textContent='RUNNING';r.textContent='Reading API + NSE MCP + Internet...';try{const model=modelFor(a);if(!model){b.textContent='UNAVAILABLE';b.style.background='#ffe0e0';r.textContent='This model is not exposed by the current Puter model catalogue. No fake response or consensus is shown.';return {state:'WAIT',ok:false,error:'model unavailable'};}m.textContent=model;const opt={model:model,normalize:true,temperature:0.1,max_tokens:800};const ans=await puter.ai.chat(promptFor(a,web),opt);const t=textOf(ans);b.textContent='DONE';b.style.background='#dff5e8';r.textContent=t;return {state:stateOf(t),ok:true,text:t};}catch(e){b.textContent='ERROR';b.style.background='#ffe0e0';r.textContent=String(e?.message||e);return {state:'WAIT',ok:false,error:String(e?.message||e)};}}
async function runSixAI(){if(running)return;running=true;document.getElementById('run').disabled=true;document.getElementById('status').innerHTML='<span class="live">● LIVE</span> Six-AI validation in progress...';try{await models();const web=await internetPacket();const results=await Promise.all(AI.map(function(a,i){return one(a,i,web)}));const states=results.map(function(x){return x.state});const valid=states.filter(function(x){return x});let final='WAIT';const completed=results.filter(function(x){return x.ok}).length;if(completed===6&&valid.length===6&&new Set(valid).size===1)final=valid[0];document.getElementById('consensus').innerHTML='<b>FINAL VALIDATION: '+final+'</b><br><span class="pill">6 AI '+completed+'/6 completed</span><span class="pill">Three-source evidence used</span><span class="pill">Missing/conflict ⇒ WAIT</span>';document.getElementById('status').innerHTML='<span class="live">● LIVE</span> Validation completed • '+new Date().toLocaleTimeString();}catch(e){document.getElementById('status').innerHTML='<span class="err">'+esc(e?.message||e)+'</span>'}finally{running=false;document.getElementById('run').disabled=false}}
window.runSixAI=runSixAI;
document.getElementById('run').onclick=runSixAI;document.getElementById('login').onclick=signIn;document.getElementById('auto').onclick=function(){auto=!auto;document.getElementById('auto').textContent='AUTO: '+(auto?'ON':'OFF');};
window.addEventListener('load',function(){setTimeout(runSixAI,1500)});
</script></body></html>
''';
  @override Widget build(BuildContext context)=>WebViewWidget(controller:controller);
}