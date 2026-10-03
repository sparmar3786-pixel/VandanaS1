import 'package:flutter/material.dart';

import 'live_data_service.dart';

class ServerAiPage extends StatefulWidget {
  final String backendUrl;
  final String apiToken;
  final Map<String, dynamic>? initialSnapshot;
  final String symbol;

  const ServerAiPage({
    super.key,
    required this.backendUrl,
    required this.apiToken,
    this.initialSnapshot,
    this.symbol = 'NIFTY',
  });

  @override
  State<ServerAiPage> createState() => _ServerAiPageState();
}

class _ServerAiPageState extends State<ServerAiPage> {
  bool busy = false;
  Map<String, dynamic> result = <String, dynamic>{};
  Map<String, dynamic> snapshot = <String, dynamic>{};
  Map<String, dynamic> providerStatus = <String, dynamic>{};
  String status = 'Ready • server-side six-AI';

  LiveDataService get service =>
      LiveDataService(widget.backendUrl, widget.apiToken);

  String get symbol => widget.symbol.toUpperCase();

  @override
  void initState() {
    super.initState();
    snapshot = widget.initialSnapshot ?? <String, dynamic>{};
    run();
  }

  Future<void> run() async {
    if (busy || widget.backendUrl.trim().isEmpty) return;
    setState(() {
      busy = true;
      status = 'Collecting live terminal snapshot...';
    });

    final api = service;
    try {
      try {
        final live = await api.terminal();
        if (live.isNotEmpty) snapshot = live;
      } catch (_) {
        // Keep the latest known terminal snapshot.
      }

      final d = await api.aiValidate(snapshot);
      if (mounted) {
        setState(() {
          result = d;
          status = 'Live AI validation complete • ' +
              DateTime.now().toLocal().toString().substring(11, 19);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          status = 'AI request failed • previous result retained';
        });
      }
    }

    try {
      final p = await api.aiProviderStatus(probe: true);
      if (mounted) setState(() => providerStatus = p);
    } catch (e) {
      if (mounted) {
        setState(() {
          providerStatus = <String, dynamic>{
            'providers': <dynamic>[],
            'error': e.toString(),
          };
        });
      }
    } finally {
      api.close();
      if (mounted) setState(() => busy = false);
    }
  }

  String providerState(Map<String, dynamic> row) {
    final status = (row['status'] ?? '').toString();
    if (status == 'ok') return 'LIVE';
    if (status == 'not_configured') return 'KEY MISSING';
    if (status == 'ok_local') return 'LOCAL';
    return 'ERROR';
  }

  Color stateColor(String state) {
    if (state == 'LIVE' || state == 'LOCAL') return Colors.green;
    if (state == 'KEY MISSING') return Colors.orange;
    return Colors.red;
  }

  @override
  Widget build(BuildContext context) {
    final rows = result['providers'] is List
        ? List<dynamic>.from(result['providers'])
        : <dynamic>[];
    final finalState = (result['final'] ?? 'WAIT').toString();
    final success = (result['successful'] ?? 0).toString();
    final total = (result['total'] ?? 6).toString();
    final configured = (result['configured'] ?? 0).toString();

    return RefreshIndicator(
      onRefresh: run,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        children: <Widget>[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(15),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    '6-AI • LIVE SERVER VALIDATION',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 5),
                  const Text(
                    'Luna • Claude • Sol • DeepSeek • Gemini • Grok',
                  ),
                  const SizedBox(height: 8),
                  Text(
                    status,
                    style: TextStyle(
                      color: busy ? Colors.orange : Colors.green,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: <Widget>[
                      Expanded(child: _metric('CONFIGURED', configured)),
                      Expanded(child: _metric('SUCCESS', '$success/$total')),
                      Expanded(
                        child: _metric(
                          'MODE',
                          result['mode']?.toString() ?? 'WAIT',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: busy ? null : run,
                    icon: Icon(busy ? Icons.sync : Icons.refresh),
                    label: const Text('RUN LIVE 6-AI'),
                  ),
                ],
              ),
            ),
          ),
          if (result['error'] != null)
            infoCard('SERVER ERROR', result['error'].toString(), Colors.red),
          Card(
            child: ListTile(
              title: Text(
                'FINAL: $finalState',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Text(
                (result['reason'] ??
                        'Waiting for server validation.')
                    .toString(),
              ),
              trailing: Chip(label: Text('$success/$total')),
            ),
          ),
          if (providerStatus['error'] != null)
            infoCard('PROVIDER PROBE ERROR', providerStatus['error'].toString(), Colors.red),
          if (providerStatus.isNotEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text(
                      'PROVIDER CONFIGURATION',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 6),
                    if (providerStatus['providers'] is List)
                      ...(providerStatus['providers'] as List).map((raw) {
                        final m = raw is Map
                            ? Map<String, dynamic>.from(raw)
                            : <String, dynamic>{};
                        final configured = m['configured'] == true;
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text((m['name'] ?? 'Provider').toString()),
                          subtitle: Text((m['model'] ?? '').toString()),
                          trailing: Chip(
                            label: Text(configured ? 'CONFIGURED' : 'KEY MISSING'),
                          ),
                        );
                      }),
                  ],
                ),
              ),
            ),
          ...rows.map((raw) {
            final m = raw is Map
                ? Map<String, dynamic>.from(raw)
                : <String, dynamic>{};
            final text = (m['text'] ?? '').toString();
            final error = (m['error'] ?? '').toString();
            String parsedState = 'WAIT';
            for (final candidate in const <String>[
              'CALL BUY',
              'PUT BUY',
              'NO QUALIFYING TRADE',
              'WAIT',
            ]) {
              if (text.toUpperCase().contains('STATE: ' + candidate)) {
                parsedState = candidate;
                break;
              }
            }
            final state = m['status'] == 'ok_local' ? 'LOCAL' : parsedState;
            final statusLabel = providerState(m);

            return Card(
              child: ExpansionTile(
                title: Text((m['name'] ?? 'AI Provider').toString()),
                subtitle: Text(
                  (m['model'] ?? '').toString() + ' • ' + statusLabel,
                ),
                leading: Icon(
                  Icons.psychology,
                  color: stateColor(statusLabel),
                ),
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Chip(label: Text(state)),
                        if (text.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 6),
                          Text(text),
                        ],
                        if (error.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 8),
                          Text(
                            'ERROR: $error',
                            style: const TextStyle(color: Colors.red),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            );
          }),
          const Padding(
            padding: EdgeInsets.all(8),
            child: Text(
              'Provider keys remain server-side; APK receives validation results only.',
              style: TextStyle(color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }

  Widget infoCard(String label, String value, Color color) => Card(
        color: color.withValues(alpha: .10),
        child: Padding(
          padding: const EdgeInsets.all(11),
          child: Row(
            children: <Widget>[
              Icon(Icons.info_outline, color: color, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(label, style: const TextStyle(fontSize: 11)),
                    const SizedBox(height: 3),
                    Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ],
          ),
        ),
      );

  Widget _metric(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(label, style: const TextStyle(fontSize: 10)),
            const SizedBox(height: 3),
            Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
      );
}
