import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

class LiveDataService {
  String baseUrl;
  String token;
  LiveDataService(this.baseUrl, this.token);

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = baseUrl.replaceFirst(RegExp(r'/+$'), '');
    return Uri.parse(base + path).replace(queryParameters: query);
  }

  Map<String, String> get _headers => <String, String>{
    if (token.isNotEmpty) 'x-token': token,
  };

  Future<Map<String, dynamic>> getJson(String path, {Map<String, String>? query}) async {
    final r = await http.get(_uri(path, query), headers: _headers).timeout(const Duration(seconds: 15));
    final d = jsonDecode(r.body);
    if (r.statusCode < 200 || r.statusCode >= 300 || d is! Map<String, dynamic>) {
      throw Exception('HTTP ${r.statusCode}');
    }
    return d;
  }

  Future<Map<String, dynamic>> liveSnapshot() => getJson('/v1/live/snapshot');

  Future<Map<String, dynamic>> diagnostics() => getJson('/v1/diagnostics');

  Future<Map<String, dynamic>> quantLive({String index = 'NIFTY'}) =>
      getJson('/v1/quant/live', query: <String, String>{'index': index});

  Future<Map<String, dynamic>> aiProviderStatus({bool probe = false}) =>
      getJson('/v1/ai/provider-status', query: <String, String>{'probe': probe.toString()});

  WebSocketChannel connectSocket() {
    final base = baseUrl.replaceFirst(RegExp(r'/+$'), '');
    final u = Uri.parse(base.replaceFirst('https://', 'wss://').replaceFirst('http://', 'ws://') + '/ws/live')
        .replace(queryParameters: <String, String>{if (token.isNotEmpty) 'token': token});
    return WebSocketChannel.connect(u);
  }
}
