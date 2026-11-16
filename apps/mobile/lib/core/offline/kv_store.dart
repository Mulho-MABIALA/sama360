import 'package:shared_preferences/shared_preferences.dart';

/// Petit stockage clé → texte, lu de façon synchrone (chargé au démarrage).
/// Sert au cache hors ligne et à la file des ventes en attente.
abstract class KeyValueStore {
  String? getString(String key);
  Future<void> setString(String key, String value);
  Future<void> remove(String key);
  Iterable<String> get keys;

  /// Efface toutes les clés qui commencent par [prefix].
  Future<void> removePrefix(String prefix) async {
    for (final k in keys.where((k) => k.startsWith(prefix)).toList()) {
      await remove(k);
    }
  }
}

/// Stockage du téléphone (SharedPreferences), conservé entre les lancements.
class PrefsStore extends KeyValueStore {
  PrefsStore(this.prefs);
  final SharedPreferences prefs;

  @override
  String? getString(String key) => prefs.getString(key);
  @override
  Future<void> setString(String key, String value) => prefs.setString(key, value);
  @override
  Future<void> remove(String key) => prefs.remove(key);
  @override
  Iterable<String> get keys => prefs.getKeys();
}

/// Stockage en mémoire (tests, ou repli si le stockage du téléphone est indisponible).
class MemoryStore extends KeyValueStore {
  final data = <String, String>{};

  @override
  String? getString(String key) => data[key];
  @override
  Future<void> setString(String key, String value) async => data[key] = value;
  @override
  Future<void> remove(String key) async => data.remove(key);
  @override
  Iterable<String> get keys => data.keys;
}
