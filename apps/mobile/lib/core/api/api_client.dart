import 'dart:async';

import 'package:dio/dio.dart';

import 'session_store.dart';

/// Erreur métier renvoyée par l'API : { error: { code, message, details } }.
class ApiException implements Exception {
  const ApiException(this.code, this.message, {this.status, this.details});
  final String code;
  final String message;
  final int? status;
  final Object? details;

  static const network = 'NETWORK';

  /// Valeur numérique d'un détail, ex. remainingAttempts.
  int? detailInt(String key) {
    final d = details;
    if (d is Map && d[key] is num) return (d[key] as num).toInt();
    return null;
  }

  @override
  String toString() => 'ApiException($code, $message)';
}

/// Client HTTP de Sama360 :
/// - ajoute le jeton d'accès et l'entreprise courante (X-Business-Id) ;
/// - rafraîchit la session une seule fois même si plusieurs requêtes expirent en même temps
///   (le serveur révoque toute la session si un jeton de rafraîchissement est réutilisé) ;
/// - convertit toutes les erreurs en [ApiException].
class ApiClient {
  ApiClient({required String baseUrl, required this.store, Dio? dio, this.onSessionExpired})
    : dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: baseUrl,
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 20),
              contentType: 'application/json',
            ),
          ) {
    this.dio.interceptors.add(InterceptorsWrapper(onRequest: _onRequest, onError: _onError));
  }

  final Dio dio;
  final SessionStore store;
  void Function()? onSessionExpired;

  /// Entreprise courante, envoyée dans X-Business-Id.
  String? businessId;

  Future<Session?>? _refreshing;

  Future<void> _onRequest(RequestOptions o, RequestInterceptorHandler h) async {
    final s = await store.read();
    if (s != null && o.extra['public'] != true) o.headers['Authorization'] = 'Bearer ${s.accessToken}';
    if (businessId != null && o.extra['noBusiness'] != true) o.headers['X-Business-Id'] = businessId;
    h.next(o);
  }

  Future<void> _onError(DioException e, ErrorInterceptorHandler h) async {
    final res = e.response;
    final code = _code(res?.data);
    final canRetry = res?.statusCode == 401 &&
        code == 'TOKEN_INVALID' &&
        e.requestOptions.extra['retried'] != true &&
        e.requestOptions.extra['public'] != true;
    if (!canRetry) return h.next(e);

    final session = await _refreshOnce();
    if (session == null) {
      onSessionExpired?.call();
      return h.next(e);
    }
    final o = e.requestOptions..extra['retried'] = true;
    o.headers['Authorization'] = 'Bearer ${session.accessToken}';
    try {
      h.resolve(await dio.fetch(o));
    } on DioException catch (err) {
      h.next(err);
    }
  }

  Future<Session?> _refreshOnce() {
    return _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);
  }

  Future<Session?> _doRefresh() async {
    final current = await store.read();
    if (current == null) return null;
    try {
      final res = await dio.post<Map<String, dynamic>>(
        '/v1/auth/refresh',
        data: {'refreshToken': current.refreshToken},
        options: Options(extra: {'public': true}),
      );
      final s = Session(accessToken: res.data!['accessToken'] as String, refreshToken: res.data!['refreshToken'] as String);
      await store.save(s);
      return s;
    } on DioException {
      await store.clear();
      return null;
    }
  }

  // ---------- Appels ----------

  Future<T> get<T>(String path, {Map<String, dynamic>? query}) =>
      _wrap(() => dio.get<T>(path, queryParameters: _clean(query)));

  Future<T> post<T>(String path, {Object? data, bool public = false}) =>
      _wrap(() => dio.post<T>(path, data: data ?? const {}, options: Options(extra: {'public': public})));

  Future<T> patch<T>(String path, {Object? data}) => _wrap(() => dio.patch<T>(path, data: data));

  Future<T> _wrap<T>(Future<Response<T>> Function() call) async {
    try {
      return (await call()).data as T;
    } on DioException catch (e) {
      throw toApiException(e);
    }
  }

  static Map<String, dynamic>? _clean(Map<String, dynamic>? q) =>
      q == null ? null : (Map.of(q)..removeWhere((_, v) => v == null));

  static String? _code(Object? data) {
    if (data is Map && data['error'] is Map) return (data['error'] as Map)['code'] as String?;
    return null;
  }

  static ApiException toApiException(DioException e) {
    final data = e.response?.data;
    if (data is Map && data['error'] is Map) {
      final err = data['error'] as Map;
      return ApiException(
        err['code'] as String? ?? 'INTERNAL',
        err['message'] as String? ?? 'Erreur',
        status: e.response?.statusCode,
        details: err['details'],
      );
    }
    if (e.response == null) {
      return const ApiException(ApiException.network, 'Connexion impossible au serveur. Vérifiez votre connexion.');
    }
    return ApiException('INTERNAL', 'Erreur inattendue (${e.response?.statusCode})', status: e.response?.statusCode);
  }
}
