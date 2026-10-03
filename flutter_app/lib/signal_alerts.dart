import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class SignalAlert {
  final int seq;
  final String kind;
  final String title;
  final String body;
  final double ts;
  SignalAlert({required this.seq, required this.kind, required this.title, required this.body, required this.ts});
  factory SignalAlert.fromJson(Map<String, dynamic> j) => SignalAlert(
    seq: (j['seq'] as num?)?.toInt() ?? 0,
    kind: (j['kind'] ?? 'ENTRY').toString(),
    title: (j['title'] ?? '').toString(),
    body: (j['body'] ?? '').toString(),
    ts: (j['ts'] as num?)?.toDouble() ?? 0,
  );
}

class SignalAlertService {
  static const _seqKey = 'alert_seq';
  final FlutterLocalNotificationsPlugin notifications = FlutterLocalNotificationsPlugin();
  Timer? _timer;
  bool _busy = false;
  bool _stopped = false;
  String baseUrl;
  String apiToken;
  SignalAlert? latest;
  final List<SignalAlert> history = [];
  void Function(SignalAlert alert)? onAlert;

  SignalAlertService(this.baseUrl, this.apiToken);

  Future<void> start() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: android);
    await notifications.initialize(settings);
    await notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
    _stopped = false;
    await poll();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => poll());
  }

  Future<void> poll() async {
    if (_busy || _stopped) return;
    _busy = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getInt(_seqKey);
      final uri = Uri.parse(baseUrl + '/api/alerts' + (saved == null ? '' : '?since=$saved'));
      final r = await http.get(
        uri,
        headers: {
          if (apiToken.isNotEmpty) 'Authorization': 'Bearer $apiToken',
          if (apiToken.isNotEmpty) 'x-token': apiToken,
        },
      ).timeout(const Duration(seconds: 8));
      if (r.statusCode != 200) return;
      final d = jsonDecode(r.body);
      if (d is! Map) return;
      final seq = (d['seq'] as num?)?.toInt() ?? saved ?? 0;
      if (saved != null && seq < saved) {
        await prefs.setInt(_seqKey, seq);
        return;
      }
      await prefs.setInt(_seqKey, seq);
      final events = d['events'];
      if (events is! List) return;
      for (final raw in events) {
        if (raw is! Map) continue;
        final alert = SignalAlert.fromJson(Map<String, dynamic>.from(raw));
        history.insert(0, alert);
        if (history.length > 50) history.removeLast();
        latest = alert;
        await _notify(alert);
        onAlert?.call(alert);
      }
    } catch (_) {
    } finally {
      _busy = false;
    }
  }

  Future<void> _notify(SignalAlert alert) async {
    await HapticFeedback.mediumImpact();
    const android = AndroidNotificationDetails(
      'algo_signal_alerts',
      'Algo Signal Alerts',
      channelDescription: 'QUALIFIED ENTRY and EXIT alerts',
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
    );
    await notifications.show(alert.seq, alert.title, alert.body, const NotificationDetails(android: android));
  }

  Future<void> stop() async {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }
}