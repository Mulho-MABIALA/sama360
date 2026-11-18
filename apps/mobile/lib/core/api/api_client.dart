import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;

import 'session_store.dart';

/// Erreur métier renvoyée par l'API : { error: { code, message, details } }.
class ApiException implements Exception {
  const ApiException(this.code, this.message, {this.status, this.details});
  final String code;
  final String message;
  final int? status;
  final Object? details;

  static const network = 'NETWORK';

  /// Pas de réponse du serveur (pas de réseau, délai dépassé) : on peut réessayer plus tard.
  bool get isNetwork => code == network;

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

  /// Faux dès qu'une requête échoue faute de réseau, vrai à la première réponse du serveur.
  final online = ValueNotifier<bool>(true);

  Future<Session?>? _refreshing;

  Future<void> _onRequest(RequestOptions o, RequestInterceptorHandler h) async {
    final s = await store.read();
    if (s != null && o.extra['public'] != true) o.headers['Authorization'] = 'Bearer ${s.accessToken}';
    // Une requête peut viser une autre entreprise (ex. vente hors ligne envoyée plus tard).
    if (businessId != null && o.extra['noBusiness'] != true) o.headers.putIfAbsent('X-Business-Id', () => businessId);
    h.next(o);
  }

  Future<void> _onError(DioException e, ErrorInterceptorHandler h) async {
    final res = e.response;
    final code = _code(res?.data);
    final canRetry =
        res?.statusCode == 401 &&
        code == 'TOKEN_INVALID' &&
        e.requestOptions.extra['retried'] != true &&
        e.requestOptions.extra['public'] != true;
    if (!canRetry) return h.next(e);

    final Session? session;
    try {
      session = await _refreshOnce();
    } on DioException {
      // Réseau coupé ou trop lent pendant le renouvellement : on garde la session,
      // la requête échoue simplement (l'écran propose de réessayer).
      return h.next(e);
    }
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
      final s = Session(
        accessToken: res.data!['accessToken'] as String,
        refreshToken: res.data!['refreshToken'] as String,
      );
      await store.save(s);
      return s;
    } on DioException catch (err) {
      // Seul un refus du serveur met fin à la session ; une panne réseau ne déconnecte pas.
      final status = err.response?.statusCode;
      if (status == 400 || status == 401 || status == 403) {
        await store.clear();
        return null;
      }
      rethrow;
    }
  }

  // ---------- Appels ----------

  Future<T> get<T>(String path, {Map<String, dynamic>? query}) =>
      _wrap(() => dio.get<T>(path, queryParameters: _clean(query)));

  Future<T> post<T>(String path, {Object? data, bool public = false, String? businessId}) => _wrap(
    () => dio.post<T>(
      path,
      data: data ?? const {},
      options: Options(extra: {'public': public}, headers: businessId == null ? null : {'X-Business-Id': businessId}),
    ),
  );

  Future<T> patch<T>(String path, {Object? data}) => _wrap(() => dio.patch<T>(path, data: data));

  Future<T> put<T>(String path, {Object? data}) => _wrap(() => dio.put<T>(path, data: data));

  Future<T> delete<T>(String path) => _wrap(() => dio.delete<T>(path));

  /// Envoi de fichier (multipart/form-data, champ « file »), avec d'éventuels champs texte.
  Future<T> upload<T>(
    String path,
    List<int> bytes, {
    required String filename,
    String field = 'file',
    Map<String, String> fields = const {},
    Duration? receiveTimeout,
  }) => _wrap(
    () => dio.post<T>(
      path,
      data: FormData.fromMap({...fields, field: MultipartFile.fromBytes(bytes, filename: filename)}),
      options: Options(
        contentType: 'multipart/form-data',
        sendTimeout: const Duration(seconds: 60),
        receiveTimeout: receiveTimeout,
      ),
    ),
  );

  Future<T> _wrap<T>(Future<Response<T>> Function() call) async {
    try {
      final data = (await call()).data as T;
      online.value = true;
      return data;
    } on DioException catch (e) {
      final err = toApiException(e);
      online.value = !err.isNetwork;
      throw err;
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
