import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:file_saver/file_saver.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'signal_alerts.dart';
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
    'Option Chain','News','Market Details','Angel API','NSE','NSE MCP','Strategy 377',
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
  String backendConnectionError = '';
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
  dynamic optionExpiry;
  List<dynamic> liveOIBuild = <dynamic>[];
  List<dynamic> liveNews = <dynamic>[];
  String liveTransport = 'HTTP polling';
  String liveLastUpdated = 'Not updated';
  String selectedChartToken = '99926000';
  String selectedChartExchange = 'NSE';
  String selectedInterval = 'FIVE_MINUTE';
  bool angelDataBusy = false;
  bool optionBusy = false;
  bool oiBusy = false;
  Map<String, dynamic> strategy377Data = <String, dynamic>{};
  Map<String, dynamic> quantData = <String, dynamic>{};
  Map<String, dynamic> aiStatusData = <String, dynamic>{};
  Map<String, dynamic> mcpContextData = <String, dynamic>{};
  Map<String, dynamic> mcpCoreData = <String, dynamic>{};
  Map<String, dynamic> mcpCommodityData = <String, dynamic>{};
  String marketDataError = '';
  String commodityDataError = '';
  String optionDataError = '';
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
  bool pageBusy = false;
  String cacheStatus = 'Cache: live';
  int optionStrikeCount = 15;

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
    timer = Timer.periodic(const Duration(seconds: 5), (_) {
      fetchTerminal();
      if (selected == 6) fetchCandles();
      if (selected == 14) fetchStrategy();
    });
    marketTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      fetchIndices();
      fetchCommodities();
      if (const {4, 7, 20, 21, 22, 23, 24, 25, 26}.contains(selected)) {
        fetchOptionRows();
      }
      if (const {3, 13, 24, 26, 28}.contains(selected)) {
        fetchStrategy377();
      }
      if (selected == 9) {
        fetchAngelMarket();
      }
      if (selected == 25) {
        fetchQuant();
      }
    });
  }
  @override void dispose() {
    timer?.cancel();
    marketTimer?.cancel();
    liveHttpTimer?.cancel();
    liveNewsTimer?.cancel();
    liveSubscription?.cancel();
    liveChannel?.sink.close();
    alertService?.stop();
    liveDataService?.close();
    super.dispose();
  }

  void startLiveConnection() {
    liveDataService?.close();
    backendConnectionError = '';
    liveDataService = LiveDataService(backendUrl, apiToken);
    liveHttpTimer?.cancel();
    liveHttpTimer = Timer.periodic(const Duration(seconds: 10), (_) => fetchLiveSnapshot());
    liveNewsTimer?.cancel();
    liveNewsTimer = Timer.periodic(const Duration(seconds: 60), (_) => fetchNews());
    _connectLiveSocket();
    probeBackendConnection();
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

  Future<void> probeBackendConnection() async {
    try {
      final service = liveDataService;
      if (service == null || backendUrl.isEmpty) return;
      final d = await service.health();
      if (!mounted) return;
      final angel = d['angel_connected'] == true;
      setState(() {
        backendConnectionError = '';
        connection = angel ? 'Connected' : 'Backend connected / Angel not connected';
        angelLoginStatus = (d['angel_message'] ?? '').toString();
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        backendConnectionError = error.toString();
        connection = 'Backend not connected';
      });
    }
  }

  Future<void> fetchLiveSnapshot() async {
    try {
      final service = liveDataService;
      if (service == null || backendUrl.isEmpty) return;
      final d = await service.liveSnapshot();
      applyLiveSnapshot(d);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        backendConnectionError = error.toString();
        connection = 'Backend not connected';
      });
    }
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
      final engine = d['engine_state'];
      if (s is Map<String, dynamic> && s.isNotEmpty) {
        signal = s;
      } else if (engine is Map) {
        signal = <String, dynamic>{
          'action': engine['signal_status'] ?? 'WAIT',
          'underlying': engine['symbol'],
          'optionSymbol': engine['option_symbol'],
          'spot': engine['index_ltp'],
          'ltp': engine['option_ltp'],
          'strike': engine['strike'],
          'entry': engine['entry'],
          'stop_loss': engine['stop_loss'],
          'sl': engine['stop_loss'],
          'target': engine['target'],
          'score': engine['score'],
          'reasons': d['strategy'] is Map
              ? (d['strategy'] as Map)['reasons']
              : <dynamic>[],
        };
      }
      connection = server && angel ? 'Connected' : server ? 'Backend connected / Angel not connected' : 'Backend not connected';
      final m = d['nse_mcp'];
      nseMcpStatus = m is Map && m['connected'] == true ? 'Connected' : 'Not connected';
    });
  }


  Future<void> fetchNews() async {
    try {
      final service = liveDataService;
      if (service == null) return;
      final d = await service.liveNews(query: 'NIFTY India');
      final items = d['items'];
      if (mounted && items is List) {
        setState(() => liveNews = List<dynamic>.from(items));
      }
    } catch (_) {}
  }

  Future<void> fetchTerminal() async {
    try {
      final service = liveDataService;
      if (service == null) return;
      final decoded = await service.terminal();
      if (!mounted) return;

      final conn = decoded['connection'];
      final angel = conn is Map && conn['angel'] == true;
      final server = conn is Map && conn['server'] == true;

      setState(() {
        terminalData = decoded;
        final s = decoded['signals'];
        final engine = decoded['engine_state'];
        final m = decoded['nse_mcp'];
        if (s is Map<String, dynamic> && s.isNotEmpty) {
          signal = s;
        } else if (engine is Map) {
          signal = <String, dynamic>{
            'action': engine['signal_status'] ?? 'WAIT',
            'underlying': engine['symbol'],
            'optionSymbol': engine['option_symbol'],
            'spot': engine['index_ltp'],
            'ltp': engine['option_ltp'],
            'strike': engine['strike'],
            'entry': engine['entry'],
            'stop_loss': engine['stop_loss'],
            'sl': engine['stop_loss'],
            'target': engine['target'],
            'score': engine['score'],
            'reasons': <dynamic>[],
          };
        } else {
          signal = null;
        }
        connection = server && angel
            ? 'Connected'
            : server
                ? 'Backend connected / Angel not connected'
                : 'Backend not connected';
        nseMcpStatus = m is Map && m['connected'] == true
            ? 'Connected'
            : 'Not connected';
        liveLastUpdated = DateTime.now().toLocal().toString().substring(11, 19);
      });
    } catch (_) {
      if (mounted) setState(() => connection = 'Backend not connected');
    }
  }

  Future<void> refreshCurrentPage({bool clearServerCache = false}) async {
    if (pageBusy) return;
    pageBusy = true;
    if (mounted) setState(() => cacheStatus = clearServerCache ? 'Clearing live cache...' : 'Refreshing live data...');
    try {
      final service = liveDataService;
      if (service == null) return;

      if (clearServerCache) {
        await service.clearCache();
        if (mounted) setState(() => cacheStatus = 'Cache cleared • fetching fresh data');
      }

      switch (selected) {
        case 0:
          await Future.wait<void>(<Future<void>>[
            fetchTerminal(),
            fetchIndices(),
            fetchOptionRows(),
          ]);
          break;
        case 1:
          await fetchIndices();
          break;
        case 2:
          await fetchCommodities();
          break;
        case 3:
          await Future.wait<void>([
            fetchTerminal(),
            refreshStrategy(),
            fetchStrategy377(),
          ]);
          break;
        case 4:
          await Future.wait<void>([
            fetchOptionRows(),
            fetchOIBuild(),
            _refreshMcpCore(),
          ]);
          break;
        case 6:
          await fetchCandles();
          break;
        case 7:
          await fetchOptionRows();
          break;
        case 8:
          await fetchNews();
          break;
        case 9:
          await fetchAngelMarket();
          break;
        case 13:
          await fetchStrategy377();
          break;
        case 14:
          await fetchStrategy();
          break;
        case 20:
        case 21:
        case 22:
        case 23:
        case 24:
          await Future.wait<void>([
            fetchTerminal(),
            fetchOptionRows(),
            fetchStrategy377(),
          ]);
          break;
        case 25:
          await Future.wait<void>([
            fetchTerminal(),
            fetchOptionRows(),
            fetchQuant(),
          ]);
          break;
        case 26:
          await Future.wait<void>([
            fetchTerminal(),
            fetchOptionRows(),
            fetchStrategy377(),
          ]);
          break;
        case 27:
          await fetchStrategy377();
          break;
        case 28:
          await fetchStrategy377();
          break;
        case 29:
          await fetchAiProviderStatus(probe: true);
          break;
        default:
          await Future.wait<void>([
            fetchLiveSnapshot(),
            fetchIndices(),
          ]);
      }

      if (mounted) {
        setState(() {
          cacheStatus = clearServerCache ? 'Fresh data loaded • cache reset' : 'Fresh data loaded';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              clearServerCache
                  ? 'Live cache cleared and fresh data fetched.'
                  : 'Live data refreshed.',
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() => cacheStatus = 'Refresh failed');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Refresh failed: $error')),
        );
      }
    } finally {
      pageBusy = false;
    }
  }

  Future<void> showCacheActions() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Wrap(
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text('Refresh current page'),
              subtitle: const Text('Fetch latest Angel One / backend data'),
              onTap: () {
                Navigator.pop(sheetContext);
                refreshCurrentPage();
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_sweep),
              title: const Text('Clear live market cache'),
              subtitle: const Text('Keeps Angel One login/session intact'),
              onTap: () {
                Navigator.pop(sheetContext);
                refreshCurrentPage(clearServerCache: true);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> downloadNseCsv() async {
    if (mounted) setState(() => csvStatus = 'Fetching NSE option chain...');
    try {
      final service = liveDataService;
      if (service == null) {
        throw StateError('Live data service is not initialized.');
      }

      final response = await service.getRaw(
        '/v1/nse/option-chain.csv',
        query: const <String, String>{'symbol': 'NIFTY'},
        timeout: const Duration(seconds: 20),
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw LiveDataException(
          statusCode: response.statusCode,
          path: '/v1/nse/option-chain.csv',
          message: 'NSE CSV unavailable.',
        );
      }

      await FileSaver.instance.saveFile(
        name: 'NIFTY_NSE_option_chain',
        bytes: response.bodyBytes,
        fileExtension: 'csv',
        mimeType: MimeType.csv,
      );

      if (mounted) {
        setState(() => csvStatus = 'NIFTY NSE option-chain CSV saved.');
      }
    } catch (error) {
      if (mounted) {
        setState(() => csvStatus = 'CSV download failed. $error');
      }
    }
  }

  @override Widget build(BuildContext context) => Theme(
    data: ThemeData(useMaterial3: true, brightness: darkMode ? Brightness.dark : Brightness.light),
    child: Scaffold(
    appBar: AppBar(
      title: Text(screens[selected]),
      actions: <Widget>[
        IconButton(
          tooltip: 'Refresh current page',
          onPressed: pageBusy ? null : refreshCurrentPage,
          icon: Icon(pageBusy ? Icons.sync : Icons.refresh),
        ),
        IconButton(
          tooltip: 'Refresh / Clear live cache',
          onPressed: showCacheActions,
          icon: const Icon(Icons.cleaning_services_outlined),
        ),
        IconButton(
          onPressed: () => setState(() => darkMode = !darkMode),
          tooltip: 'Light / Dark mode',
          icon: Icon(darkMode ? Icons.light_mode : Icons.dark_mode),
        ),
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
            onTap: () {
              Navigator.pop(context);
              setState(() => selected = i);
              Future<void>.microtask(refreshCurrentPage);
            },
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
    else if (selected == 13) screen = strategy377Page();
    else if (selected == 14) screen = strategiesPage();
    else if (selected == 15) screen = aiModelsPage();
    else if (selected >= 20 && selected <= 29) screen = liveReferencePage(selected);
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
    const unavailable = "DATA UNAVAILABLE";
    final marketOpen = terminalData?["market_open"] == true;
    final e = terminalData?["engine_state"] is Map
        ? Map<String, dynamic>.from(terminalData!["engine_state"] as Map)
        : <String, dynamic>{};

    String value(dynamic v) {
      if (v == null) return unavailable;
      final text = v.toString().trim();
      return text.isEmpty ? unavailable : text;
    }

    dynamic liveIndex(String query) {
      final needle = query.toUpperCase().replaceAll(" ", "");
      for (final item in liveIndices) {
        if (item is! Map) continue;
        final m = Map<String, dynamic>.from(item);
        final name = value(m["name"] ?? m["symbol"] ?? m["tradingSymbol"])
            .toUpperCase()
            .replaceAll(" ", "");
        if (name.contains(needle) || needle.contains(name)) return m;
      }
      return null;
    }

    final primaryIndex = liveIndex("NIFTY");
    final primaryLtp = primaryIndex is Map
        ? value(primaryIndex["ltp"])
        : value(e["index_ltp"]);
    final primaryChange = primaryIndex is Map
        ? value(primaryIndex["percentChange"] ?? primaryIndex["netChange"])
        : unavailable;
    final primaryChangeNumber = double.tryParse(
      primaryChange.replaceAll("%", "").replaceAll(",", "").trim(),
    );

    final trend = value(e["trend"]);
    final action = value(e["signal_status"]);
    final up = trend.toUpperCase().contains("UP");
    final down = trend.toUpperCase().contains("DOWN");
    final color = !marketOpen
        ? Colors.blue
        : up
            ? Colors.green
            : down
                ? Colors.red
                : Colors.blue;
    final status = value(e["status"]);
    final source = value(e["source"]);
    final angelConnected = terminalData?["connection"] is Map &&
        (terminalData?["connection"] as Map)["angel"] == true;

    return RefreshIndicator(
      onRefresh: () async {
        await Future.wait<void>(<Future<void>>[
          fetchTerminal(),
          fetchIndices(),
        ]);
      },
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        children: <Widget>[
          Card(
            color: color.withValues(alpha: .18),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: color, width: 1.5),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      const Icon(Icons.bolt, size: 30),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          "NSE Algo Signal",
                          style: TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Chip(
                        backgroundColor: color,
                        label: Text(
                          marketOpen ? trend : "MARKET CLOSED",
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "Engine status: $status",
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    "Source: " + source +
                        " • " + (angelConnected ? "Angel One connected" : "Angel One not connected"),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: infoCard("NIFTY LIVE", primaryLtp, Colors.blue),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: infoCard(
                  "CHANGE",
                  primaryChange,
                  primaryChangeNumber != null && primaryChangeNumber < 0
                      ? Colors.red
                      : Colors.green,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      const Expanded(
                        child: Text(
                          "LIVE INDIAN INDICES",
                          style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                        ),
                      ),
                      IconButton(
                        tooltip: "Refresh indices",
                        onPressed: fetchIndices,
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                  const Divider(height: 16),
                  if (liveIndices.isEmpty)
                    const ListTile(
                      dense: true,
                      leading: Icon(Icons.sync),
                      title: Text("Waiting for Angel One index feed"),
                      subtitle: Text("No fabricated market values are shown."),
                    )
                  else
                    ...liveIndices.take(8).map((item) {
                      if (item is! Map) return const SizedBox.shrink();
                      final q = Map<String, dynamic>.from(item);
                      final pct = value(q["percentChange"] ?? q["netChange"]);
                      final pctNumber = double.tryParse(pct.replaceAll("%", "").trim());
                      final qColor = pctNumber == null
                          ? Colors.blue
                          : pctNumber > 0
                              ? Colors.green
                              : pctNumber < 0
                                  ? Colors.red
                                  : Colors.blue;
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          value(q["name"] ?? q["symbol"] ?? q["tradingSymbol"]),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(value(q["exchange"]) + " • " + pct),
                        trailing: Text(
                          value(q["ltp"]),
                          style: TextStyle(
                            color: qColor,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      );
                    }),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    "CURRENT ENGINE STATE",
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const Divider(height: 20),
                  row("Symbol", value(e["symbol"])),
                  row("Index / Underlying LTP", primaryLtp),
                  row("CE / PE", value(e["ce_pe"])),
                  row("Strike Price", value(e["strike"])),
                  row("Option LTP", value(e["option_ltp"])),
                  row("OI", value(e["oi"])),
                  row("OI Change", value(e["oi_change"])),
                  row("Volume", value(e["volume"])),
                  row("ATM", value(e["atm"])),
                  row("Trend", trend),
                  row("Signal Status", action),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    "SIGNAL DETAILS",
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                  row("Option Symbol", value(e["option_symbol"])),
                  row("Entry", value(e["entry"])),
                  row("Stop Loss", value(e["stop_loss"])),
                  row("Target", value(e["target"])),
                  row("Score", value(e["score"])),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          infoCard(
            "Connection",
            connection,
            connection == "Connected" ? Colors.green : Colors.orange,
          ),
          infoCard("Live transport", liveTransport + " • updated " + liveLastUpdated, Colors.blue),
          infoCard("NSE MCP", nseMcpStatus, nseMcpStatus == "Connected" ? Colors.green : Colors.orange),
          infoCard("Mode", "Paper signals only • No order placement.", Colors.blue),
          FilledButton.icon(
            onPressed: fetchTerminal,
            icon: const Icon(Icons.refresh),
            label: const Text("REFRESH LIVE DASHBOARD"),
          ),
        ],
      ),
    );
  }
  Future<void> fetchIndices() async {
    try {
      final service = liveDataService;
      if (service == null) return;
      final d = await service.angelIndices();
      final rows = d['data'];
      if (mounted && rows is List) {
        setState(() => liveIndices = List<dynamic>.from(rows));
      }
    } catch (_) {}
  }

  Future<void> fetchCommodities() async {
    final service = liveDataService;
    if (service == null) return;
    await Future.wait<void>([
      () async {
        try {
          final d = await service.mcpCommodities();
          final rows = d['rows'];
          if (mounted && rows is List && rows.isNotEmpty) {
            setState(() => mcpCommodityData = d);
          }
        } catch (_) {}
      }(),
      () async {
        try {
          final d = await service.angelCommodities();
          final data = d['data'];
          final rows = data is Map ? data['fetched'] : null;
          if (mounted && rows is List) {
            setState(() {
              liveCommodities = List<dynamic>.from(rows);
              commodityDataError = '';
            });
          }
        } catch (e) {
          if (mounted) setState(() => commodityDataError = e.toString());
        }
      }(),
    ]);
  }

  Future<void> fetchAngelMarket() async {
    final service = liveDataService;
    if (service == null) return;
    await Future.wait<void>([
      () async {
        try {
          final d = await service.angelMarket();
          final data = d['data'];
          final rows = data is Map ? data['fetched'] : null;
          if (mounted && rows is List) {
            setState(() {
              liveMarket = List<dynamic>.from(rows);
              marketDataError = '';
            });
          }
        } catch (e) {
          if (mounted) setState(() => marketDataError = e.toString());
        }
      }(),
      () async {
        try {
          final d = await service.mcpContext(index: selectedOptionSymbol);
          if (mounted) setState(() => mcpContextData = d);
        } catch (e) {
          if (mounted) setState(() => mcpContextData = <String,dynamic>{
            'connected': false,
            'error': e.toString(),
          });
        }
      }(),
      () async {
        try {
          final d = await service.mcpMarketCore(symbol: selectedOptionSymbol);
          if (mounted) setState(() => mcpCoreData = d);
        } catch (_) {}
      }(),
    ]);
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
    if (chartBusy) return;
    chartBusy = true;
    if (mounted) setState(() => angelDataBusy = true);

    try {
      final service = liveDataService;
      if (service == null) return;
      final d = await service.angelCandles(
        exchange: selectedChartExchange,
        token: selectedChartToken,
        interval: selectedInterval,
        days: 1,
      );
      final rows = d['data'];
      if (mounted && rows is List) {
        setState(() => liveCandles = List<dynamic>.from(rows));
        await pushProChartData();
      }
    } catch (_) {
      // UI keeps the last known candle set instead of flashing fake data.
    } finally {
      chartBusy = false;
      if (mounted) setState(() => angelDataBusy = false);
    }
  }

  Future<void> fetchOptionRows() async {
    if (optionBusy) return;
    optionBusy = true;
    if (mounted) setState(() => angelDataBusy = true);
    final service = liveDataService;
    if (service == null) {
      optionBusy = false;
      return;
    }
    try {
      final mcpFuture = service
          .mcpOptionChain(
            symbol: selectedOptionSymbol,
            expiry: optionExpiry?.toString(),
          )
          .then<void>((mcp) {
            if (!mounted) return;
            setState(() {
              mcpContextData = <String, dynamic>{
                ...mcpContextData,
                'option_chain': mcp,
              };
            });
          })
          .catchError((Object _) {});

      final d = await service.optionChain(
        symbol: selectedOptionSymbol,
        count: optionStrikeCount,
      );
      final rows = d['rows'];
      if (mounted) {
        setState(() {
          liveOptionRows =
              rows is List ? List<dynamic>.from(rows) : <dynamic>[];
          optionSpot = d['spot'];
          optionExpiry = d['expiry'];
          optionDataError = liveOptionRows.isEmpty
              ? 'Angel One returned no option rows.'
              : '';
          final cached = d['cached'] == true;
          final age = d['cache_age_sec'];
          cacheStatus = cached
              ? 'Server cache • ' + (age?.toString() ?? '-') + 's old'
              : 'Live Angel One snapshot';
        });
      }
      await mcpFuture;
    } catch (e) {
      if (mounted) setState(() => optionDataError = e.toString());
    } finally {
      optionBusy = false;
      if (mounted) setState(() => angelDataBusy = false);
    }
  }

  Future<void> fetchOIBuild() async {
    if (oiBusy) return;
    oiBusy = true;
    if (mounted) setState(() => angelDataBusy = true);
    try {
      final service = liveDataService;
      if (service == null) return;
      final d = await service.oiBuildup();
      final rows = d['data'];
      if (mounted && rows is List) {
        setState(() => liveOIBuild = List<dynamic>.from(rows));
      }
    } catch (_) {
      // Preserve the last good OI snapshot.
    } finally {
      oiBusy = false;
      if (mounted) setState(() => angelDataBusy = false);
    }
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

  Widget commodityPage() => RefreshIndicator(
        onRefresh: () => refreshCurrentPage(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(12),
          children: <Widget>[
            Row(children: <Widget>[
              const Expanded(child: Text('Commodity • MCX', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold))),
              IconButton(onPressed: pageBusy ? null : refreshCurrentPage, icon: const Icon(Icons.refresh)),
            ]),
            infoCard('LIVE SOURCE', 'Angel One SmartAPI + local MCP shared MCX store', Colors.blue),
            if (mcpCommodityData['data_ok'] == true)
              infoCard('MCP', 'Shared commodity snapshot • ' + (mcpCommodityData['age_s']?.toString() ?? '-') + 's old', Colors.green),
            if (commodityDataError.isNotEmpty)
              infoCard('FETCH ERROR', commodityDataError, Colors.red),
            ...liveCommodities.map((q) => Card(
              child: ListTile(
                title: Text((q['tradingSymbol'] ?? q['name'] ?? '-').toString()),
                subtitle: Text(
                  'Expiry ' + (q['expiry'] ?? '-').toString() +
                  ' • OI ' + (q['oi'] ?? '-').toString() +
                  ' • Vol ' + (q['volume'] ?? '-').toString(),
                ),
                trailing: Text((q['ltp'] ?? '-').toString(),
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              ),
            )),
            if (liveCommodities.isEmpty)
              infoCard('MCX', 'No live commodity quote received yet. Check Angel One session.', Colors.orange),
            FilledButton.icon(
              onPressed: pageBusy ? null : refreshCurrentPage,
              icon: const Icon(Icons.refresh),
              label: const Text('REFRESH MCX'),
            ),
          ],
        ),
      );

  Widget oiLabPage() {
    num ceOI = 0;
    num peOI = 0;
    num ceUp = 0;
    num peUp = 0;
    num ceDown = 0;
    num peDown = 0;

    for (final raw in liveOptionRows) {
      if (raw is! Map) continue;
      final r = Map<String, dynamic>.from(raw);
      final oi = num.tryParse((r["oi"] ?? "0").toString()) ?? 0;
      final ch = num.tryParse((r["oiChangePct"] ?? r["oi_change"] ?? "0").toString()) ?? 0;
      final side = (r["type"] ?? "").toString().toUpperCase();
      if (side == "CE") {
        ceOI += oi;
        if (ch > 0) ceUp++;
        if (ch < 0) ceDown++;
      } else if (side == "PE") {
        peOI += oi;
        if (ch > 0) peUp++;
        if (ch < 0) peDown++;
      }
    }

    final pcr = ceOI > 0 ? peOI / ceOI : null;

    return RefreshIndicator(
      onRefresh: () => refreshCurrentPage(),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        children: <Widget>[
          Row(
            children: <Widget>[
              const Expanded(
                child: Text("OI LAB • LIVE", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              ),
              IconButton(
                tooltip: "Refresh OI",
                onPressed: pageBusy ? null : refreshCurrentPage,
                icon: const Icon(Icons.refresh),
              ),
              IconButton(
                tooltip: "Clear OI cache",
                onPressed: pageBusy ? null : () => refreshCurrentPage(clearServerCache: true),
                icon: const Icon(Icons.delete_sweep),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text("Angel One SmartAPI • live index option OI", style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              for (final sym in const <String>["NIFTY","BANKNIFTY","FINNIFTY","MIDCPNIFTY","SENSEX","BANKEX"])
                ChoiceChip(
                  label: Text(sym),
                  selected: selectedOptionSymbol == sym,
                  onSelected: (selected) {
                    if (!selected) return;
                    setState(() => selectedOptionSymbol = sym);
                    refreshCurrentPage(clearServerCache: true);
                  },
                ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(child: infoCard("CALL OI", ceOI.toStringAsFixed(0), Colors.green)),
              const SizedBox(width: 8),
              Expanded(child: infoCard("PUT OI", peOI.toStringAsFixed(0), Colors.red)),
              const SizedBox(width: 8),
              Expanded(
                child: infoCard(
                  "PCR",
                  pcr == null ? "DATA UNAVAILABLE" : pcr.toStringAsFixed(3),
                  Colors.purple,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(child: infoCard("CE ↑ / ↓", ceUp.toString() + " / " + ceDown.toString(), Colors.green)),
              const SizedBox(width: 8),
              Expanded(child: infoCard("PE ↑ / ↓", peUp.toString() + " / " + peDown.toString(), Colors.red)),
            ],
          ),
          const SizedBox(height: 10),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    "OI BUILDUP FEED",
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  if (liveOIBuild.isEmpty)
                    const Text("No OI buildup rows returned yet.")
                  else
                    ...liveOIBuild.take(8).map((raw) {
                      final m = raw is Map
                          ? Map<String, dynamic>.from(raw)
                          : <String, dynamic>{};
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          (m["tradingSymbol"] ?? m["symbol"] ?? "-").toString(),
                        ),
                        subtitle: Text(
                          "LTP " + (m["ltp"] ?? "-").toString() +
                          " • OI " + (m["opnInterest"] ?? m["oi"] ?? "-").toString() +
                          " • OI Δ " + (m["netChangeOpnInterest"] ?? m["oi_change"] ?? "-").toString(),
                        ),
                      );
                    }),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          const SizedBox(height: 10),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text("TOP OI WALLS", style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  ..._topOiRows(),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          infoCard(
            "MCP STORE",
            mcpCoreData["data_ok"] == true
                ? "Live • " + (mcpCoreData["age_s"] ?? "-").toString() + "s old"
                : "No fresh shared MCP snapshot",
            mcpCoreData["data_ok"] == true ? Colors.green : Colors.orange,
          ),
          infoCard("CACHE", cacheStatus, Colors.blue),
          FilledButton.icon(
            onPressed: pageBusy ? null : () => refreshCurrentPage(clearServerCache: true),
            icon: const Icon(Icons.delete_sweep),
            label: const Text("CLEAR CACHE + REFRESH OI"),
          ),
        ],
      ),
    );
  }

  List<Widget> _topOiRows() {
    final rows = liveOptionRows
        .whereType<Map>()
        .map((x) => Map<String, dynamic>.from(x))
        .toList()
      ..sort(
        (a, b) => (double.tryParse((b["oi"] ?? "0").toString()) ?? 0)
            .compareTo(double.tryParse((a["oi"] ?? "0").toString()) ?? 0),
      );

    return rows.take(10).map((r) {
      final side = (r["type"] ?? "").toString().toUpperCase();
      final color = side == "CE" ? Colors.green : Colors.red;
      return ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: CircleAvatar(
          radius: 15,
          child: Text(side == "CE" ? "C" : "P"),
        ),
        title: Text((r["strike"] ?? "-").toString() + " • " + (r["symbol"] ?? "-").toString()),
        subtitle: Text(
          "LTP " + (r["ltp"] ?? "-").toString() +
              " • OI " + (r["oi"] ?? "-").toString() +
              " • OI Δ " + (r["oiChangePct"] ?? r["oi_change"] ?? "-").toString(),
        ),
        trailing: Text(side, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
      );
    }).toList();
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

  Widget optionChain() {
    final spot = double.tryParse((optionSpot ?? "").toString());

    return RefreshIndicator(
      onRefresh: () => refreshCurrentPage(),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(8),
        children: <Widget>[
          Row(
            children: <Widget>[
              const Expanded(
                child: Text("OPTION CHAIN • PRO", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              ),
              IconButton(
                tooltip: "Refresh chain",
                onPressed: pageBusy ? null : refreshCurrentPage,
                icon: Icon(pageBusy ? Icons.sync : Icons.refresh),
              ),
              IconButton(
                tooltip: "Clear chain cache",
                onPressed: pageBusy ? null : () => refreshCurrentPage(clearServerCache: true),
                icon: const Icon(Icons.delete_sweep),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: <Widget>[
                for (final sym in const <String>["NIFTY","BANKNIFTY","FINNIFTY","MIDCPNIFTY","SENSEX","BANKEX"])
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(sym),
                      selected: selectedOptionSymbol == sym,
                      onSelected: (selected) {
                        if (!selected) return;
                        setState(() => selectedOptionSymbol = sym);
                        refreshCurrentPage(clearServerCache: true);
                      },
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(child: _chainMetric("SPOT", optionSpot)),
                      Expanded(child: _chainMetric("ATM", optionSpot)),
                      Expanded(child: _chainMetric("EXPIRY", optionExpiry)),
                      Expanded(child: _chainMetric("ROWS", liveOptionRows.length)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: <Widget>[
                      const Text("STRIKES"),
                      const SizedBox(width: 8),
                      for (final count in const <int>[7, 15, 25])
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ChoiceChip(
                            label: Text("±" + count.toString()),
                            selected: optionStrikeCount == count,
                            onSelected: (selected) {
                              if (!selected) return;
                              setState(() => optionStrikeCount = count);
                              refreshCurrentPage();
                            },
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(cacheStatus, style: const TextStyle(fontSize: 11)),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (optionDataError.isNotEmpty)
            infoCard("OPTION FETCH", optionDataError, Colors.red),
          finalOptionMcpCard(),
          if (liveOptionRows.isEmpty)
            infoCard(
              "OPTION CHAIN",
              "No live rows received. Check Angel One session and refresh.",
              Colors.orange,
            )
          else
            _proOptionTable(spot),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: FilledButton.icon(
                  onPressed: pageBusy ? null : refreshCurrentPage,
                  icon: const Icon(Icons.refresh),
                  label: const Text("REFRESH"),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: pageBusy ? null : () => refreshCurrentPage(clearServerCache: true),
                  icon: const Icon(Icons.delete_sweep),
                  label: const Text("CLEAR CACHE"),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget finalOptionMcpCard() {
    final optionMcp = mcpContextData['option_chain'];
    if (optionMcp is! Map) {
      return infoCard("NSE MCP", "Option-chain MCP status not checked yet.", Colors.blue);
    }
    final available = optionMcp['available'] == true;
    return infoCard(
      "NSE MCP OPTION CHAIN",
      available
          ? "Available • tool " + (optionMcp['tool'] ?? '-').toString()
          : "Official MCP has no usable option-chain tool • Angel One remains primary",
      available ? Colors.green : Colors.orange,
    );
  }

  Widget _chainMetric(String label, dynamic value) {
    final text = value == null || value.toString().trim().isEmpty
        ? "DATA UNAVAILABLE"
        : value.toString();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: const TextStyle(fontSize: 10)),
          const SizedBox(height: 2),
          Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _proOptionTable(double? spot) {
    final byStrike = <double, Map<String, dynamic>>{};
    for (final raw in liveOptionRows) {
      if (raw is! Map) continue;
      final row = Map<String, dynamic>.from(raw);
      final strike = double.tryParse((row["strike"] ?? "").toString());
      if (strike == null) continue;
      byStrike.putIfAbsent(strike, () => <String, dynamic>{})
        [(row["type"] ?? "").toString().toUpperCase()] = row;
    }

    final strikes = byStrike.keys.toList()..sort();

    String read(dynamic row, String key) {
      if (row is! Map) return "-";
      final value = row[key];
      return value == null || value.toString().trim().isEmpty ? "-" : value.toString();
    }

    String change(dynamic row) {
      final direct = read(row, "priceChange");
      return direct == "-" ? read(row, "netChange") : direct;
    }

    DataCell numberCell(dynamic row, String key, {Color? color}) => DataCell(
      Text(read(row, key), style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );

    return Card(
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columnSpacing: 14,
          headingRowHeight: 44,
          dataRowMinHeight: 50,
          dataRowMaxHeight: 58,
          columns: const <DataColumn>[
            DataColumn(label: Text("CE LTP")),
            DataColumn(label: Text("CE OI")),
            DataColumn(label: Text("CE IV")),
            DataColumn(label: Text("CE Δ")),
            DataColumn(label: Text("CE Γ")),
            DataColumn(label: Text("STRIKE")),
            DataColumn(label: Text("PE LTP")),
            DataColumn(label: Text("PE OI")),
            DataColumn(label: Text("PE IV")),
            DataColumn(label: Text("PE Δ")),
            DataColumn(label: Text("PE Γ")),
          ],
          rows: strikes.map((strike) {
            final bucket = byStrike[strike]!;
            final ce = bucket["CE"];
            final pe = bucket["PE"];
            final isAtm = spot != null && (strike - spot).abs() <= 20;
            final ceCh = double.tryParse(change(ce));
            final peCh = double.tryParse(change(pe));
            return DataRow(
              color: isAtm
                  ? MaterialStatePropertyAll<Color?>(Colors.amber.withValues(alpha: .10))
                  : null,
              cells: <DataCell>[
                numberCell(ce, "ltp", color: Colors.green),
                numberCell(ce, "oi"),
                numberCell(ce, "iv"),
                numberCell(ce, "delta", color: Colors.green),
                numberCell(ce, "gamma", color: Colors.green),
                DataCell(
                  Text(
                    isAtm ? "ATM " + strike.toStringAsFixed(0) : strike.toStringAsFixed(0),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: isAtm ? Colors.amber.shade700 : null,
                    ),
                  ),
                ),
                numberCell(pe, "ltp", color: Colors.red),
                numberCell(pe, "oi"),
                numberCell(pe, "iv"),
                numberCell(pe, "delta", color: Colors.red),
                numberCell(pe, "gamma", color: Colors.red),
              ],
            );
          }).toList(),
        ),
      ),
    );
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

  Widget marketDetailsPage() {
    String v(dynamic x) => x == null || x.toString().trim().isEmpty ? "DATA UNAVAILABLE" : x.toString();
    return RefreshIndicator(
      onRefresh: () => refreshCurrentPage(),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        children: <Widget>[
          Row(children: <Widget>[
            const Expanded(child: Text("MARKET DETAILS • PRO", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold))),
            IconButton(onPressed: pageBusy ? null : refreshCurrentPage, icon: const Icon(Icons.refresh)),
          ]),
          infoCard("LIVE SOURCE", "Angel One SmartAPI • NSE/BSE index quote feed", Colors.blue),
          if (liveMarket.isEmpty)
            infoCard("STATUS", "No live quote rows received. Connect Angel One and refresh.", Colors.orange),
          ...liveMarket.whereType<Map>().map((raw) {
            final q = Map<String, dynamic>.from(raw);
            final ch = double.tryParse(v(q["netChange"])) ?? 0;
            final color = ch > 0 ? Colors.green : ch < 0 ? Colors.red : Colors.blue;
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(13),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                  Row(children: <Widget>[
                    Expanded(child: Text(v(q["tradingSymbol"] ?? q["name"] ?? q["symbol"]), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold))),
                    Text(v(q["ltp"]), style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: color)),
                  ]),
                  const SizedBox(height: 8),
                  Row(children: <Widget>[
                    Expanded(child: _detailMetric("OPEN", v(q["open"]))),
                    Expanded(child: _detailMetric("HIGH", v(q["high"]))),
                    Expanded(child: _detailMetric("LOW", v(q["low"]))),
                    Expanded(child: _detailMetric("CHANGE", v(q["netChange"] ?? q["percentChange"]))),
                  ]),
                ]),
              ),
            );
          }),
          const SizedBox(height: 8),
          if (marketDataError.isNotEmpty)
            infoCard("FETCH ERROR", marketDataError, Colors.red),
          infoCard(
            "NSE MCP",
            mcpContextData['connected'] == true
                ? "Connected • " + (mcpContextData['data'] is List ? (mcpContextData['data'] as List).length.toString() : "0") + " live tool responses"
                : "MCP unavailable • " + (mcpContextData['error'] ?? "not checked").toString(),
            mcpContextData['connected'] == true ? Colors.green : Colors.orange,
          ),
          infoCard("TRANSPORT", liveTransport + " • " + liveLastUpdated, Colors.blue),
        ],
      ),
    );
  }

  Widget _detailMetric(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text(label, style: const TextStyle(fontSize: 9)),
          const SizedBox(height: 2),
          Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold)),
        ]),
      );
  Map<String,dynamic>? strategyRefresh;
  Future<void> refreshStrategy() async {
    try {
      final service = liveDataService;
      if (service == null) return;
      final d = await service.strategyRefresh();
      if (mounted) setState(() => strategyRefresh = d);
    } catch (_) {}
  }
  Widget signals() {
    final rawAction = signal?["action"]?.toString() ??
        signal?["signal_status"]?.toString() ?? "WAIT";
    final action = rawAction.replaceAll("_", " ").toUpperCase();
    final wait = action == "WAIT" || action == "NO QUALIFYING TRADE";
    final color = wait ? Colors.orange : Colors.green;
    final underlying = (signal?["underlying"] ??
            signal?["index"] ??
            signal?["indexName"] ??
            selectedOptionSymbol)
        .toString();
    final optionSymbol = (signal?["optionSymbol"] ??
            signal?["option_symbol"] ??
            signal?["tradingSymbol"] ??
            signal?["symbol"] ??
            "DATA UNAVAILABLE")
        .toString();
    final spot = signal?["spot"] ?? signal?["index_ltp"] ?? "DATA UNAVAILABLE";
    final ltp = signal?["ltp"] ?? signal?["option_ltp"] ?? "DATA UNAVAILABLE";
    final strike = signal?["strike"] ?? "DATA UNAVAILABLE";
    final entry = signal?["entry"] ?? "DATA UNAVAILABLE";
    final sl = signal?["sl"] ?? signal?["stop_loss"] ?? "DATA UNAVAILABLE";
    final target = signal?["target"] ?? "DATA UNAVAILABLE";
    final score = signal?["score"] ?? "DATA UNAVAILABLE";
    final reasonsRaw = signal?["reasons"];
    final reasons = reasonsRaw is List
        ? reasonsRaw.map((e) => e.toString()).where((e) => e.trim().isNotEmpty).toList()
        : <String>[];

    return RefreshIndicator(
      onRefresh: () => refreshCurrentPage(),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        children: <Widget>[
          Row(
            children: <Widget>[
              const Expanded(
                child: Text(
                  "SIGNALS • LIVE ENGINE",
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
              ),
              IconButton(
                tooltip: "Refresh signal",
                onPressed: pageBusy ? null : refreshCurrentPage,
                icon: Icon(pageBusy ? Icons.sync : Icons.refresh),
              ),
              IconButton(
                tooltip: "Clear signal cache",
                onPressed: pageBusy
                    ? null
                    : () => refreshCurrentPage(clearServerCache: true),
                icon: const Icon(Icons.delete_sweep),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Card(
            color: color.withValues(alpha: .12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: color, width: 1.4),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(
                        wait ? Icons.pause_circle_outline : Icons.bolt,
                        color: color,
                        size: 34,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          action,
                          style: TextStyle(
                            fontSize: 27,
                            fontWeight: FontWeight.w800,
                            color: color,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    "Angel One SmartAPI • paper signals only",
                    style: TextStyle(fontSize: 12),
                  ),
                  const Divider(height: 22),
                  Row(
                    children: <Widget>[
                      Expanded(child: infoCard("INDEX", underlying, Colors.blue)),
                      const SizedBox(width: 8),
                      Expanded(child: infoCard("SPOT", spot, Colors.blue)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  row("Option Symbol", optionSymbol),
                  row("LTP", ltp),
                  row("Strike", strike),
                  row("Entry", entry),
                  row("Stop Loss", sl),
                  row("Target", target),
                  row("Score", score),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    "ENGINE RESPONSE",
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  if (reasons.isEmpty)
                    Text(
                      wait
                          ? "No qualifying live signal response yet."
                          : "Signal received; no explanation list returned.",
                    )
                  else
                    ...reasons.map(
                      (reason) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            const Text("• "),
                            Expanded(child: Text(reason)),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          infoCard(
            "LIVE STATUS",
            connection + " • " + liveTransport + " • " + liveLastUpdated,
            connection == "Connected" ? Colors.green : Colors.orange,
          ),
          FilledButton.icon(
            onPressed: pageBusy ? null : refreshCurrentPage,
            icon: const Icon(Icons.refresh),
            label: const Text("REFRESH LIVE SIGNAL"),
          ),
        ],
      ),
    );
  }
  Future<void> _refreshMcpCore() async {
    final service = liveDataService;
    if (service == null) return;
    try {
      final d = await service.mcpMarketCore(symbol: selectedOptionSymbol);
      if (mounted) setState(() => mcpCoreData = d);
    } catch (_) {}
  }

  Future<void> fetchStrategy377() async {
    try {
      final service = liveDataService;
      if (service == null) return;
      final d = await service.strategy377();
      if (mounted) setState(() => strategy377Data = d);
    } catch (_) {
      if (mounted) {
        setState(() => strategy377Data = <String, dynamic>{
          "error": "Strategy 377 live payload unavailable."
        });
      }
    }
  }

  Future<void> fetchQuant() async {
    try {
      final service = liveDataService;
      if (service == null) return;
      final d = await service.quantLive(index: selectedOptionSymbol);
      if (mounted) setState(() => quantData = d);
    } catch (_) {}
  }

  Future<void> fetchAiProviderStatus({bool probe = false}) async {
    try {
      final service = liveDataService;
      if (service == null) return;
      final d = await service.aiProviderStatus(probe: probe);
      if (mounted) setState(() => aiStatusData = d);
    } catch (_) {}
  }

  Future<void> fetchStrategy() async {
    if (strategyBusy) return;
    strategyBusy = true;
    try {
      final service = liveDataService;
      if (service == null) return;
      final d = await service.strategyRefresh(index: selectedOptionSymbol);
      if (mounted) setState(() => strategyData = d);
    } catch (_) {
      // Preserve the last known strategy snapshot during transient failures.
    } finally {
      strategyBusy = false;
    }
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
    infoCard('Backend diagnostic',backendConnectionError.isEmpty ? 'Reachability OK' : backendConnectionError, backendConnectionError.isEmpty ? Colors.green : Colors.red),
    FilledButton.icon(onPressed: probeBackendConnection, icon: const Icon(Icons.network_check), label: const Text('Test backend now')),
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

  Widget dataPage(String title) => ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Text(title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          infoCard(
            'Live data status',
            connection == 'Connected'
                ? 'Backend connected. Use the page-specific live module for this data stream.'
                : 'Backend not connected. No fabricated market values are shown.',
            connection == 'Connected' ? Colors.green : Colors.orange,
          ),
          const SizedBox(height: 10),
          infoCard(
            'Source',
            'Server-side Angel One / NSE adapter',
            Colors.blue,
          ),
        ],
      );

  String backendProvider() {
    final host = Uri.tryParse(cleanUrl(backendUrl))?.host.toLowerCase() ?? '';
    if (host == 'railway.app' || host.endsWith('.railway.app')) return 'Railway';
    if (host.isEmpty) return 'Railway URL not configured';
    return 'Invalid backend';
  }

  Widget strategy377Page() {
    final strategy = strategy377Data["strategy"] is Map
        ? Map<String, dynamic>.from(strategy377Data["strategy"] as Map)
        : <String, dynamic>{};
    final state = strategy377Data["state"] is Map
        ? Map<String, dynamic>.from(strategy377Data["state"] as Map)
        : <String, dynamic>{};
    final evaluation = strategy377Data["evaluation"] is Map
        ? Map<String, dynamic>.from(strategy377Data["evaluation"] as Map)
        : <String, dynamic>{};
    final decision = (evaluation["decision"] ?? "WAIT").toString();
    final decisionColor = decision == "CALL BUY"
        ? Colors.green
        : decision == "PUT BUY"
            ? Colors.red
            : Colors.orange;
    return RefreshIndicator(
      onRefresh: () => refreshCurrentPage(),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        children: <Widget>[
          Row(children: <Widget>[
            const Expanded(child: Text("STRATEGY 377", style: TextStyle(fontSize: 25, fontWeight: FontWeight.bold))),
            IconButton(onPressed: pageBusy ? null : refreshCurrentPage, icon: const Icon(Icons.refresh)),
            IconButton(onPressed: pageBusy ? null : () => refreshCurrentPage(clearServerCache: true), icon: const Icon(Icons.delete_sweep)),
          ]),
          Card(
            color: decisionColor.withValues(alpha: .12),
            child: Padding(
              padding: const EdgeInsets.all(15),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                Row(children: <Widget>[
                  const Icon(Icons.rule, size: 30), const SizedBox(width: 10),
                  Expanded(child: Text(strategy["name"]?.toString() ?? "Strategy 377", style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
                  Chip(label: Text(decision, style: TextStyle(color: decisionColor))),
                ]),
                const SizedBox(height: 10),
                Row(children: <Widget>[
                  Expanded(child: _detailMetric("INDEX", strategy["index"]?.toString() ?? "NIFTY")),
                  Expanded(child: _detailMetric("TF", strategy["tf"]?.toString() ?? "5m")),
                  Expanded(child: _detailMetric("VERSION", strategy["version"]?.toString() ?? "377.1")),
                ]),
              ]),
            ),
          ),
          Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            const Text("ENTRY RULES", style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text("CALL: ${(strategy["entry_call"] as List?)?.join(" • ") ?? "DATA UNAVAILABLE"}"),
            const SizedBox(height: 5),
            Text("PUT: ${(strategy["entry_put"] as List?)?.join(" • ") ?? "DATA UNAVAILABLE"}"),
            const SizedBox(height: 5),
            Text("BLOCK: ${(strategy["block_if"] as List?)?.join(" • ") ?? "DATA UNAVAILABLE"}"),
            const SizedBox(height: 5),
            Text("TIME: ${strategy["time_filter"] ?? "DATA UNAVAILABLE"} • SL ${strategy["sl"] ?? "DATA UNAVAILABLE"} • TARGET ${strategy["target"] ?? "DATA UNAVAILABLE"}"),
          ]))),
          const SizedBox(height: 8),
          Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            const Text("LIVE CONDITIONS", style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            ...state.entries.map((e) => row(e.key, e.value)),
          ]))),
          const SizedBox(height: 8),
          infoCard("ENGINE", "Deterministic strategy evaluation • paper only • no order placement", Colors.blue),
          FilledButton.icon(onPressed: pageBusy ? null : refreshCurrentPage, icon: const Icon(Icons.refresh), label: const Text("REFRESH STRATEGY 377")),
        ],
      ),
    );
  }

  Widget liveReferencePage(int index) {
    String val(dynamic x) => x == null || x.toString().trim().isEmpty ? "DATA UNAVAILABLE" : x.toString();
    final rows = liveOptionRows.whereType<Map>().map((x) => Map<String, dynamic>.from(x)).toList();
    final engine = terminalData?["engine_state"] is Map
        ? Map<String, dynamic>.from(terminalData!["engine_state"] as Map)
        : <String, dynamic>{};
    final nse = terminalData?["nse"] is Map
        ? Map<String, dynamic>.from(terminalData!["nse"] as Map)
        : <String, dynamic>{};
    final computed = quantData["computed"] is Map
        ? Map<String, dynamic>.from(quantData["computed"] as Map)
        : <String, dynamic>{};
    final stratEval = strategy377Data["evaluation"] is Map
        ? Map<String, dynamic>.from(strategy377Data["evaluation"] as Map)
        : <String, dynamic>{};
    final strategy = strategy377Data["strategy"] is Map
        ? Map<String, dynamic>.from(strategy377Data["strategy"] as Map)
        : <String, dynamic>{};

    Map<String, dynamic>? nearest(String side) {
      if (rows.isEmpty) return null;
      final spot = double.tryParse((optionSpot ?? "").toString());
      final candidates = rows.where((r) => (r["type"] ?? "").toString().toUpperCase() == side).toList();
      if (candidates.isEmpty) return null;
      candidates.sort((a, b) {
        final ak = double.tryParse((a["strike"] ?? "").toString()) ?? 0;
        final bk = double.tryParse((b["strike"] ?? "").toString()) ?? 0;
        return spot == null ? 0 : (ak - spot).abs().compareTo((bk - spot).abs());
      });
      return candidates.first;
    }

    final ceAtm = nearest("CE");
    final peAtm = nearest("PE");
    final titleMap = <int, String>{20:"MARKET OVERVIEW",21:"OI HEATMAP",22:"PREMIUM / VOLUME",23:"GREEKS / IV SURFACE",24:"SIGNAL FLOW",25:"MARKET REGIME",26:"TRADE PLANS (S+)",27:"BACKTEST",28:"STRATEGY REGISTRY",29:"AI 6-LAYER PANEL"};
    final title = titleMap[index] ?? "LIVE MODULE";

    Widget proHeader() => Row(children: <Widget>[
      Expanded(child: Text(title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold))),
      IconButton(onPressed: pageBusy ? null : refreshCurrentPage, icon: const Icon(Icons.refresh)),
      IconButton(onPressed: pageBusy ? null : () => refreshCurrentPage(clearServerCache: true), icon: const Icon(Icons.delete_sweep)),
    ]);

    Widget chipIndexSelector() => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: <Widget>[
        for (final sym in const <String>["NIFTY","BANKNIFTY","FINNIFTY","MIDCPNIFTY","SENSEX","BANKEX"])
          Padding(padding: const EdgeInsets.only(right: 6), child: ChoiceChip(
            label: Text(sym), selected: selectedOptionSymbol == sym, onSelected: (ok) {
              if (!ok) return;
              setState(() => selectedOptionSymbol = sym);
              refreshCurrentPage(clearServerCache: true);
            },
          )),
      ]),
    );

    Widget marketOverview() => Column(children: <Widget>[
      chipIndexSelector(), const SizedBox(height: 8),
      Row(children: <Widget>[
        Expanded(child: infoCard("ANGEL", connection == "Connected" ? "CONNECTED" : "CHECK CONNECTION", connection == "Connected" ? Colors.green : Colors.orange)),
        const SizedBox(width: 8), Expanded(child: infoCard("SPOT", val(optionSpot ?? engine["index_ltp"]), Colors.blue)),
      ]),
      Card(child: Column(children: <Widget>[
        for (final raw in liveIndices.take(10)) _quoteCard(raw),
        if (liveIndices.isEmpty) const ListTile(title: Text("Waiting for live Indian indices")),
      ])),
    ]);

    Widget heatmap() {
      final grouped = <double, Map<String, dynamic>>{};
      for (final r in rows) {
        final strike = double.tryParse((r["strike"] ?? "").toString());
        if (strike == null) continue;
        final bucket = grouped.putIfAbsent(strike, () => <String, dynamic>{});
        bucket[(r["type"] ?? "").toString().toUpperCase()] = r;
      }
      final strikes = grouped.keys.toList()..sort();
      num maxOi = 0;
      for (final strike in strikes) {
        final bucket = grouped[strike]!;
        for (final side in const ["CE", "PE"]) {
          final data = bucket[side];
          final oi = num.tryParse((data is Map ? data["oi"] : 0).toString()) ?? 0;
          if (oi > maxOi) maxOi = oi;
        }
      }
      final liveSpot = double.tryParse((optionSpot ?? "").toString());

      Widget heatCell(dynamic data, String side) {
        final oi = num.tryParse((data is Map ? data["oi"] : 0).toString()) ?? 0;
        final ratio = maxOi > 0 ? (oi / maxOi).clamp(0.0, 1.0) : 0.0;
        final color = side == "CE" ? Colors.green : Colors.red;
        return Expanded(
          child: Container(
            margin: const EdgeInsets.all(2),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            decoration: BoxDecoration(
              color: color.withValues(alpha: .08 + (.42 * ratio)),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: color.withValues(alpha: .25)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Text(side, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold)),
                Text(val(data is Map ? data["oi"] : null), style: const TextStyle(fontWeight: FontWeight.bold)),
                Text("Δ " + val(data is Map ? (data["oiChangePct"] ?? data["oi_change"]) : null), style: const TextStyle(fontSize: 10)),
              ],
            ),
          ),
        );
      }

      return Column(children: <Widget>[
        chipIndexSelector(),
        const SizedBox(height: 8),
        Row(children: <Widget>[
          Expanded(child: infoCard("SPOT", val(optionSpot), Colors.blue)),
          const SizedBox(width: 8),
          Expanded(child: infoCard("EXPIRY", val(optionExpiry), Colors.purple)),
          const SizedBox(width: 8),
          Expanded(child: infoCard("OI ROWS", strikes.length.toString(), Colors.orange)),
        ]),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(children: <Widget>[
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(children: <Widget>[
                  Expanded(child: Text("CALL OI", style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold))),
                  Expanded(child: Center(child: Text("STRIKE", style: TextStyle(fontWeight: FontWeight.bold)))),
                  Expanded(child: Text("PUT OI", textAlign: TextAlign.right, style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold))),
                ]),
              ),
              const Divider(height: 1),
              ...strikes.take(25).map((strike) {
                final bucket = grouped[strike]!;
                final atm = liveSpot != null && (strike - liveSpot).abs() <= 20;
                return Container(
                  margin: const EdgeInsets.symmetric(vertical: 2),
                  decoration: BoxDecoration(
                    color: atm ? Colors.amber.withValues(alpha: .10) : null,
                    borderRadius: BorderRadius.circular(9),
                    border: atm ? Border.all(color: Colors.amber.withValues(alpha: .35)) : null,
                  ),
                  child: Row(children: <Widget>[
                    heatCell(bucket["CE"], "CE"),
                    Expanded(child: Center(child: Text(atm ? "ATM " + strike.toStringAsFixed(0) : strike.toStringAsFixed(0), style: TextStyle(fontWeight: FontWeight.bold, color: atm ? Colors.amber.shade700 : null)))),
                    heatCell(bucket["PE"], "PE"),
                  ]),
                );
              }),
              if (strikes.isEmpty) const Padding(padding: EdgeInsets.all(20), child: Text("LIVE OI DATA UNAVAILABLE")),
            ]),
          ),
        ),
        infoCard("HEAT SCALE", "Higher OI = stronger cell intensity. ATM strike is highlighted.", Colors.blue),
      ]);
    }
    Widget premiumVolume() {
      num ceVol = 0, peVol = 0;
      Map<String, dynamic>? topCe;
      Map<String, dynamic>? topPe;
      for (final r in rows) {
        final volume = num.tryParse((r["volume"] ?? "0").toString()) ?? 0;
        final side = (r["type"] ?? "").toString().toUpperCase();
        if (side == "CE") {
          ceVol += volume;
          final currentTop = num.tryParse((topCe?["volume"] ?? "0").toString()) ?? 0;
          if (topCe == null || volume > currentTop) topCe = r;
        } else if (side == "PE") {
          peVol += volume;
          final currentTop = num.tryParse((topPe?["volume"] ?? "0").toString()) ?? 0;
          if (topPe == null || volume > currentTop) topPe = r;
        }
      }
      final total = ceVol + peVol;
      final ceRatio = total > 0 ? ceVol / total : 0.0;
      final peRatio = total > 0 ? peVol / total : 0.0;
      final ceLtp = num.tryParse((ceAtm?["ltp"] ?? "0").toString()) ?? 0;
      final peLtp = num.tryParse((peAtm?["ltp"] ?? "0").toString()) ?? 0;
      final spread = ceLtp - peLtp;

      return Column(children: <Widget>[
        chipIndexSelector(),
        const SizedBox(height: 8),
        Row(children: <Widget>[
          Expanded(child: infoCard("CE VOLUME", ceVol.toStringAsFixed(0), Colors.green)),
          const SizedBox(width: 8),
          Expanded(child: infoCard("PE VOLUME", peVol.toStringAsFixed(0), Colors.red)),
          const SizedBox(width: 8),
          Expanded(child: infoCard("ATM SPREAD", spread.toStringAsFixed(2), Colors.blue)),
        ]),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              const Text("VOLUME FLOW", style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              Row(children: <Widget>[
                const SizedBox(width: 34, child: Text("CE")),
                Expanded(child: LinearProgressIndicator(value: ceRatio)),
                const SizedBox(width: 10),
                Text((ceRatio * 100).toStringAsFixed(1) + "%"),
              ]),
              const SizedBox(height: 9),
              Row(children: <Widget>[
                const SizedBox(width: 34, child: Text("PE")),
                Expanded(child: LinearProgressIndicator(value: peRatio)),
                const SizedBox(width: 10),
                Text((peRatio * 100).toStringAsFixed(1) + "%"),
              ]),
            ]),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              const Text("ATM PREMIUM", style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              row("CE LTP", val(ceAtm?["ltp"])),
              row("PE LTP", val(peAtm?["ltp"])),
              row("CE IV", val(ceAtm?["iv"])),
              row("PE IV", val(peAtm?["iv"])),
              row("Highest CE volume", val(topCe?["volume"])),
              row("Highest PE volume", val(topPe?["volume"])),
              row("Premium spread", spread.toStringAsFixed(2)),
            ]),
          ),
        ),
        infoCard("LIVE SOURCE", "Angel One SmartAPI • " + rows.length.toString() + " live option rows", Colors.blue),
      ]);
    }
    Widget greeks() => Column(children: <Widget>[
      chipIndexSelector(), const SizedBox(height: 8),
      Row(children: <Widget>[
        Expanded(child: infoCard("SPOT", val(optionSpot), Colors.blue)),
        const SizedBox(width: 8), Expanded(child: infoCard("EXPIRY", val(optionExpiry), Colors.purple)),
      ]),
      Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        const Text("ATM GREEKS", style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        _greeksRow("CE", ceAtm),
        const Divider(),
        _greeksRow("PE", peAtm),
      ]))),
      infoCard("NOTE", "Greeks are displayed only when returned by the live Angel One/NSE backend adapter.", Colors.blue),
    ]);

    Widget signalFlow() {
      final stages = <Map<String,dynamic>>[
        {"name":"ANGEL ONE FEED","ok":connection == "Connected"},
        {"name":"ENGINE","ok":engine["available"] == true},
        {"name":"STRATEGY 377","ok":strategy377Data.isNotEmpty && stratEval.isNotEmpty},
        {"name":"AI VALIDATION","ok":aiStatusData["total"] != null},
      ];
      return Column(children: <Widget>[
        Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(children: <Widget>[
          for (int i=0; i<stages.length; i++) ...<Widget>[
            ListTile(dense: true, leading: Icon(stages[i]["ok"] == true ? Icons.check_circle : Icons.radio_button_unchecked, color: stages[i]["ok"] == true ? Colors.green : Colors.orange), title: Text(stages[i]["name"] as String), trailing: Text(stages[i]["ok"] == true ? "READY" : "WAITING")),
            if (i < stages.length - 1) const Divider(height: 1),
          ],
        ]))),
        infoCard("CURRENT SIGNAL", val(signal?["action"] ?? engine["signal_status"]), Colors.blue),
        row("Option", val(signal?["optionSymbol"] ?? engine["option_symbol"])),
        row("Entry", val(signal?["entry"] ?? engine["entry"])),
        row("SL", val(signal?["sl"] ?? engine["stop_loss"])),
        row("Target", val(signal?["target"] ?? engine["target"])),
      ]);
    }

    Widget regime() => Column(children: <Widget>[
      Row(children: <Widget>[
        Expanded(child: infoCard("TREND", val(engine["trend"] ?? nse["trend"]), Colors.blue)),
        const SizedBox(width: 8), Expanded(child: infoCard("RSI 14", val(computed["rsi_14"]), Colors.purple)),
      ]),
      Row(children: <Widget>[
        Expanded(child: infoCard("EMA 8", val(computed["ema_8"]), Colors.green)),
        const SizedBox(width: 8), Expanded(child: infoCard("EMA 13", val(computed["ema_13"]), Colors.orange)),
      ]),
      Row(children: <Widget>[
        Expanded(child: infoCard("MACD", val(computed["macd"]), Colors.blue)),
        const SizedBox(width: 8), Expanded(child: infoCard("REALIZED VOL", val(computed["realized_vol"]), Colors.red)),
      ]),
      Row(children: <Widget>[
        Expanded(child: infoCard("ATR 14", val(computed["atr_14"]), Colors.purple)),
        const SizedBox(width: 8), Expanded(child: infoCard("VWAP", val(computed["vwap"]), Colors.green)),
      ]),
      infoCard("REGIME INPUT", "Deterministic quant layer • no fabricated indicators", Colors.blue),
    ]);

    Widget tradePlans() {
      final action = (signal?["action"] ?? stratEval["decision"] ?? "WAIT").toString().replaceAll("_", " ");
      final color = action.contains("CALL") ? Colors.green : action.contains("PUT") ? Colors.red : Colors.orange;
      return Column(children: <Widget>[
        Card(color: color.withValues(alpha: .12), child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Row(children: <Widget>[Icon(Icons.view_list, color: color, size: 30), const SizedBox(width: 10), Expanded(child: Text("S+ TRADE PLAN", style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold))), Chip(label: Text(action))]),
          const SizedBox(height: 10),
          row("Underlying", val(signal?["underlying"] ?? engine["symbol"])),
          row("Option", val(signal?["optionSymbol"] ?? engine["option_symbol"])),
          row("Entry", val(signal?["entry"] ?? engine["entry"])),
          row("Stop Loss", val(signal?["sl"] ?? engine["stop_loss"])),
          row("Target", val(signal?["target"] ?? engine["target"])),
          row("Score", val(signal?["score"] ?? engine["score"])),
        ]))),
        infoCard("STRATEGY", strategy["name"]?.toString() ?? "Strategy 377", Colors.blue),
        infoCard("STATUS", action == "WAIT" ? "No qualifying live setup." : "Live engine plan returned. Paper only.", color),
      ]);
    }

    Widget backtest() => Column(children: <Widget>[
      Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        const Text("STRATEGY 377 • BACKTEST", style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text("Timeframe: ${strategy["tf"] ?? "5m"} • Version: ${strategy["version"] ?? "377.1"}"),
        const SizedBox(height: 6),
        const Text("No synthetic performance numbers are shown. Use the backend backtest endpoint with historical bars for measured results."),
      ]))),
      FilledButton(onPressed: () => setState(() => selected = 13), child: const Text("OPEN STRATEGY 377")),
    ]);

    Widget registry() => Column(children: <Widget>[
      Card(child: ListTile(leading: const Icon(Icons.verified), title: const Text("Strategy 377"), subtitle: Text("${strategy["tf"] ?? "5m"} • ${(strategy["entry_call"] as List?)?.length ?? 0} call conditions • ${(strategy["entry_put"] as List?)?.length ?? 0} put conditions"), trailing: Chip(label: Text(strategy377Data.isEmpty ? "LOAD" : "LIVE")))),
      Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        const Text("VALIDATION", style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        row("Decision", val(stratEval["decision"])),
        row("Matched", val((stratEval["matched"] as List?)?.join(", "))),
        row("Blocked", val((stratEval["blocked"] as List?)?.join(", "))),
      ]))),
      infoCard("POLICY", "Deterministic rules only • no arbitrary strategy code • paper trading only", Colors.blue),
    ]);

    Widget aiLayers() => Column(children: <Widget>[
      Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        const Text("SIX AI LAYERS", style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        if (aiStatusData["providers"] is List)
          ...(aiStatusData["providers"] as List).map((raw) {
            final p = raw is Map ? Map<String,dynamic>.from(raw) : <String,dynamic>{};
            final live = p["live"] == true || p["status"] == "ok";
            final configured = p["configured"] == true || p["status"] != "not_configured";
            return ListTile(
              dense: true, contentPadding: EdgeInsets.zero,
              leading: Icon(live ? Icons.check_circle : Icons.error_outline, color: live ? Colors.green : Colors.orange),
              title: Text(val(p["name"])),
              subtitle: Text(val(p["model"])),
              trailing: Chip(label: Text(live ? "LIVE" : configured ? "CONFIGURED" : "KEY MISSING")),
            );
          })
        else
          const ListTile(title: Text("Tap refresh to probe six server-side AI providers.")),
      ]))),
      FilledButton.icon(onPressed: () => setState(() => selected = 15), icon: const Icon(Icons.psychology), label: const Text("OPEN AI MODELS")),
    ]);

    Widget body;
    if (index == 20) body = marketOverview();
    else if (index == 21) body = heatmap();
    else if (index == 22) body = premiumVolume();
    else if (index == 23) body = greeks();
    else if (index == 24) body = signalFlow();
    else if (index == 25) body = regime();
    else if (index == 26) body = tradePlans();
    else if (index == 27) body = backtest();
    else if (index == 28) body = registry();
    else body = aiLayers();

    return RefreshIndicator(
      onRefresh: () => refreshCurrentPage(),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
        children: <Widget>[proHeader(), const SizedBox(height: 4), body, const SizedBox(height: 8),
          Text("LIVE • Angel One / deterministic backend • last update $liveLastUpdated", textAlign: TextAlign.center, style: const TextStyle(fontSize: 11)),
        ],
      ),
    );
  }

  Widget _greeksRow(String side, Map<String,dynamic>? r) {
    String v(String key) => r == null || r[key] == null || r[key].toString().trim().isEmpty ? "DATA UNAVAILABLE" : r[key].toString();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Text(side, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: side == "CE" ? Colors.green : Colors.red)),
      const SizedBox(height: 6),
      Row(children: <Widget>[
        Expanded(child: _detailMetric("IV", v("iv"))),
        Expanded(child: _detailMetric("DELTA", v("delta"))),
        Expanded(child: _detailMetric("GAMMA", v("gamma"))),
        Expanded(child: _detailMetric("VEGA", v("vega"))),
        Expanded(child: _detailMetric("THETA", v("theta"))),
      ]),
    ]);
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
