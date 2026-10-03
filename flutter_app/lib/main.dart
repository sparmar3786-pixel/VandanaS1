import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:file_saver/file_saver.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'signal_alerts.dart';
import 'puter_ai_page.dart';
import 'server_ai_page.dart';
import 'live_data_service.dart';

const String railwayBackendUrl =
    String.fromEnvironment('RAILWAY_BACKEND_URL', defaultValue: 'https://nse-algo-backend-production.up.railway.app');
const String defaultBackendUrl = railwayBackendUrl;

void main() => runApp(const AlgoApp());

class AlgoApp extends StatelessWidget {
  const AlgoApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Parmar Trading',
    theme: ThemeData.dark(useMaterial3: true),
    home: const Terminal(),
  );
}

class Terminal extends StatefulWidget {
  const Terminal({super.key});
  @override State<Terminal> createState() => _TerminalState();
}

class _TerminalState extends State<Terminal> {
  // 30-screen reference layout: the first 18 screens remain functional/live,
  // while screens 19-30 provide the complete design-system views from the supplied
  // 30 Screen Layout reference. No order-placement UI is added.
  static const screens = <String>[
    'Dashboard','Market','Commodity','Signals','OI Lab','Watchlist','Charts',
    'Option Chain','News','Market Details','Angel API','NSE','NSE MCP','Data',
    'Strategies','AI Models','Settings','More',
    'Splash / Launch','Login / Authentication','Market Overview','OI Heatmap',
    'Premium / Volume','Greeks / IV Surface','Signal Flow','Market Regime',
    'Trade Plans (S+)','Backtest','Strategy Registry','AI 6-Layer Panel'
  ];
  static const icons = <IconData>[
    Icons.dashboard, Icons.show_chart, Icons.precision_manufacturing,
    Icons.notifications_active, Icons.analytics, Icons.star, Icons.candlestick_chart,
    Icons.table_chart, Icons.article, Icons.info_outline, Icons.key, Icons.language,
    Icons.hub, Icons.storage, Icons.rule, Icons.psychology, Icons.tune, Icons.more_horiz,
    Icons.rocket_launch, Icons.login, Icons.dashboard_customize, Icons.bar_chart,
    Icons.stacked_line_chart, Icons.auto_graph, Icons.swap_vert, Icons.insights,
    Icons.view_list, Icons.history, Icons.menu_book, Icons.psychology_alt
  ];
  int selected = 0;
  String backendUrl = defaultBackendUrl;
  String apiToken = '';
  String connection = 'Connecting...';
  bool darkMode = true;
  List<dynamic> liveIndices = <dynamic>[];
  List<dynamic> liveCommodities = <dynamic>[];
  String selectedOptionSymbol = 'NIFTY';
  String chartFilterExchange = 'ALL';
  String selectedChartName = 'NIFTY 50';
  String nseMcpStatus = 'Not checked';
  String angelLoginStatus = '';
  String csvStatus = '';
  Map<String,dynamic>? signal;
  List<dynamic> liveMarket = <dynamic>[];
  List<dynamic> liveCandles = <dynamic>[];
  List<dynamic> liveOptionRows = <dynamic>[];
  dynamic optionSpot;
  List<dynamic> liveOIBuild = <dynamic>[];
  List<dynamic> liveNews = <dynamic>[];
  String liveTransport = 'HTTP polling';
  String liveLastUpdated = 'Not updated';
  String selectedChartToken = '99926000';
  String selectedChartExchange = 'NSE';
  String selectedInterval = 'FIVE_MINUTE';
  bool angelDataBusy = false;
  Map<String,dynamic>? terminalData;
  Timer? timer;
  Timer? marketTimer;
  bool chartBusy = false;
  Map<String,dynamic> strategyData=<String,dynamic>{};
  bool strategyBusy=false;
  SignalAlertService? alertService;
  SignalAlert? latestAlert;
  late final WebViewController proChartController;
  bool proChartReady = false;
  LiveDataService? liveDataService;
  Timer? liveNewsTimer;
  WebSocketChannel? liveChannel;
  StreamSubscription<dynamic>? liveSubscription;
  Timer? liveHttpTimer;

  @override void initState() {
    super.initState();
    proChartController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          proChartReady = true;
          pushProChartData();
        },
      ));
    proChartController.loadFlutterAsset('assets/prochart.html');
    startLiveConnection();
    fetchTerminal();
    fetchIndices();
    fetchCommodities();
    fetchNews();
    fetchOptionRows();
    fetchOIBuild();
    alertService = SignalAlertService(backendUrl, apiToken);
    alertService!.onAlert = (a) {
      if (!mounted) return;
      setState(() => latestAlert = a);
      Future.delayed(const Duration(seconds: 8), () {
        if (mounted && latestAlert?.seq == a.seq) setState(() => latestAlert = null);
      });
    };
    alertService!.start();
    timer = Timer.periodic(const Duration(seconds: 5), (_) { fetchTerminal(); if (selected == 6) fetchCandles(); if (selected == 14) fetchStrategy(); });
    marketTimer = Timer.periodic(const Duration(seconds: 10), (_) { fetchIndices(); fetchCommodities(); });
  }
  @override void dispose() {
    timer?.cancel();
    marketTimer?.cancel();
    liveHttpTimer?.cancel();
    liveNewsTimer?.cancel();
    liveSubscription?.cancel();
    liveChannel?.sink.close();
    alertService?.stop();
    super.dispose();
  }

  void startLiveConnection() {
    liveDataService = LiveDataService(backendUrl, apiToken);
    liveHttpTimer?.cancel();
    liveHttpTimer = Timer.periodic(const Duration(seconds: 10), (_) => fetchLiveSnapshot());
    liveNewsTimer?.cancel();
    liveNewsTimer = Timer.periodic(const Duration(seconds: 60), (_) => fetchNews());
    _connectLiveSocket();
  }

  void _connectLiveSocket() {
    try {
      liveChannel?.sink.close();
      final service = liveDataService;
      if (service == null || backendUrl.isEmpty) return;
      final channel = service.connectSocket();
      liveChannel = channel;
      liveSubscription?.cancel();
      liveSubscription = channel.stream.listen(
        (raw) {
          try {
            final d = raw is String ? jsonDecode(raw) : raw;
            if (d is Map<String, dynamic>) applyLiveSnapshot(d);
          } catch (_) {}
        },
        onError: (_) {},
        onDone: () {},
        cancelOnError: false,
      );
    } catch (_) {}
  }

  Future<void> fetchLiveSnapshot() async {
    try {
      final service = liveDataService;
      if (service == null || backendUrl.isEmpty) return;
      final d = await service.liveSnapshot();
      applyLiveSnapshot(d);
    } catch (_) {}
  }

  void applyLiveSnapshot(Map<String, dynamic> d) {
    if (!mounted) return;
    final conn = d['connection'];
    final angel = conn is Map && conn['angel'] == true;
    final server = conn is Map && conn['server'] == true;
    setState(() {
      terminalData = d;
      liveTransport = (d['live_transport'] ?? 'http').toString().toUpperCase();
      liveLastUpdated = DateTime.now().toLocal().toString().substring(11, 19);
      final s = d['signals'];
      signal = s is Map<String, dynamic> ? s : signal;
      connection = server && angel ? 'Connected' : server ? 'Backend connected / Angel not connected' : 'Backend not connected';
      final m = d['nse_mcp'];
      nseMcpStatus = m is Map && m['connected'] == true ? 'Connected' : 'Not connected';
    });
  }


  Future<void> fetchNews() async {
    try {
      final d = await liveDataService?.getJson('/v1/live/news', query: <String, String>{'q': 'NIFTY India'});
      if (d != null && mounted && d['items'] is List) {
        setState(() => liveNews = List<dynamic>.from(d['items'] as List));
      }
    } catch (_) {}
  }

  Future<void> fetchTerminal() async {
    try {
      final response = await http.get(
        backendUri('/v1/terminal'),
        headers: <String,String>{'x-token': apiToken},
      ).timeout(const Duration(seconds: 5));
      if (!mounted) return;
      dynamic decoded;
      try { decoded = jsonDecode(response.body); } catch (_) { decoded = null; }
      final conn = decoded is Map<String,dynamic> ? decoded['connection'] : null;
      final angel = conn is Map && conn['angel'] == true;
      setState(() {
        terminalData = decoded is Map<String,dynamic> ? decoded : null;
        final s = terminalData?['signals'];
        final m = terminalData?['nse_mcp'];
        signal = s is Map<String,dynamic> ? s : null;
        connection = response.statusCode == 200 && conn is Map && conn['server'] == true && conn['angel'] == true ? 'Connected' : response.statusCode == 200 && conn is Map && conn['server'] == true ? 'Backend connected / Angel not connected' : 'HTTP ' + response.statusCode.toString();
        nseMcpStatus = m is Map && m['connected'] == true ? 'Connected' : 'Not connected';
      });
      if (angel) await fetchAngelMarket();
    } catch (_) {
      if (mounted) setState(() => connection = 'Backend not connected');
    }
  }

  Future<void> downloadNseCsv() async {
    setState(() => csvStatus = 'Fetching NSE option chain...');
    try {
      final response = await http.get(
        Uri.parse(backendUrl + '/v1/nse/option-chain.csv?symbol=NIFTY'),
        headers: <String,String>{'x-token': apiToken},
      ).timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        setState(() => csvStatus = 'NSE CSV unavailable: HTTP ' + response.statusCode.toString());
        return;
      }
      await FileSaver.instance.saveFile(
        name: 'NIFTY_NSE_option_chain',
        bytes: response.bodyBytes,
        fileExtension: 'csv',
        mimeType: MimeType.csv,
      );
      if (mounted) setState(() => csvStatus = 'NIFTY NSE option-chain CSV saved.');
    } catch (e) {
      if (mounted) setState(() => csvStatus = 'CSV download failed. ' + e.toString());
    }
  }

  @override Widget build(BuildContext context) => Theme(
    data: ThemeData(useMaterial3: true, brightness: darkMode ? Brightness.dark : Brightness.light),
    child: Scaffold(
    appBar: AppBar(
      title: Text(screens[selected]),
      actions: <Widget>[
        IconButton(onPressed: fetchTerminal, icon: const Icon(Icons.refresh)),
        IconButton(onPressed: () => setState(() => darkMode = !darkMode), tooltip: 'Light / Dark mode', icon: Icon(darkMode ? Icons.light_mode : Icons.dark_mode)),
        IconButton(onPressed: openSettings, icon: const Icon(Icons.settings)),
      ],
    ),
    drawer: Drawer(
      child: SafeArea(child: ListView(
        padding: EdgeInsets.zero,
        children: <Widget>[
          const DrawerHeader(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Icon(Icons.candlestick_chart, size: 42),
            SizedBox(height: 10),
            Text('Parmar Trading', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            SizedBox(height: 4),
            Text('30-screen NSE AI terminal'),
          ])),
          for (int i=0; i<screens.length; i++) ListTile(
            leading: Icon(icons[i]),
            title: Text(screens[i]),
            selected: selected == i,
            onTap: () { Navigator.pop(context); setState(() => selected = i); },
          ),
        ],
      )),
    ),
    body: Stack(
      children: <Widget>[
        buildScreen(),
        if (latestAlert != null)
          Positioned(
            top: 8, left: 8, right: 8,
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(12),
              color: latestAlert!.kind == 'ENTRY' ? Colors.green.shade700 : Colors.red.shade700,
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => setState(() => latestAlert = null),
                child: Padding(
                  padding: const EdgeInsets.all(13),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                    Text(latestAlert!.title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 3),
                    Text(latestAlert!.body, style: const TextStyle(color: Colors.white, fontSize: 13)),
                  ]),
                ),
              ),
            ),
          ),
      ],
    ),
  ),
  );

  Widget buildScreen() {
    Widget screen;
    if (selected == 0) screen = dashboard();
    else if (selected == 1) screen = marketPage();
    else if (selected == 2) screen = commodityPage();
    else if (selected == 3) screen = signals();
    else if (selected == 4) screen = oiLabPage();
    else if (selected == 5) screen = watchlistPage();
    else if (selected == 6) screen = chartsPage();
    else if (selected == 7) screen = optionChain();
    else if (selected == 8) screen = newsPage();
    else if (selected == 9) screen = marketDetailsPage();
    else if (selected == 10) screen = angelApi();
    else if (selected == 12) screen = nseMcp();
    else if (selected == 14) screen = strategiesPage();
    else if (selected == 15) screen = aiModelsPage();
    else if (selected == 16) screen = settingsPage();
    else if (selected == 17) screen = morePage();
    else if (selected >= 18) screen = referenceLayoutScreen(selected);
    else screen = dataPage(screens[selected]);
    return Column(children: <Widget>[
      liveStatusStrip(),
      Expanded(child: screen),
    ]);
  }

  Widget liveStatusStrip() => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    child: Row(children: <Widget>[
      Icon(Icons.circle, size: 9, color: connection == 'Connected' ? Colors.green : Colors.orange),
      const SizedBox(width: 6),
      Expanded(child: Text('LIVE API • $connection • $liveTransport • updated $liveLastUpdated', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11))),
      IconButton(
        visualDensity: VisualDensity.compact,
        onPressed: fetchLiveSnapshot,
        icon: const Icon(Icons.sync, size: 17),
      ),
    ]),
  );

  Widget dashboard() {
    final marketOpen = terminalData?["market_open"] == true;
    final e = (terminalData?["engine_state"] is Map) ? Map<String,dynamic>.from(terminalData!["engine_state"] as Map) : <String,dynamic>{};
    const unavailable = "DATA UNAVAILABLE";
    String value(dynamic v) => v == null || v.toString().trim().isEmpty ? unavailable : v.toString();
    final trend = value(e["trend"]);
    final action = value(e["signal_status"]);
    final up = trend.toUpperCase().contains("UP");
    final down = trend.toUpperCase().contains("DOWN");
    final color = !marketOpen ? Colors.blue : up ? Colors.green : down ? Colors.red : Colors.blue;
    final status = value(e["status"]);
    return ListView(padding: const EdgeInsets.all(12), children: <Widget>[
      Card(color: color.withOpacity(.18), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: color, width: 1.5)), child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Row(children: <Widget>[const Icon(Icons.bolt, size: 30), const SizedBox(width: 10), const Expanded(child: Text("NSE Algo Signal", style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold))), Chip(backgroundColor: color, label: Text(marketOpen ? trend : "MARKET CLOSED", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)))]),
        const SizedBox(height: 8),
        Text("Engine status: $status", style: TextStyle(color: color, fontWeight: FontWeight.bold)),
        Text("Live snapshot • no fabricated values"),
      ]))),
      const SizedBox(height: 10),
      Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        const Text("CURRENT ENGINE STATE", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const Divider(height: 20),
        row("Symbol", value(e["symbol"])),
        row("Index / Underlying LTP", value(e["index_ltp"])),
        row("CE / PE", value(e["ce_pe"])),
        row("Strike Price", value(e["strike"])),
        row("Option LTP", value(e["option_ltp"])),
        row("OI", value(e["oi"])),
        row("OI Change", value(e["oi_change"])),
        row("Volume", value(e["volume"])),
        row("ATM", value(e["atm"])),
        row("Trend", trend),
        row("Signal Status", action),
      ]))),
      const SizedBox(height: 10),
      Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        const Text("SIGNAL DETAILS", style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        row("Option Symbol", value(e["option_symbol"])),
        row("Entry", value(e["entry"])),
        row("Stop Loss", value(e["stop_loss"])),
        row("Target", value(e["target"])),
      ]))),
      const SizedBox(height: 10),
      infoCard("Connection", connection, connection == "Connected" ? Colors.green : Colors.orange),
      infoCard("Mode", "Paper signals only • No order placement.", Colors.blue),
      FilledButton.icon(onPressed: fetchTerminal, icon: const Icon(Icons.refresh), label: const Text("REFRESH LIVE ENGINE")),
    ]);
  }
  Future<void> fetchIndices() async {
    try {
      final r=await http.get(backendUri('/v1/angel/indices'),headers:<String,String>{'x-token':apiToken}).timeout(const Duration(seconds:8));
      if(r.statusCode==200){final d=jsonDecode(r.body);final rows=d is Map&&d['data'] is List?d['data']:<dynamic>[];if(mounted)setState(()=>liveIndices=rows is List?rows:<dynamic>[]);}
    } catch (_) {}
  }

  Future<void> fetchCommodities() async {
    try {
      final r=await http.get(backendUri('/v1/angel/commodities'),headers:<String,String>{'x-token':apiToken}).timeout(const Duration(seconds:10));
      if(r.statusCode==200){final d=jsonDecode(r.body);final rows=d is Map&&d['data'] is Map&&d['data']['fetched'] is List?d['data']['fetched']:<dynamic>[];if(mounted)setState(()=>liveCommodities=rows is List?rows:<dynamic>[]);}
    } catch (_) {}
  }

  Future<void> fetchAngelMarket() async {
    try {
      final r=await http.get(backendUri('/v1/angel/market'),headers:<String,String>{'x-token':apiToken}).timeout(const Duration(seconds:8));
      if(r.statusCode==200){
        final d=jsonDecode(r.body);
        final rows=d is Map && d['data'] is Map ? (d['data']['fetched'] ?? <dynamic>[]) : <dynamic>[];
        if(mounted) setState(()=>liveMarket=rows is List ? rows : <dynamic>[]);
      }
    } catch (_) {}
  }

  Future<void> pushProChartData() async {
    if (!proChartReady) return;
    try {
      final payload = jsonEncode(liveCandles);
      await proChartController.runJavaScript('window.setChartData(' + payload + ');');
      await proChartController.runJavaScript(
        'window.setChartSymbol(' + jsonEncode(selectedChartName) + ');',
      );
    } catch (_) {}
  }

  Future<void> fetchCandles() async {
    if(chartBusy)return;
    chartBusy=true;
    if(mounted)setState(()=>angelDataBusy=true);
    try {
      final u=backendUrl+'/v1/angel/candles?exchange='+selectedChartExchange+'&token='+selectedChartToken+'&interval='+selectedInterval+'&days=1';
      final r=await http.get(Uri.parse(u),headers:<String,String>{'x-token':apiToken}).timeout(const Duration(seconds:12));
      if(r.statusCode==200){
        final d=jsonDecode(r.body);
        final rows=d is Map && d['data'] is List ? d['data'] : <dynamic>[];
        if(mounted) { setState(()=>liveCandles=rows is List ? rows : <dynamic>[]); await pushProChartData(); }
      }
    } catch (_) {} finally { chartBusy=false; if(mounted) setState(()=>angelDataBusy=false); }
  }

  Future<void> fetchOptionRows() async {
    setState(()=>angelDataBusy=true);
    try {
      final r=await http.get(backendUri('/v1/angel/option-chain?symbol='+selectedOptionSymbol+'&count=10'),headers:<String,String>{'x-token':apiToken}).timeout(const Duration(seconds:15));
      if(r.statusCode==200){
        final d=jsonDecode(r.body);
        final rows=d is Map && d['rows'] is List ? d['rows'] : <dynamic>[];
        if(mounted) setState(() { liveOptionRows=rows is List ? rows : <dynamic>[]; optionSpot=d is Map ? d['spot'] : null; });
      }
    } catch (_) {} finally { if(mounted) setState(()=>angelDataBusy=false); }
  }

  Future<void> fetchOIBuild() async {
    setState(()=>angelDataBusy=true);
    try {
      final r=await http.get(backendUri('/v1/angel/oi-buildup?datatype=Long%20Built%20Up&expirytype=NEAR'),headers:<String,String>{'x-token':apiToken}).timeout(const Duration(seconds:12));
      if(r.statusCode==200){
        final d=jsonDecode(r.body);
        final rows=d is Map && d['data'] is List ? d['data'] : <dynamic>[];
        if(mounted) setState(()=>liveOIBuild=rows is List ? rows : <dynamic>[]);
      }
    } catch (_) {} finally { if(mounted) setState(()=>angelDataBusy=false); }
  }

  Widget indexCard(dynamic q) {
    final name=(q['tradingSymbol']??q['tradingsymbol']??'-').toString();
    return Card(child:ListTile(
      title:Text(name,style:const TextStyle(fontWeight:FontWeight.bold)),
      subtitle:Text('Open '+(q['open']??'-').toString()+'  High '+(q['high']??'-').toString()+'  Low '+(q['low']??'-').toString()),
      trailing:Column(mainAxisAlignment:MainAxisAlignment.center,crossAxisAlignment:CrossAxisAlignment.end,children:<Widget>[
        Text((q['ltp']??'-').toString(),style:const TextStyle(fontSize:18,fontWeight:FontWeight.bold)),
        Text((q['netChange']??'').toString()+' '+(q['percentChange']??'').toString())
      ]),
    ));
  }

  Widget marketPage() => ListView(padding:const EdgeInsets.all(12),children:<Widget>[
    const Text('Market • Indian Indices',style:TextStyle(fontSize:24,fontWeight:FontWeight.bold)), const SizedBox(height:8),
    infoCard('Live source','Angel One SmartAPI • NSE + BSE index universe',Colors.blue),
    ...liveIndices.map((q)=>_quoteCard(q)),
    if(liveIndices.isEmpty) infoCard('Indices','Waiting for Angel One index feed.',Colors.orange),
    FilledButton.icon(onPressed:fetchIndices,icon:const Icon(Icons.refresh),label:const Text('REFRESH ALL INDIAN INDICES')),
  ]);

  Widget _quoteCard(dynamic q) {
    final pct=num.tryParse((q['percentChange']??q['netChange']??'').toString())??0;
    final color=pct>0?Colors.green:pct<0?Colors.red:Colors.blue;
    return Card(child:ListTile(title:Text((q['name']??q['symbol']??'-').toString()),subtitle:Text((q['exchange']??'').toString()+' • '+(q['percentChange']??q['netChange']??'-').toString()),trailing:Text((q['ltp']??'-').toString(),style:TextStyle(color:color,fontSize:18,fontWeight:FontWeight.bold))));
  }

  Widget commodityPage() => ListView(padding:const EdgeInsets.all(12),children:<Widget>[
    const Text('Commodity • MCX',style:TextStyle(fontSize:24,fontWeight:FontWeight.bold)), const SizedBox(height:8),
    infoCard('Live source','Angel One SmartAPI • MCX current contracts',Colors.blue),
    ...liveCommodities.map((q)=>Card(child:ListTile(title:Text((q['tradingSymbol']??q['name']??'-').toString()),subtitle:Text('Expiry '+(q['expiry']??'-').toString()+' • OI '+(q['oi']??'-').toString()),trailing:Text((q['ltp']??'-').toString(),style:const TextStyle(fontWeight:FontWeight.bold,fontSize:18))))),
    if(liveCommodities.isEmpty) infoCard('MCX','Waiting for commodity contracts/live quotes.',Colors.orange),
    FilledButton.icon(onPressed:fetchCommodities,icon:const Icon(Icons.refresh),label:const Text('REFRESH MCX')),
  ]);

  Widget oiLabPage() => ListView(padding:const EdgeInsets.all(12),children:<Widget>[
    const Text('OI Lab • Indian Index Options',style:TextStyle(fontSize:24,fontWeight:FontWeight.bold)),
    const SizedBox(height:8),
    infoCard('Scope','Only Indian index option OI. MCX/futures are excluded.',Colors.blue),
    Wrap(spacing:6,children:<Widget>[
      for(final sym in const['NIFTY','BANKNIFTY','FINNIFTY','MIDCPNIFTY','SENSEX','BANKEX'])
        FilterChip(label:Text(sym),selected:selectedOptionSymbol==sym,onSelected:(_){setState(()=>selectedOptionSymbol=sym);fetchOptionRows();})
    ]),
    const SizedBox(height:8),
    if(liveOptionRows.isNotEmpty) _oiSummaryCards(),
    if(liveOptionRows.isEmpty) infoCard('OI snapshot','Select an index to load its live CE/PE OI snapshot.',Colors.orange),
  ]);

  Widget _oiSummaryCards() {
    num ceOI=0,peOI=0,ceUp=0,peUp=0,ceDown=0,peDown=0;
    for(final r in liveOptionRows){
      final oi=num.tryParse((r['oi']??0).toString())??0;
      final ch=num.tryParse((r['oiChangePct']??0).toString())??0;
      if(r['type']=='CE'){ceOI+=oi;if(ch>0)ceUp++;if(ch<0)ceDown++;}
      if(r['type']=='PE'){peOI+=oi;if(ch>0)peUp++;if(ch<0)peDown++;}
    }
    return Column(children:<Widget>[
      Row(children:<Widget>[
        Expanded(child:infoCard('CALL OI',ceOI.toStringAsFixed(0)+' • ↑ '+ceUp.toString()+' ↓ '+ceDown.toString(),Colors.green)),
        const SizedBox(width:8),
        Expanded(child:infoCard('PUT OI',peOI.toStringAsFixed(0)+' • ↑ '+peUp.toString()+' ↓ '+peDown.toString(),Colors.red)),
      ]),
      infoCard('OI direction','↑ OI = addition • ↓ OI = reduction • selected index: '+selectedOptionSymbol,Colors.blue),
    ]);
  }

  Widget watchlistPage() => ListView(padding:const EdgeInsets.all(12),children:<Widget>[
    const Text('Watchlist • All Indian Indices',style:TextStyle(fontSize:24,fontWeight:FontWeight.bold)), const SizedBox(height:8),
    ...liveIndices.map((q)=>Card(child:ListTile(leading:const Icon(Icons.star_border),title:Text((q['name']??q['symbol']??'-').toString()),subtitle:Text((q['exchange']??'').toString()),trailing:Column(mainAxisAlignment:MainAxisAlignment.center,crossAxisAlignment:CrossAxisAlignment.end,children:<Widget>[Text((q['ltp']??'-').toString(),style:const TextStyle(fontWeight:FontWeight.bold)),Text((q['percentChange']??q['netChange']??'-').toString())])))),
    if(liveIndices.isEmpty) infoCard('Watchlist','Waiting for index feed.',Colors.orange),
  ]);

  Widget chartsPage() => Column(children:<Widget>[
    Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Row(children:<Widget>[
        Expanded(child: Text(
          'ProChart • ' + selectedChartName,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        )),
        IconButton(
          tooltip: 'Refresh live candles',
          onPressed: fetchCandles,
          icon: Icon(angelDataBusy ? Icons.sync : Icons.refresh),
        ),
      ]),
    ),
    Expanded(child: WebViewWidget(controller: proChartController)),
  ]);

  Widget optionChain() => ListView(padding:const EdgeInsets.all(8),children:<Widget>[
    const Text('Option Chain • Indian Indices',style:TextStyle(fontSize:24,fontWeight:FontWeight.bold)), const SizedBox(height:6),
    Wrap(spacing:6,children:<Widget>[for(final s in const['NIFTY','BANKNIFTY','FINNIFTY','MIDCPNIFTY','SENSEX','BANKEX'])FilterChip(label:Text(s),selected:selectedOptionSymbol==s,onSelected:(_){setState(()=>selectedOptionSymbol=s);fetchOptionRows();})]),
    const SizedBox(height:8), if(liveOptionRows.isEmpty) infoCard('Option chain','Select an index and refresh to load live CE/PE.',Colors.orange),
    ..._optionChainCards(), FilledButton.icon(onPressed:fetchOptionRows,icon:const Icon(Icons.refresh),label:Text(angelDataBusy?'LOADING...':'REFRESH LIVE OPTION CHAIN')),
  ]);

  List<Widget> _optionChainCards() {
    final byStrike=<String,Map<String,dynamic>>{};
    for(final r in liveOptionRows.where((x)=>x is Map)){
      final key=(r['strike']??'-').toString();
      byStrike.putIfAbsent(key,()=>{}); byStrike[key]![r['type'].toString()]=r;
    }
    final keys=byStrike.keys.toList()..sort((a,b)=>(double.tryParse(a)??0).compareTo(double.tryParse(b)??0));
    return keys.map((strike){
      final ce=byStrike[strike]!['CE']; final pe=byStrike[strike]!['PE'];
      final atm=optionSpot!=null && (double.tryParse(strike)??-1)==(double.tryParse(optionSpot.toString())??-2);
      return Card(child:Padding(padding:const EdgeInsets.all(8),child:Column(children:<Widget>[
        Container(width:double.infinity,padding:const EdgeInsets.symmetric(vertical:5),color:Theme.of(context).brightness==Brightness.dark?Colors.white.withOpacity(.08):Colors.black.withOpacity(.04),child:Center(child:Text(atm?'SPOT  '+strike+'  SPOT':strike,style:const TextStyle(fontWeight:FontWeight.bold)))),
        const SizedBox(height:6), Row(crossAxisAlignment:CrossAxisAlignment.start,children:<Widget>[
          Expanded(child:_optionCell(ce,'CE')), const SizedBox(width:8), Expanded(child:_optionCell(pe,'PE')),
        ]),
      ])));
    }).toList();
  }

  Widget _optionCell(dynamic r,String side) {
    if(r==null)return Card(child:Padding(padding:const EdgeInsets.all(8),child:Text(side+' —')));
    final ch=double.tryParse(r['priceChange']?.toString() ?? r['netChange']?.toString() ?? '0')??0;
    final oiCh=double.tryParse(r['oiChangePct']?.toString() ?? '0')??0;
    final color=ch>0?Colors.green:ch<0?Colors.red:Colors.blue;
    final oiArrow=oiCh>0?'↑':oiCh<0?'↓':'—'; final priceArrow=ch>0?'↑':ch<0?'↓':'—';
    return Column(crossAxisAlignment:CrossAxisAlignment.start,children:<Widget>[
      Text(side,style:TextStyle(fontWeight:FontWeight.bold,color:side=='CE'?Colors.green:Colors.red)),
      Text('LTP '+(r['ltp']??'-').toString()+'  OI '+(r['oi']??'-').toString()),
      Text('OI $oiArrow  PRICE $priceArrow',style:TextStyle(color:color,fontWeight:FontWeight.bold)),
      Text('Δ '+(r['delta']??'-').toString()+'  Γ '+(r['gamma']??'-').toString()),
      Text('Θ '+(r['theta']??'-').toString()+'  V '+(r['vega']??'-').toString()),
      Text('POP '+(r['pop']??'-').toString()),
    ]);
  }

  Widget newsPage() => ListView(padding:const EdgeInsets.all(16),children:<Widget>[
    const Text('News',style:TextStyle(fontSize:24,fontWeight:FontWeight.bold)),
    const SizedBox(height:8),
    infoCard('Source','Live Internet news feed via secure backend adapter.',Colors.blue),
    if(liveNews.isEmpty) infoCard('Status','Waiting for live news feed.',Colors.orange),
    ...liveNews.map((x) {
      final m=x is Map ? Map<String,dynamic>.from(x) : <String,dynamic>{};
      return Card(child:ListTile(
        title:Text((m['title'] ?? 'Untitled').toString()),
        subtitle:Text(((m['source'] ?? '')).toString()+' • '+((m['published'] ?? '')).toString()),
        trailing:const Icon(Icons.public),
      ));
    }),
    FilledButton.icon(onPressed:fetchNews,icon:const Icon(Icons.refresh),label:const Text('REFRESH LIVE NEWS')),
  ]);

  Widget marketDetailsPage() => ListView(padding:const EdgeInsets.all(16),children:<Widget>[
    const Text('Market Details',style:TextStyle(fontSize:24,fontWeight:FontWeight.bold)),
    const SizedBox(height:8),
    infoCard('Indices','Angel One live market payload',Colors.blue),
    ...liveMarket.map(indexCard),
    infoCard('OI / breadth','Angel OI APIs are available through the backend.',Colors.green),
  ]);

  Map<String,dynamic>? strategyRefresh;
  Future<void> refreshStrategy() async {
    try {
      final r=await http.get(backendUri('/v1/strategy/refresh'),headers:<String,String>{'x-token':apiToken}).timeout(const Duration(seconds:12));
      if(r.statusCode==200){final d=jsonDecode(r.body);if(mounted)setState(()=>strategyRefresh=d is Map<String,dynamic>?d:null);}
    } catch (_) {}
  }
  Widget signals() {
    final action = (signal?['action']?.toString() ?? 'WAIT').replaceAll('_',' ');
    final underlying = (signal?['underlying'] ?? signal?['index'] ?? signal?['indexName'] ?? signal?['symbol'] ?? selectedOptionSymbol).toString();
    final optionSymbol = (signal?['optionSymbol'] ?? signal?['tradingSymbol'] ?? signal?['tradingsymbol'] ?? signal?['symbol'] ?? '-').toString();
    final ltp = signal?['ltp'] ?? signal?['optionLtp'] ?? signal?['option_ltp'] ?? '-';
    final strike = signal?['strike'] ?? '-';
    final entry = signal?['entry'] ?? '-';
    final sl = signal?['sl'] ?? signal?['stopLoss'] ?? signal?['stop_loss'] ?? '-';
    final target = signal?['target'] ?? '-';
    final spot = signal?['spot'] ?? '-';
    final raw = signal?['reasons'];
    final reasons = raw is List ? raw.map((e) => e.toString()).join('\n') : (raw?.toString() ?? 'No qualifying live evidence yet.');
    final wait = action == 'WAIT' || action == 'NO QUALIFYING TRADE';
    return ListView(padding: const EdgeInsets.all(16), children: <Widget>[
      const Text('Signals', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      Text('Angel One live engine • clear instrument fields • paper only', style: TextStyle(color: Colors.grey.shade700)),
      const SizedBox(height: 12),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Row(children: <Widget>[
              Icon(wait ? Icons.pause_circle_outline : Icons.bolt, color: wait ? Colors.orange : Colors.green, size: 30),
              const SizedBox(width: 10),
              Expanded(child: Text(action, style: TextStyle(fontSize: 25, fontWeight: FontWeight.bold, color: wait ? Colors.orange : Colors.green))),
            ]),
            const Divider(height: 22),
            row('Underlying / Index', underlying),
            row('Option Symbol', optionSymbol),
            row('Spot', spot),
            row('LTP', ltp),
            row('Strike', strike),
            row('Entry', entry),
            row('Stop Loss', sl),
            row('Target', target),
          ]),
        ),
      ),
      const SizedBox(height: 10),
      infoCard('ENGINE READOUT', reasons, wait ? Colors.orange : Colors.green),
      const SizedBox(height: 10),
      infoCard('Policy','CALL BUY / PUT BUY only when qualifying evidence exists. WAIT means no qualifying trade is being forced.',Colors.blue),
      const SizedBox(height: 10),
      FilledButton.icon(onPressed:() async { await fetchTerminal(); await refreshStrategy(); },icon:const Icon(Icons.refresh),label:const Text('REFRESH STRATEGY • LIVE EVIDENCE')),
      if(strategyRefresh!=null) Card(child:Padding(padding:const EdgeInsets.all(14),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:<Widget>[
        const Text('STRATEGY ENGINE DETAIL',style:TextStyle(fontSize:18,fontWeight:FontWeight.bold)),
        row('Trend',strategyRefresh!['trend']), row('PCR',strategyRefresh!['pcr']), row('Support',strategyRefresh!['support']), row('Resistance',strategyRefresh!['resistance']), row('Max Pain',strategyRefresh!['max_pain']),
        row('Total CE OI',strategyRefresh!['ce_total_oi']), row('Total PE OI',strategyRefresh!['pe_total_oi']),
        row('Call seller pressure',strategyRefresh!['call_seller_pressure']), row('Put seller pressure',strategyRefresh!['put_seller_pressure']),
        const SizedBox(height:6), Text('Sources: Angel One API • NSE MCP/engine • Internet evidence',style:TextStyle(fontSize:12,color:Colors.grey)),
      ]))),
    ]);
  }

  Future<void> fetchStrategy() async {
    if(strategyBusy)return;
    strategyBusy=true;
    try{
      final r=await http.get(backendUri('/v1/strategy/refresh?index='+selectedOptionSymbol),headers:<String,String>{'x-token':apiToken}).timeout(const Duration(seconds:10));
      if(r.statusCode==200){final d=jsonDecode(r.body);if(d is Map<String,dynamic> && mounted)setState(()=>strategyData=d);}
    }catch(_){}finally{strategyBusy=false;}
  }

  Widget strategiesPage() {
    final d = strategyData;
    final ok = d["available"] == true;
    final trend = (d["trend"] ?? "DATA UNAVAILABLE").toString();
    final trendUpper = trend.toUpperCase();
    final color = trendUpper.contains("UP")
        ? Colors.green
        : trendUpper.contains("DOWN")
            ? Colors.red
            : Colors.blue;
    String n(dynamic x) =>
        x == null || x.toString().trim().isEmpty ? "DATA UNAVAILABLE" : x.toString();
    List<dynamic> listValue(dynamic x) => x is List ? x : <dynamic>[];
    final ce = listValue(d["highest_ce_oi"]);
    final pe = listValue(d["highest_pe_oi"]);
    final cwp = listValue(d["call_writer_pressure"]);
    final pwp = listValue(d["put_writer_pressure"]);
    final changes = listValue(d["what_is_changing"]);
    final bc = d["buildup_counts"] is Map
        ? Map<String, dynamic>.from(d["buildup_counts"] as Map)
        : <String, dynamic>{};

    Widget strikeCard(dynamic x, String side) {
      final m = x is Map ? Map<String, dynamic>.from(x) : <String, dynamic>{};
      return Card(
        child: ListTile(
          title: Text("$side ${n(m["strike"])}"),
          subtitle: Text(
            "OI ${n(m["oi"])} • LTP ${n(m["ltp"])} • OI Δ ${n(m["oi_change"])} • Premium Δ ${n(m["premium_change"])}",
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(14),
      children: <Widget>[
        const Text("Strategy Engine", style: TextStyle(fontSize: 25, fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        const Text(
          "One live snapshot • Angel API + NSE evidence + Internet AI",
          style: TextStyle(color: Colors.grey),
        ),
        const SizedBox(height: 12),
        infoCard(
          "INDEX / LTP",
          "${n(d["index"])} • LTP ${n(d["spot"])} • ATM ${n(d["atm"])}",
          Colors.blue,
        ),
        infoCard("TREND", "$trend • PCR ${n(d["pcr"])}", color),
        Row(
          children: <Widget>[
            Expanded(child: infoCard("SUPPORT", n(d["support"]), Colors.green)),
            const SizedBox(width: 8),
            Expanded(child: infoCard("RESISTANCE", n(d["resistance"]), Colors.red)),
          ],
        ),
        infoCard("MAX PAIN", n(d["max_pain"]), Colors.blue),
        infoCard("CALL SELLER / WRITER PRESSURE", n(d["call_seller_pressure"]), Colors.orange),
        infoCard("PUT SELLER / WRITER PRESSURE", n(d["put_seller_pressure"]), Colors.orange),
        const SizedBox(height: 6),
        const Text("HIGHEST CALL OI", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        ...ce.map((x) => strikeCard(x, "CE")),
        const Text("HIGHEST PUT OI", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        ...pe.map((x) => strikeCard(x, "PE")),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text("OI / PREMIUM CLASSIFICATION", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                row("Long buildup", n(bc["LONG_BUILDUP"])),
                row("Short buildup", n(bc["SHORT_BUILDUP"])),
                row("Short covering", n(bc["SHORT_COVERING"])),
                row("Long unwinding", n(bc["LONG_UNWINDING"])),
              ],
            ),
          ),
        ),
        if (cwp.isNotEmpty) ...<Widget>[
          const Text("CALL WRITER EVIDENCE", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ...cwp.map((x) => strikeCard(x, "CE")),
        ],
        if (pwp.isNotEmpty) ...<Widget>[
          const Text("PUT WRITER EVIDENCE", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ...pwp.map((x) => strikeCard(x, "PE")),
        ],
        const Text("WHAT IS CHANGING", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        ...changes.take(12).map((x) {
          final m = x is Map ? Map<String, dynamic>.from(x) : <String, dynamic>{};
          return Card(
            child: ListTile(
              title: Text("${n(m["type"])} ${n(m["strike"])} • ${n(m["classification"])}"),
              subtitle: Text("Premium Δ ${n(m["premium_change"])} • OI Δ ${n(m["oi_change"])}"),
            ),
          );
        }),
        if (!ok)
          infoCard(
            "ENGINE",
            "Live option snapshot unavailable. No fabricated strategy data is shown.",
            Colors.orange,
          ),
        infoCard(
          "CURRENT ENGINE SIGNAL",
          n(d["current_engine_state"] is Map
              ? (d["current_engine_state"] as Map)["signal_status"]
              : d["action"]),
          Colors.blue,
        ),
        FilledButton.icon(
          onPressed: strategyBusy ? null : fetchStrategy,
          icon: const Icon(Icons.refresh),
          label: Text(strategyBusy ? "REFRESHING..." : "REFRESH STRATEGY • LIVE"),
        ),
      ],
    );
  }
  Widget aiModelsPage() => ServerAiPage(
    backendUrl: backendUrl,
    apiToken: apiToken,
    initialSnapshot: terminalData,
    symbol: selectedOptionSymbol,
  );

  Widget nseMcp() => ListView(padding: const EdgeInsets.all(16), children: <Widget>[
    const Text('NSE MCP', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
    const SizedBox(height: 12),
    infoCard('Official endpoint','https://mcp.nseindia.in/cmmkt/mcp',Colors.blue),
    infoCard('Connection',nseMcpStatus,nseMcpStatus == 'Connected' ? Colors.green : Colors.orange),
    infoCard('Internal Market MCP',backendUrl + '/mcp',Colors.blue),
    infoCard('Strategy Evidence MCP',backendUrl + '/mcp-strategy',Colors.blue),
    infoCard('CSV route',backendUrl + '/v1/nse/option-chain.csv?symbol=NIFTY',Colors.blue),
    const Text('MCP access is server-side; APK never stores NSE/Angel credentials.', style: TextStyle(color: Colors.grey)),
  ]);

  Widget angelApi() => AngelApiForm(
    backendUrl: backendUrl,
    apiToken: apiToken,
    connection: connection,
    status: angelLoginStatus,
    onConnected: fetchTerminal,
    onStatus: (v) => setState(() => angelLoginStatus = v),
  );

  Widget settingsPage() => ListView(padding: const EdgeInsets.all(16), children: <Widget>[
    const Text('Settings', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
    const SizedBox(height: 12),
    infoCard('Backend provider',backendProvider(),backendProvider() == 'Railway' ? Colors.green : Colors.blue),
    infoCard('Backend URL',backendUrl,Colors.blue),
    infoCard('MCP servers','Market MCP + Strategy Evidence MCP + official NSE MCP client',Colors.blue),
    infoCard('Mode','Paper signals only',Colors.orange),
    infoCard('Timeframes','1m 2m 3m 5m 10m 15m 30m 1h 2h 4h 1D',Colors.blue),
    infoCard('Indicators','8 EMA / 13 EMA',Colors.blue),
    FilledButton.icon(onPressed: openSettings, icon: const Icon(Icons.dns), label: const Text('Edit server connection')),
  ]);

  Widget morePage() => ListView(padding: const EdgeInsets.all(16), children: <Widget>[
    const Text('More', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
    const SizedBox(height: 12),
    infoCard('Order mode','No order placement. Paper signals only.',Colors.orange),
    infoCard('Security','Keep Angel credentials server-side and never commit secrets.',Colors.blue),
    infoCard('Navigation',screens.join(', '),Colors.blue),
  ]);

  Widget dataPage(String title) => ListView(padding: const EdgeInsets.all(16), children: <Widget>[
    Row(children: <Widget>[Icon(icons[selected], size: 30), const SizedBox(width: 10), Text(title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold))]),
    const SizedBox(height: 14),
    infoCard('Live data status', connection == 'Connected' ? 'Backend connected. This screen will use its corresponding live payload when available.' : 'Backend not connected. No fabricated market values are shown.', connection == 'Connected' ? Colors.green : Colors.orange),
    const SizedBox(height: 10),
    infoCard('Data source', title == 'NSE MCP' ? 'NSE MCP integration is configured by the backend.' : 'Corresponding API/data adapter is handled by the backend.', Colors.blue),
  ]);

  String backendProvider() {
    final host = Uri.tryParse(cleanUrl(backendUrl))?.host.toLowerCase() ?? '';
    if (host == 'railway.app' || host.endsWith('.railway.app')) return 'Railway';
    if (host.isEmpty) return 'Railway URL not configured';
    return 'Invalid backend';
  }

  Widget referenceLayoutScreen(int index) {
    final specs = <Map<String,dynamic>>[
      {'title':'Splash / Launch','subtitle':'Smart Analysis • Disciplined Execution • AI Powered','icon':Icons.rocket_launch},
      {'title':'Login / Authentication','subtitle':'Secure Angel One connection through backend','icon':Icons.login},
      {'title':'Market Overview','subtitle':'Indices • Options • Watchlist','icon':Icons.dashboard_customize},
      {'title':'OI Heatmap','subtitle':'CE / PE concentration and change in OI','icon':Icons.bar_chart},
      {'title':'Premium / Volume','subtitle':'CE-PE premium spread • volume flow','icon':Icons.stacked_line_chart},
      {'title':'Greeks / IV Surface','subtitle':'ATM IV • Delta • Gamma • Vega • Theta','icon':Icons.auto_graph},
      {'title':'Signal Flow','subtitle':'Signal lifecycle • no order placement','icon':Icons.swap_vert},
      {'title':'Market Regime','subtitle':'Trend • Volatility • Momentum • Mode','icon':Icons.insights},
      {'title':'Trade Plans (S+)','subtitle':'Qualifying setups with entry, SL and targets','icon':Icons.view_list},
      {'title':'Backtest','subtitle':'Strategy performance • equity curve • trade count','icon':Icons.history},
      {'title':'Strategy Registry','subtitle':'Searchable strategy families and validation state','icon':Icons.menu_book},
      {'title':'AI 6-Layer Panel','subtitle':'Six-layer validation context','icon':Icons.psychology_alt},
    ];
    final spec = specs[index - 18];
    final isDarkVariant = index >= 26;
    final bg = isDarkVariant ? const Color(0xFF07111D) : Theme.of(context).scaffoldBackgroundColor;
    final accent = Theme.of(context).colorScheme.primary;
    final pct = liveIndices.isNotEmpty
        ? (liveIndices.first['percentChange'] ?? liveIndices.first['netChange'] ?? '--').toString()
        : '--';
    final ltp = liveIndices.isNotEmpty
        ? (liveIndices.first['ltp'] ?? '--').toString()
        : '--';

    Widget metric(String label, String value, {Color? color}) => Expanded(
      child: Card(
        color: color?.withValues(alpha: .10),
        child: Padding(
          padding: const EdgeInsets.all(11),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(label, style: Theme.of(context).textTheme.labelSmall),
              const SizedBox(height: 5),
              Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      ),
    );

    Widget section(String title, Widget child) => Card(
      child: Padding(
        padding: const EdgeInsets.all(13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );

    final liveRows = liveOptionRows.whereType<Map>().toList();
    Map<String,dynamic>? liveAtm() {
      final spot = double.tryParse((optionSpot ?? '').toString());
      if (liveRows.isEmpty || spot == null) return liveRows.isNotEmpty ? Map<String,dynamic>.from(liveRows.first) : null;
      Map<String,dynamic>? best;
      var bestDiff = double.infinity;
      for (final r in liveRows) {
        final strike = double.tryParse((r['strike'] ?? '').toString());
        if (strike == null) continue;
        final diff = (strike - spot).abs();
        if (diff < bestDiff) { bestDiff = diff; best = Map<String,dynamic>.from(r); }
      }
      return best;
    }
    String liveValue(dynamic value) => value == null || value.toString().trim().isEmpty ? 'DATA UNAVAILABLE' : value.toString();
    final atmRow = liveAtm();
    final engine = terminalData?['engine_state'] is Map
        ? Map<String,dynamic>.from(terminalData!['engine_state'] as Map)
        : <String,dynamic>{};

    Widget miniBars() {
      if (liveRows.isEmpty) {
        return const SizedBox(height: 72, child: Center(child: Text('LIVE OPTION/OI DATA WAITING')));
      }
      final values = liveRows.take(16).map((r) {
        final oi = double.tryParse((r['oi'] ?? r['openInterest'] ?? '0').toString()) ?? 0;
        return oi;
      }).toList();
      final maxValue = values.fold<double>(0, (a, v) => v > a ? v : a);
      if (maxValue <= 0) return const SizedBox(height: 72, child: Center(child: Text('LIVE OI VALUES UNAVAILABLE')));
      return SizedBox(
        height: 92,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: List<Widget>.generate(values.length, (i) {
            final h = 18.0 + (values[i] / maxValue) * 68.0;
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Container(
                  height: h,
                  decoration: BoxDecoration(
                    color: (liveRows[i]['type'] ?? 'CE').toString().toUpperCase() == 'PE'
                        ? Colors.red.withValues(alpha: .68)
                        : Colors.green.withValues(alpha: .68),
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                  ),
                ),
              ),
            );
          }),
        ),
      );
    }

    Widget signalRow(String side, String strike, String entry, String sl, String target) => ListTile(
      dense: true,
      leading: CircleAvatar(
        radius: 15,
        child: Text(side, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
      ),
      title: Text('$side  $strike', style: const TextStyle(fontWeight: FontWeight.bold)),
      subtitle: Text('Entry $entry  •  SL $sl  •  T1 $target'),
      trailing: const Icon(Icons.chevron_right),
    );

    final content = <Widget>[
      section('LIVE MARKET SNAPSHOT', Row(children: <Widget>[
        metric('Index LTP', ltp, color: Colors.blue),
        const SizedBox(width: 7),
        metric('Change', pct, color: Colors.green),
        const SizedBox(width: 7),
        metric('Connection', connection, color: Colors.green),
      ])),
      section('REFERENCE LAYOUT', Column(children: <Widget>[
        Row(children: <Widget>[
          Icon(spec['icon'] as IconData, color: accent, size: 28),
          const SizedBox(width: 10),
          Expanded(child: Text(spec['title'] as String, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
        ]),
        const SizedBox(height: 5),
        Text(spec['subtitle'] as String),
      ])),
    ];

    if (index == 18) {
      content.add(section('LAUNCH PANEL', Column(children: <Widget>[
        const Icon(Icons.candlestick_chart, size: 56),
        const SizedBox(height: 8),
        const Text('PARMAR TRADING', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        const Text('Smart Analysis  •  Disciplined Execution  •  AI Powered'),
        const SizedBox(height: 14),
        FilledButton(onPressed: () => setState(() => selected = 0), child: const Text('GET STARTED')),
        const SizedBox(height: 6),
        const Text('Live data only • No order placement'),
      ])));
    } else if (index == 19) {
      content.add(section('BROKER AUTHENTICATION', Column(children: <Widget>[
        infoCard('Angel One', 'Client ID • MPIN • TOTP • API key', Colors.blue),
        infoCard('Backend', backendUrl.isEmpty ? 'Not configured' : backendUrl, Colors.orange),
        FilledButton(onPressed: () => setState(() => selected = 10), child: const Text('OPEN ANGEL API LOGIN')),
      ])));
    } else if (index == 20) {
      content.add(section('INDICES', Column(children: <Widget>[
        ...liveIndices.take(6).map((q) => _quoteCard(q)),
        if (liveIndices.isEmpty) const ListTile(title: Text('Waiting for live index feed')),
      ])));
    } else if (index == 21) {
      content.add(section('OI HEATMAP', Column(children: <Widget>[
        miniBars(),
        const SizedBox(height: 8),
        const Text('Green = CE concentration • Red = PE concentration'),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: const <Widget>[
          Chip(label: Text('Long Buildup')),
          Chip(label: Text('Short Covering')),
          Chip(label: Text('Short Buildup')),
          Chip(label: Text('Long Unwinding')),
        ]),
      ])));
    } else if (index == 22) {
      final ce = liveRows.where((r) => (r['type'] ?? '').toString().toUpperCase() == 'CE').toList();
      final pe = liveRows.where((r) => (r['type'] ?? '').toString().toUpperCase() == 'PE').toList();
      final ceAtm = ce.isNotEmpty ? ce.first : <String,dynamic>{};
      final peAtm = pe.isNotEmpty ? pe.first : <String,dynamic>{};
      final volume = liveRows.fold<num>(0, (sum, r) => sum + (num.tryParse((r['volume'] ?? '0').toString()) ?? 0));
      content.add(section('PREMIUM / VOLUME', Column(children: <Widget>[
        miniBars(),
        Row(children: <Widget>[
          metric('CE Premium', liveValue(ceAtm['ltp'])),
          metric('PE Premium', liveValue(peAtm['ltp'])),
          metric('Volume', liveRows.isEmpty ? 'DATA UNAVAILABLE' : volume.toString()),
        ]),
      ])));
    } else if (index == 23) {
      content.add(section('IV SURFACE', Column(children: <Widget>[
        Row(children: <Widget>[
          metric('ATM IV', liveValue(atmRow?['iv'] ?? atmRow?['impliedVolatility'])),
          metric('Delta', liveValue(atmRow?['delta'])),
          metric('Gamma', liveValue(atmRow?['gamma'])),
        ]),
        Row(children: <Widget>[
          metric('Vega', liveValue(atmRow?['vega'])),
          metric('Theta', liveValue(atmRow?['theta'])),
          metric('PCR', liveValue(strategyData['pcr'] ?? terminalData?['pcr'])),
        ]),
        const SizedBox(height: 8),
        const Text('Values shown only from live backend data; unavailable fields remain DATA UNAVAILABLE.'),
      ])));
    } else if (index == 24) {
      final sig = signal ?? <String,dynamic>{};
      final side = (sig['action'] ?? 'WAIT').toString().toUpperCase().contains('PUT') ? 'PE' : 'CE';
      content.add(section('SIGNAL FLOW', Column(children: <Widget>[
        signalRow(
          side,
          liveValue(sig['strike']),
          liveValue(sig['entry']),
          liveValue(sig['sl'] ?? sig['stopLoss']),
          liveValue(sig['target']),
        ),
        infoCard('Execution', 'Live signal flow is read-only; order placement remains disabled.', Colors.blue),
      ])));
    } else if (index == 25) {
      content.add(section('MARKET REGIME', Column(children: <Widget>[
        Row(children: <Widget>[
          metric('Trend', liveValue(engine['trend'])),
          metric('Volatility', liveValue(engine['volatility'] ?? engine['volatility_state'])),
        ]),
        Row(children: <Widget>[
          metric('Momentum', liveValue(engine['momentum'])),
          metric('Mode', liveValue(engine['mode'] ?? engine['status'])),
        ]),
        miniBars(),
      ])));
    } else if (index == 26) {
      final sig = signal ?? <String,dynamic>{};
      final action = liveValue(sig['action'] ?? engine['signal_status']);
      content.add(section('QUALIFYING TRADE PLANS', Column(children: <Widget>[
        signalRow(
          action.toUpperCase().contains('PUT') ? 'PE' : 'CE',
          liveValue(sig['strike']),
          liveValue(sig['entry']),
          liveValue(sig['sl'] ?? sig['stopLoss']),
          liveValue(sig['target']),
        ),
        infoCard('Signal state', action, action == 'WAIT' ? Colors.orange : Colors.blue),
        const Text('No hard-coded market prices are used.', style: TextStyle(color: Colors.grey)),
      ])));
    } else if (index == 27) {
      content.add(section('STRATEGY PERFORMANCE', Column(children: <Widget>[
        Row(children: <Widget>[
          metric('Win Rate', liveValue(strategyData['win_rate'] ?? strategyData['winRate'])),
          metric('Avg R', liveValue(strategyData['avg_r'] ?? strategyData['avgR'])),
          metric('Trades', liveValue(strategyData['trades'] ?? strategyData['trade_count'])),
        ]),
        const SizedBox(height: 8),
        const Text('Performance is shown only when a live backtest payload is available.', style: TextStyle(color: Colors.grey)),
        FilledButton(onPressed: () => setState(() => selected = 14), child: const Text('OPEN STRATEGIES')),
      ])));
    } else if (index == 28) {
      content.add(section('STRATEGY REGISTRY', Column(children: <Widget>[
        TextField(decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search strategy modules...')),
        const SizedBox(height: 8),
        for (final item in const ['S001 • Long Buildup','S002 • Short Covering','S003 • Short Buildup','S004 • Long Unwinding','S005 • OI Wall'])
          ListTile(
            dense: true,
            title: Text(item),
            subtitle: const Text('OI / Position • validation state'),
            trailing: const Icon(Icons.verified),
          ),
      ])));
    } else {
      content.add(section('6-LAYER AI VALIDATION', Column(children: <Widget>[
        for (final layer in const ['GPT-6 Luna','Claude Sonnet','GPT-5.6 Sol','DeepSeek Chat','Gemini 2.5 Flash','Grok 4'])
          ListTile(
            dense: true,
            leading: const CircleAvatar(child: Icon(Icons.psychology, size: 16)),
            title: Text(layer),
            trailing: const Chip(label: Text('AGREE')),
          ),
        infoCard('Final output', 'WAIT / NO TRADE until live validation is available.', Colors.blue),
      ])));
    }

    return Theme(
      data: Theme.of(context).copyWith(
        scaffoldBackgroundColor: bg,
        cardTheme: Theme.of(context).cardTheme.copyWith(
          margin: const EdgeInsets.symmetric(vertical: 5),
        ),
      ),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
        children: <Widget>[
          Row(children: <Widget>[
            Expanded(child: Text(spec['title'] as String, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold))),
            Chip(label: Text(isDarkVariant ? 'DARK' : 'LIGHT')),
          ]),
          Text(spec['subtitle'] as String),
          const SizedBox(height: 8),
          ...content,
          const SizedBox(height: 8),
          Text(
            'NSE-AI-TERMINAL • Live data from configured backend • UI reference screen',
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .55), fontSize: 11),
          ),
        ],
      ),
    );
  }

  String cleanUrl(String s) {
    s = s.trim();
    if (s.isEmpty) return defaultBackendUrl;
    if (!s.startsWith('http://') && !s.startsWith('https://')) {
      s = 'https://' + s;
    }
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  Uri backendUri(String path) {
    final base = cleanUrl(backendUrl);
    if (base.isEmpty) {
      throw const FormatException(
        'Railway backend URL is not configured. Build the APK with RAILWAY_BACKEND_URL.',
      );
    }
    final uri = Uri.tryParse(base + path);
    final host = uri?.host.toLowerCase() ?? '';
    final isRailwayHost = host == 'railway.app' || host.endsWith('.railway.app');
    if (uri == null || uri.host.isEmpty || uri.scheme != 'https' || !isRailwayHost) {
      throw const FormatException('Only the configured HTTPS Railway backend is allowed.');
    }
    return uri;
  }

  Future<void> openSettings() async {
    final u = TextEditingController(text: backendUrl);
    final k = TextEditingController(text: apiToken);
    await showDialog<void>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Server Settings'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: u,
              decoration: const InputDecoration(labelText: 'Backend URL'),
            ),
            TextField(
              controller: k,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'API token'),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () {
              setState(() {
                backendUrl = cleanUrl(u.text);
                apiToken = k.text.trim();
                liveDataService = LiveDataService(backendUrl, apiToken);
              });
              alertService?.baseUrl = backendUrl;
              alertService?.apiToken = apiToken;
              Navigator.pop(d);
              startLiveConnection();
              fetchTerminal();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    u.dispose();
    k.dispose();
  }

  Widget infoCard(String title,String value,Color color) => Card(child: ListTile(
    leading: Icon(Icons.circle,color:color,size:13), title: Text(title), subtitle: Text(value),
  ));


  Widget row(String label,dynamic value) => Padding(
    padding: const EdgeInsets.symmetric(vertical:4),
    child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: <Widget>[
      Text(label), Flexible(child:Text((value ?? '-').toString(), textAlign:TextAlign.right)),
    ]),
  );
}



// APK build fix: settings dialog and widget-scoped connection UI are syntactically closed.
class AngelApiForm extends StatefulWidget {
  final String backendUrl;
  final String apiToken;
  final String connection;
  final String status;
  final VoidCallback onConnected;
  final ValueChanged<String> onStatus;

  const AngelApiForm({
    super.key,
    required this.backendUrl,
    required this.apiToken,
    required this.connection,
    required this.status,
    required this.onConnected,
    required this.onStatus,
  });

  @override
  State<AngelApiForm> createState() => _AngelApiFormState();
}

class _AngelApiFormState extends State<AngelApiForm> {
  final clientId = TextEditingController();
  final mpin = TextEditingController();
  final totp = TextEditingController();
  final apiKey = TextEditingController();
  bool busy = false;

  @override
  void dispose() {
    clientId.dispose();
    mpin.dispose();
    totp.dispose();
    apiKey.dispose();
    super.dispose();
  }

  Future<void> login() async {
    final c = clientId.text.trim();
    final p = mpin.text.trim();
    final t = totp.text.trim();
    final k = apiKey.text.trim();

    if (c.isEmpty || p.isEmpty || k.isEmpty || !RegExp(r'^\d{6}$').hasMatch(t)) {
      widget.onStatus('Client ID, MPIN, API key and current 6-digit TOTP are required.');
      return;
    }

    setState(() => busy = true);
    widget.onStatus('Connecting to Angel One through secure backend...');

    try {
      final base = widget.backendUrl.trim();
      if (base.isEmpty) {
        widget.onStatus('Railway backend URL is not configured in this APK. Set GitHub variable RAILWAY_BACKEND_URL and rebuild.');
        return;
      }
      final normalized = base.startsWith('http://') || base.startsWith('https://')
          ? base
          : 'https://' + base;
      final normalizedUri = Uri.tryParse(normalized);
      final host = normalizedUri?.host.toLowerCase() ?? '';
      final isRailwayHost = host == 'railway.app' || host.endsWith('.railway.app');
      if (normalizedUri == null || normalizedUri.host.isEmpty || normalizedUri.scheme != 'https' || !isRailwayHost) {
        widget.onStatus('Invalid backend URL. This APK accepts only the configured HTTPS Railway backend.');
        return;
      }
      final loginUri = normalizedUri.replace(path: '/v1/angel/login');
      if (loginUri.host.isEmpty) {
        widget.onStatus('Invalid backend URL. Enter a valid HTTPS backend host in Settings.');
        return;
      }

      final response = await http.post(
        loginUri,
        headers: <String,String>{
          'Content-Type': 'application/json',
          'x-token': widget.apiToken,
        },
        body: jsonEncode(<String,String>{
          'clientId': c,
          'pin': p,
          'totp': t,
          'apiKey': k,
        }),
      ).timeout(const Duration(seconds: 60));

      dynamic decoded;
      try { decoded = jsonDecode(response.body); } catch (_) { decoded = null; }

      if (response.statusCode == 200 &&
          decoded is Map &&
          decoded['connected'] == true) {
        widget.onStatus('CONNECTED • Angel One SmartAPI');
        widget.onConnected();
      } else {
        final detail = decoded is Map ? decoded['detail']?.toString() : null;
        widget.onStatus(detail == null || detail.isEmpty
            ? 'Login failed. Check Client ID, MPIN, TOTP, API key and backend.'
            : detail);
      }
    } catch (e) {
      widget.onStatus('Backend connection failed: ' + e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  InputDecoration field(String label, String hint) => InputDecoration(
    labelText: label,
    hintText: hint,
    border: const OutlineInputBorder(),
  );

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: <Widget>[
      Row(
        children: <Widget>[
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('Angel API', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                SizedBox(height: 4),
                Text('Secure SmartAPI connection'),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(24),
            ),
            child: const Text('LIVE DATA ONLY'),
          ),
        ],
      ),
      const SizedBox(height: 16),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: const <Widget>[
                  Text('BROKER CONNECTION', style: TextStyle(fontWeight: FontWeight.bold)),
                  Text('API'),
                ],
              ),
              const Divider(height: 24),
              TextField(
                controller: clientId,
                autocorrect: false,
                decoration: field('CLIENT ID', 'Enter Angel One Client ID'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: mpin,
                obscureText: true,
                keyboardType: TextInputType.number,
                decoration: field('MPIN', 'Enter 4-digit MPIN'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: totp,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: field('CURRENT TOTP', 'Enter current 6-digit TOTP'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: apiKey,
                obscureText: true,
                autocorrect: false,
                decoration: field('SMARTAPI API KEY', 'Enter SmartAPI API key'),
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).dividerColor),
                ),
                child: Row(
                  children: const <Widget>[
                    Expanded(child: Text('API key is sent only to the configured HTTPS backend during secure login.')),
                    SizedBox(width: 10),
                    Text('MASKED', style: TextStyle(fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: busy ? null : login,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    child: Text(busy ? 'CONNECTING...' : 'SECURE LOGIN'),
                  ),
                ),
              ),
              if (widget.status.isNotEmpty) ...<Widget>[
                const SizedBox(height: 12),
                Text(widget.status),
              ],
              const SizedBox(height: 8),
              Text(
                'Frontend → Secure backend → Angel One SmartAPI',
                style: TextStyle(color: Theme.of(context).colorScheme.primary),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      Card(
        child: ListTile(
          title: const Text('BACKEND CONNECTION'),
          subtitle: Text(widget.backendUrl),
          trailing: Icon(
            widget.connection == 'Connected' ? Icons.check_circle : Icons.cloud_off,
            color: widget.connection == 'Connected' ? Colors.green : Colors.orange,
          ),
        ),
      ),
    ],
  );
}
