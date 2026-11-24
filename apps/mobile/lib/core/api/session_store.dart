import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Session {
  const Session({required this.accessToken, required this.refreshToken});
  final String accessToken;
  final String refreshToken;
}

/// Où l'app garde la session et l'entreprise choisie.
abstract class SessionStore {
  Future<Session?> read();
  Future<void> save(Session session);
  Future<void> clear();
  Future<String?> readBusinessId();
  Future<void> saveBusinessId(String? id);
}

/// Jetons dans le stockage chiffré du téléphone ; entreprise choisie dans les préférences.
class SecureSessionStore implements SessionStore {
  SecureSessionStore([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _storage;
  static const _access = 'sama_access';
  static const _refresh = 'sama_refresh';
  static const _business = 'sama_business';

  @override
  Future<Session?> read() async {
    final a = await _storage.read(key: _access);
    final r = await _storage.read(key: _refresh);
    if (a == null || r == null) return null;
    return Session(accessToken: a, refreshToken: r);
  }

  @override
  Future<void> save(Session s) async {
    await _storage.write(key: _access, value: s.accessToken);
    await _storage.write(key: _refresh, value: s.refreshToken);
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: _access);
    await _storage.delete(key: _refresh);
    await saveBusinessId(null);
  }

  @override
  Future<String?> readBusinessId() async => (await SharedPreferences.getInstance()).getString(_business);

  @override
  Future<void> saveBusinessId(String? id) async {
    final prefs = await SharedPreferences.getInstance();
    id == null ? await prefs.remove(_business) : await prefs.setString(_business, id);
  }
}

/// Version web : préférences du navigateur. Le stockage chiffré a besoin de WebCrypto,
/// absent d'une page en http:// sur le Wi-Fi (http://192.168…:3000/app) ; c'est le cas des tests sur iPhone.
class PrefsSessionStore implements SessionStore {
  /// [prefix] sépare deux sessions dans le même navigateur (ex. « admin. » pour le back office).
  PrefsSessionStore({String prefix = ''})
    : _access = '${prefix}sama_access',
      _refresh = '${prefix}sama_refresh',
      _business = '${prefix}sama_business';
  final String _access;
  final String _refresh;
  final String _business;

  @override
  Future<Session?> read() async {
    final p = await SharedPreferences.getInstance();
    final a = p.getString(_access);
    final r = p.getString(_refresh);
    return a == null || r == null ? null : Session(accessToken: a, refreshToken: r);
  }

  @override
  Future<void> save(Session s) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_access, s.accessToken);
    await p.setString(_refresh, s.refreshToken);
  }

  @override
  Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_access);
    await p.remove(_refresh);
    await p.remove(_business);
  }

  @override
  Future<String?> readBusinessId() async => (await SharedPreferences.getInstance()).getString(_business);

  @override
  Future<void> saveBusinessId(String? id) async {
    final prefs = await SharedPreferences.getInstance();
    id == null ? await prefs.remove(_business) : await prefs.setString(_business, id);
  }
}

/// Tests et prévisualisations.
class MemorySessionStore implements SessionStore {
  Session? session;
  String? businessId;

  @override
  Future<Session?> read() async => session;
  @override
  Future<void> save(Session s) async => session = s;
  @override
  Future<void> clear() async {
    session = null;
    businessId = null;
  }

  @override
  Future<String?> readBusinessId() async => businessId;
  @override
  Future<void> saveBusinessId(String? id) async => businessId = id;
}
