import 'package:flutter/foundation.dart';

const _apiUrlOverride = String.fromEnvironment('API_URL');

/// API en ligne (Render, voir DEPLOY.md) : utilisée par les versions publiées sans --dart-define.
const productionApiUrl = 'https://sama360-api.onrender.com';

/// Adresse de l'API Sama360.
///
/// Par défaut :
/// - émulateur Android : http://10.0.2.2:3000 (le PC hôte vu depuis l'émulateur) ;
/// - Chrome, Windows, iOS (simulateur) : http://localhost:3000.
/// Sur un vrai téléphone (même Wi-Fi que le PC), lancer avec :
///   flutter run --dart-define=API_URL=http://192.168.x.x:3000
/// Version publiée (flutter build --release) : l'API en ligne, jamais le PC de développement ;
/// sur le web, l'adresse d'où la page est servie.
String get apiUrl {
  if (_apiUrlOverride.isNotEmpty) return _apiUrlOverride;
  // Version web servie par l'API elle-même (http://<pc>:3000/app/) : même adresse que la page.
  if (kIsWeb && kReleaseMode) return Uri.base.origin;
  if (kReleaseMode) return productionApiUrl;
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) return 'http://10.0.2.2:3000';
  return 'http://localhost:3000';
}
