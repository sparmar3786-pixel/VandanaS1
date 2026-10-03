import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:parmar_trading/live_data_service.dart';

void main() {
  test('retries a transient backend failure and returns JSON', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      if (calls == 1) {
        return http.Response('temporary failure', 503);
      }
      return http.Response(
        jsonEncode(<String, dynamic>{'ok': true}),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });

    final service = LiveDataService(
      'https://example.com',
      '',
      client: client,
    );

    final result = await service.getJson('/health');

    expect(result['ok'], true);
    expect(calls, 2);
    service.close();
  });

  test('rejects invalid backend schemes', () {
    expect(
      () => LiveDataService('ftp://example.com', ''),
      throwsArgumentError,
    );
  });

  test('strategy endpoint builds an encoded query', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/v1/strategy/refresh');
      expect(request.url.queryParameters['index'], 'BANK NIFTY');
      return http.Response(
        jsonEncode(<String, dynamic>{'available': true}),
        200,
      );
    });

    final service = LiveDataService(
      'https://example.com',
      '',
      client: client,
    );

    final result = await service.strategyRefresh(index: 'BANK NIFTY');

    expect(result['available'], true);
    service.close();
  });
}
