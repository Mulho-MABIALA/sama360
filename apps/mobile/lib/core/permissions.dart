/// Même règle que le serveur (packages/contracts) : `*`, `domaine:*` ou permission exacte.
bool hasPermission(List<String> granted, String required) {
  if (granted.contains('*') || granted.contains(required)) return true;
  final domain = required.split(':').first;
  return granted.contains('$domain:*');
}

/// Prix d'achat, marges et valeur du stock : propriétaire, gérant et comptable (comme le serveur).
bool seesCosts(List<String> granted) =>
    hasPermission(granted, 'reports:read') || hasPermission(granted, 'catalog:write');

/// Droit nécessaire pour ouvrir un écran (du plus précis au plus général). null = ouvert à tous.
const _routeRules = <(String, String)>[
  (r'^/purchases/(new|scan)$', 'purchasing:write'),
  (r'^/purchases/[^/]+/edit$', 'purchasing:write'),
  (r'^/suppliers/(new|[^/]+/edit)$', 'purchasing:write'),
  (r'^/(purchases|suppliers)(/|$)', 'purchasing:read'),
  (r'^/(reports|insights)(/|$)', 'reports:read'),
  (r'^/team(/|$)', 'members:read'),
  (r'^/documents(/|$)', 'documents:read'),
  (r'^/locations(/|$)', 'business:update'),
  (r'^/stock/transfer$', 'inventory:write'),
  (r'^/stock(/|$)', 'inventory:read'),
  (r'^/products/new$', 'catalog:write'),
  (r'^/categories(/|$)', 'catalog:read'),
  (r'^/invoices/(new|[^/]+/edit)$', 'invoicing:write'),
  (r'^/invoices(/|$)', 'invoicing:read'),
  (r'^/customers/(new|[^/]+/edit)$', 'contacts:write'),
  (r'^/customers(/|$)', 'contacts:read'),
  (r'^/(reminders|loyalty)(/|$)', 'contacts:read'),
  (r'^/sales(/|$)', 'sales:read'),
  (r'^/(pos|cash)(/|$)', 'sales:create'),
];

String? permissionFor(String location) {
  for (final (pattern, perm) in _routeRules) {
    if (RegExp(pattern).hasMatch(location)) return perm;
  }
  return null;
}

/// Écran interdit pour ce rôle : renvoie vers « Accès réservé » (null = autorisé ou droits pas encore connus).
String? accessRedirect(List<String>? granted, String location) {
  if (granted == null || location == '/denied') return null;
  final perm = permissionFor(location);
  if (perm == null || hasPermission(granted, perm)) return null;
  return '/denied';
}
