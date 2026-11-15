/// Même règle que le serveur (packages/contracts) : `*`, `domaine:*` ou permission exacte.
bool hasPermission(List<String> granted, String required) {
  if (granted.contains('*') || granted.contains(required)) return true;
  final domain = required.split(':').first;
  return granted.contains('$domain:*');
}
