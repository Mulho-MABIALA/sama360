import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Code secret à 4 chiffres demandé à l'ouverture de l'app (comme Wave ou Orange Money).
/// Il reste sur le téléphone : seule son empreinte (PBKDF2, sel aléatoire) est gardée, chiffrée.
const pinLength = 4;
const maxPinAttempts = 5;

/// Retour dans l'app après ce délai en arrière-plan : le code est redemandé.
const pinRelockAfter = Duration(minutes: 2);

/// Code trop facile à deviner (0000, 1234, 4321…) : refusé à la création.
String? weakPinReason(String pin) {
  if (pin.split('').toSet().length == 1) return 'Évitez 4 chiffres identiques.';
  final d = pin.codeUnits;
  bool step(int s) => [for (var i = 1; i < d.length; i++) d[i] - d[i - 1]].every((x) => x == s);
  if (step(1) || step(-1)) return 'Évitez les suites comme 1234.';
  return null;
}

/// Empreinte « v1$sel$hash » : PBKDF2-HMAC-SHA256 (le code n'est jamais gardé en clair).
String hashPin(String pin, {List<int>? salt, int iterations = 20000}) {
  final s = salt ?? List<int>.generate(16, (_) => Random.secure().nextInt(256));
  return 'v1\$${base64Url.encode(s)}\$${base64Url.encode(_pbkdf2(utf8.encode(pin), s, iterations))}';
}

bool checkPin(String pin, String stored) {
  final parts = stored.split(r'$');
  if (parts.length != 3 || parts[0] != 'v1') return false;
  final expected = hashPin(pin, salt: base64Url.decode(parts[1]));
  // Comparaison en temps constant
  if (expected.length != stored.length) return false;
  var diff = 0;
  for (var i = 0; i < expected.length; i++) {
    diff |= expected.codeUnitAt(i) ^ stored.codeUnitAt(i);
  }
  return diff == 0;
}

List<int> _pbkdf2(List<int> password, List<int> salt, int iterations) {
  final hmac = Hmac(sha256, password);
  var u = hmac.convert([...salt, 0, 0, 0, 1]).bytes;
  final out = List<int>.from(u);
  for (var i = 1; i < iterations; i++) {
    u = hmac.convert(u).bytes;
    for (var j = 0; j < out.length; j++) {
      out[j] ^= u[j];
    }
  }
  return out;
}

/// Code enregistré : à qui il appartient, son empreinte, et les essais ratés.
class StoredPin {
  const StoredPin({required this.userId, required this.hash, this.failures = 0});
  final String userId;
  final String hash;
  final int failures;

  String encode() => jsonEncode({'u': userId, 'h': hash, 'f': failures});
  static StoredPin? decode(String? raw) {
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return StoredPin(userId: j['u'] as String, hash: j['h'] as String, failures: (j['f'] as num?)?.toInt() ?? 0);
    } catch (_) {
      return null;
    }
  }

  StoredPin withFailures(int f) => StoredPin(userId: userId, hash: hash, failures: f);
}

abstract class PinStore {
  Future<StoredPin?> read();
  Future<void> save(StoredPin pin);
  Future<void> clear();
}

class SecurePinStore implements PinStore {
  SecurePinStore([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _storage;
  static const _key = 'sama_pin';

  @override
  Future<StoredPin?> read() async => StoredPin.decode(await _storage.read(key: _key));
  @override
  Future<void> save(StoredPin pin) => _storage.write(key: _key, value: pin.encode());
  @override
  Future<void> clear() => _storage.delete(key: _key);
}

/// Tests et prévisualisations.
class MemoryPinStore implements PinStore {
  MemoryPinStore([this.pin]);
  StoredPin? pin;
  @override
  Future<StoredPin?> read() async => pin;
  @override
  Future<void> save(StoredPin p) async => pin = p;
  @override
  Future<void> clear() async => pin = null;
}

final pinStoreProvider = Provider<PinStore>((ref) => SecurePinStore());

/// Verrou actif ? (désactivé dans la plupart des tests pour ne pas passer par le code)
final pinLockEnabledProvider = Provider<bool>((ref) => true);

class PinLockState {
  const PinLockState({this.ready = false, this.pin, this.locked = true});
  final bool ready;
  final StoredPin? pin;
  final bool locked;

  int get attemptsLeft => maxPinAttempts - (pin?.failures ?? 0);
  bool hasPinFor(String userId) => pin?.userId == userId;
}

enum PinCheck { ok, wrong, blocked }

class PinLockController extends Notifier<PinLockState> {
  PinStore get _store => ref.read(pinStoreProvider);

  @override
  PinLockState build() {
    _load();
    return const PinLockState();
  }

  Future<void> _load() async {
    final pin = await _store.read();
    state = PinLockState(ready: true, pin: pin, locked: true);
  }

  /// Nouveau code (création ou changement) : l'app reste déverrouillée.
  Future<void> setPin(String userId, String pin) async {
    final stored = StoredPin(userId: userId, hash: hashPin(pin));
    await _store.save(stored);
    state = PinLockState(ready: true, pin: stored, locked: false);
  }

  /// Vérifie le code. Après [maxPinAttempts] échecs : bloqué (l'app déconnecte).
  Future<PinCheck> verify(String pin) async {
    final stored = state.pin;
    if (stored == null) return PinCheck.blocked;
    if (checkPin(pin, stored.hash)) {
      final reset = stored.withFailures(0);
      await _store.save(reset);
      state = PinLockState(ready: true, pin: reset, locked: false);
      return PinCheck.ok;
    }
    final failed = stored.withFailures(stored.failures + 1);
    await _store.save(failed);
    state = PinLockState(ready: true, pin: failed, locked: true);
    return failed.failures >= maxPinAttempts ? PinCheck.blocked : PinCheck.wrong;
  }

  /// Vérifie sans changer l'état du verrou (changement de code depuis le profil).
  bool matches(String pin) => state.pin != null && checkPin(pin, state.pin!.hash);

  void lock() {
    if (state.pin != null && !state.locked) state = PinLockState(ready: true, pin: state.pin, locked: true);
  }

  /// Déconnexion volontaire ou code oublié : le code est effacé du téléphone.
  Future<void> forget() async {
    await _store.clear();
    state = const PinLockState(ready: true, locked: true);
  }
}

final pinLockProvider = NotifierProvider<PinLockController, PinLockState>(PinLockController.new);
