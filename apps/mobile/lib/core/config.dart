import 'package:flutter/foundation.dart';

const _apiUrlOverride = String.fromEnvironment('API_URL');

/// Adresse de l'API Sama360.
///
/// Par défaut :
/// - émulateur Android : http://10.0.2.2:3000 (le PC hôte vu depuis l'émulateur) ;
/// - Chrome, Windows, iOS (simulateur) : http://localhost:3000.
/// Sur un vrai téléphone (même Wi-Fi que le PC), lancer avec :
///   flutter run --dart-define=API_URL=http://192.168.x.x:3000
String get apiUrl {
  if (_apiUrlOverride.isNotEmpty) return _apiUrlOverride;
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) return 'http://10.0.2.2:3000';
  return 'http://localhost:3000';
}
