import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sama360/core/api/api_client.dart';
import 'package:sama360/core/api/session_store.dart';

var refreshCalls = 0;

/// Serveur factice : /v1/me répond « jeton expiré », /v1/auth/refresh selon le scénario.
class _Adapter implements HttpClientAdapter {
  _Adapter(this.refresh);
  final ResponseBody Function(RequestOptions o) refresh;

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? body, Future<void>? cancel) async {
    if (o.path.endsWith('/v1/auth/refresh')) {
      refreshCalls++;
      return refresh(o);
    }
    return _json(401, {
      'error': {'code': 'TOKEN_INVALID', 'message': 'Session expirée'},
    });
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(int status, Map<String, dynamic> data) => ResponseBody.fromString(
  jsonEncode(data),
  status,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);

Future<(ApiClient, MemorySessionStore, List<bool>)> _client(ResponseBody Function(RequestOptions) refresh) async {
  final store = MemorySessionStore();
  await store.save(const Session(accessToken: 'a', refreshToken: 'r'));
  final expired = <bool>[];
  final dio = Dio(BaseOptions(baseUrl: 'http://api.test'))..httpClientAdapter = _Adapter(refresh);
  final client = ApiClient(
    baseUrl: 'http://api.test',
    store: store,
    dio: dio,
    onSessionExpired: () => expired.add(true),
  );
  return (client, store, expired);
}

void main() {
  test('panne réseau pendant le renouvellement : la session est gardée', () async {
    final (client, store, expired) = await _client(
      (o) => throw DioException.connectionError(requestOptions: o, reason: 'hors ligne'),
    );
    await expectLater(client.get<Map<String, dynamic>>('/v1/me'), throwsA(isA<ApiException>()));
    expect(refreshCalls, 1);
    expect(await store.read(), isNotNull);
    expect(expired, isEmpty);
  });

  test('refus du serveur : déconnexion', () async {
    final (client, store, expired) = await _client(
      (_) => _json(401, {
        'error': {'code': 'TOKEN_INVALID'},
      }),
    );
    await expectLater(client.get<Map<String, dynamic>>('/v1/me'), throwsA(isA<ApiException>()));
    expect(await store.read(), isNull);
    expect(expired, [true]);
  });
}
