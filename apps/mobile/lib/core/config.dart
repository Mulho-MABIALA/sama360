/// Adresse de l'API Sama360.
///
/// Par défaut : l'émulateur Android joint le PC hôte via 10.0.2.2.
/// Sur un vrai téléphone (même Wi-Fi que le PC), lancer avec :
///   flutter run --dart-define=API_URL=http://192.168.x.x:3000
const String apiUrl = String.fromEnvironment('API_URL', defaultValue: 'http://10.0.2.2:3000');
