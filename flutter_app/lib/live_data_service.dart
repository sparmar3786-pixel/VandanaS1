import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

/// Production-oriented API layer for the Flutter client.
///
/// Keeps network concerns out of UI widgets and provides:
/// - URI/authentication handling in one place.
/// - Retries for transient failures.
/// - JSON shape validation.
/// - Central endpoints for live market/AI data.
/// - A single WebSocket factory for the live stream.
class LiveDataService {
  LiveDataService(
    String baseUrl,
    String token, {
    http.Client? client,
  })  : baseUrl = _normalizeBaseUrl(baseUrl),
        token = token.trim(),
        _client = client ?? http.Client();

  final String baseUrl;
  final String token;
  final http.Client _client;

  static const Duration defaultTimeout = Duration(seconds: 15);
  static const int maxAttempts = 3;

  static String _normalizeBaseUrl(String value) {
    final cleaned = value.trim().replaceFirst(RegExp(r'/+$'), '');
    if (cleaned.isEmpty) {
      throw ArgumentError('Backend URL cannot be empty.');
    }
    final uri = Uri.tryParse(cleaned);
    if (uri == null ||
        uri.host.isEmpty ||
        !{'https', 'http'}.contains(uri.scheme)) {
      throw ArgumentError('Backend URL must be a valid HTTP(S) URL.');
    }
    return cleaned;
  }

  Map<String, String> get _headers => <String, String>{
        'Accept': 'application/json',
        'User-Agent': 'Parmar-Trading-Flutter/1.0',
        if (token.isNotEmpty) 'x-token': token,
      };

  Uri _uri(String path, [Map<String, String>? query]) {
    final uri = Uri.parse(baseUrl + path);
    return query == null ? uri : uri.replace(queryParameters: query);
  }

  Future<http.Response> _get(
    String path, {
    Map<String, String>? query,
    Duration timeout = defaultTimeout,
  }) async {
    Object? lastError;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final response = await _client
            .get(_uri(path, query), headers: _headers)
            .timeout(timeout);

        final retryableStatus = response.statusCode == 408 ||
            response.statusCode == 429 ||
            response.statusCode >= 500;

        if (!retryableStatus || attempt == maxAttempts) {
          return response;
        }

        lastError = StateError('HTTP ${response.statusCode}');
      } catch (error) {
        lastError = error;
        if (attempt == maxAttempts) {
          rethrow;
        }
      }

      await Future<void>.delayed(
        Duration(milliseconds: 250 * (1 << (attempt - 1))),
      );
    }

    throw Exception('Request failed: $lastError');
  }

  dynamic _decode(String body) {
    if (body.trim().isEmpty) {
      throw const FormatException('Server returned an empty response.');
    }
    try {
      return jsonDecode(body);
    } on FormatException catch (error) {
      throw FormatException('Invalid JSON from backend: ${error.message}');
    }
  }

  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, String>? query,
    Duration timeout = defaultTimeout,
  }) async {
    final response = await _get(path, query: query, timeout: timeout);
    final decoded = _decode(response.body);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final detail = decoded is Map<String, dynamic>
          ? (decoded['detail'] ?? decoded['error'] ?? 'Request failed')
          : 'Request failed';
      throw LiveDataException(
        statusCode: response.statusCode,
        path: path,
        message: detail.toString(),
      );
    }

    if (decoded is! Map<String, dynamic>) {
      throw LiveDataException(
        statusCode: response.statusCode,
        path: path,
        message: 'Expected a JSON object.',
      );
    }

    return decoded;
  }

  Future<List<dynamic>> getList(
    String path, {
    Map<String, String>? query,
    Duration timeout = defaultTimeout,
  }) async {
    final response = await _get(path, query: query, timeout: timeout);
    final decoded = _decode(response.body);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw LiveDataException(
        statusCode: response.statusCode,
        path: path,
        message: 'HTTP ${response.statusCode}',
      );
    }

    if (decoded is! List<dynamic>) {
      throw LiveDataException(
        statusCode: response.statusCode,
        path: path,
        message: 'Expected a JSON array.',
      );
    }

    return decoded;
  }

  Future<http.Response> getRaw(
    String path, {
    Map<String, String>? query,
    Duration timeout = defaultTimeout,
  }) =>
      _get(path, query: query, timeout: timeout);

  Future<Map<String, dynamic>> liveSnapshot() =>
      getJson('/v1/live/snapshot');

  Future<Map<String, dynamic>> diagnostics() =>
      getJson('/v1/diagnostics');

  Future<Map<String, dynamic>> quantLive({
    String index = 'NIFTY',
  }) =>
      getJson(
        '/v1/quant/live',
        query: <String, String>{'index': index},
      );

  Future<Map<String, dynamic>> aiProviderStatus({
    bool probe = false,
  }) =>
      getJson(
        '/v1/ai/provider-status',
        query: <String, String>{'probe': probe.toString()},
      );

  Future<Map<String, dynamic>> liveNews({
    String query = 'NIFTY India',
  }) =>
      getJson(
        '/v1/live/news',
        query: <String, String>{'q': query},
      );

  Future<Map<String, dynamic>> terminal() =>
      getJson('/v1/terminal');

  Future<Map<String, dynamic>> strategyRefresh({
    String? index,
  }) =>
      getJson(
        '/v1/strategy/refresh',
        query: index == null
            ? null
            : <String, String>{'index': index},
        timeout: const Duration(seconds: 12),
      );

  Future<Map<String, dynamic>> angelIndices() =>
      getJson('/v1/angel/indices', timeout: const Duration(seconds: 8));

  Future<Map<String, dynamic>> angelCommodities() =>
      getJson('/v1/angel/commodities', timeout: const Duration(seconds: 10));

  Future<Map<String, dynamic>> angelMarket() =>
      getJson('/v1/angel/market', timeout: const Duration(seconds: 8));

  Future<Map<String, dynamic>> angelCandles({
    required String exchange,
    required String token,
    required String interval,
    int days = 1,
  }) =>
      getJson(
        '/v1/angel/candles',
        query: <String, String>{
          'exchange': exchange,
          'token': token,
          'interval': interval,
          'days': days.toString(),
        },
        timeout: const Duration(seconds: 12),
      );

  Future<Map<String, dynamic>> optionChain({
    String symbol = 'NIFTY',
    int count = 10,
  }) =>
      getJson(
        '/v1/angel/option-chain',
        query: <String, String>{
          'symbol': symbol,
          'count': count.toString(),
        },
        timeout: const Duration(seconds: 15),
      );

  Future<Map<String, dynamic>> oiBuildup({
    String datatype = 'Long Built Up',
    String expiryType = 'NEAR',
  }) =>
      getJson(
        '/v1/angel/oi-buildup',
        query: <String, String>{
          'datatype': datatype,
          'expirytype': expiryType,
        },
        timeout: const Duration(seconds: 12),
      );

  WebSocketChannel connectSocket() {
    final scheme = baseUrl.startsWith('https://')
        ? 'wss://'
        : baseUrl.startsWith('http://')
            ? 'ws://'
            : null;
    if (scheme == null) {
      throw ArgumentError('WebSocket requires an HTTP(S) backend URL.');
    }

    final hostPath = baseUrl.replaceFirst(RegExp(r'^https?://'), '');
    final uri = Uri.parse('$scheme$hostPath/ws/live').replace(
      queryParameters: <String, String>{
        if (token.isNotEmpty) 'token': token,
      },
    );
    return WebSocketChannel.connect(uri);
  }

  void close() => _client.close();
}

class LiveDataException implements Exception {
  const LiveDataException({
    required this.statusCode,
    required this.path,
    required this.message,
  });

  final int statusCode;
  final String path;
  final String message;

  @override
  String toString() => 'LiveDataException($statusCode, $path): $message';
}
