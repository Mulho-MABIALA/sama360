import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

/// Ce que le téléphone propose pour remplacer le code secret.
enum BiometricKind {
  face('Face ID', 'Déverrouiller avec Face ID'),
  fingerprint('Empreinte digitale', 'Déverrouiller avec l’empreinte');

  const BiometricKind(this.label, this.action);
  final String label;
  final String action;
}

abstract class Biometrics {
  /// null : rien d'enregistré sur ce téléphone (ou web).
  Future<BiometricKind?> kind();

  /// Vrai si la personne s'est identifiée ; faux si annulé, raté ou indisponible.
  Future<bool> authenticate(String reason);
}

class DeviceBiometrics implements Biometrics {
  final _auth = LocalAuthentication();

  @override
  Future<BiometricKind?> kind() async {
    if (kIsWeb) return null;
    try {
      if (!await _auth.isDeviceSupported() || !await _auth.canCheckBiometrics) return null;
      final types = await _auth.getAvailableBiometrics();
      if (types.isEmpty) return null;
      return types.contains(BiometricType.face) && !types.contains(BiometricType.fingerprint)
          ? BiometricKind.face
          : BiometricKind.fingerprint;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    if (kIsWeb) return false;
    try {
      return await _auth.authenticate(localizedReason: reason, biometricOnly: true, persistAcrossBackgrounding: true);
    } catch (_) {
      return false; // capteur bloqué, annulé… : on retombe sur le code
    }
  }
}

final biometricsProvider = Provider<Biometrics>((ref) => DeviceBiometrics());

final biometricKindProvider = FutureProvider<BiometricKind?>((ref) => ref.watch(biometricsProvider).kind());
