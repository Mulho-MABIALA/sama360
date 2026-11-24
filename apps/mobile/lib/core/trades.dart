import 'models.dart';

/// Métiers proposés à la création de l'entreprise (clé enregistrée → libellé).
const tradeLabels = {
  'boutique': 'Boutique',
  'mode': 'Habits & chaussures',
  'cosmetique': 'Parfumerie & cosmétique',
  'quincaillerie': 'Quincaillerie',
  'alimentation': 'Alimentation',
  'telephonie': 'Téléphones & électronique',
  'restaurant': 'Restaurant',
  'salon': 'Salon / beauté',
  'prestataire': 'Prestataire',
  'autre': 'Autre',
};

/// Services qu'on peut ajouter ou retirer de l'accueil (mêmes clés que l'API : shared/services.ts).
/// Ventes, caisse, stock, clients, dépenses et rapports sont toujours là.
enum BizService {
  invoices('invoices', 'Factures et devis', 'Pour les clients qui demandent une facture'),
  purchases('purchases', 'Achats fournisseurs', 'Commandes au fournisseur, arrivage, dettes'),
  delivery('delivery', 'Livraison', 'Courses confiées à vos livreurs'),
  shop('shop', 'Boutique en ligne', 'Vos produits sur un lien et en statut WhatsApp'),
  booking('booking', 'Réservation', 'Rendez-vous et réservations de vos clients'),
  loyalty('loyalty', 'Fidélité', 'Points et récompenses pour les habitués'),
  reminders('reminders', 'Relances', 'Rappeler les clients qui vous doivent'),
  documents('documents', 'Documents', 'Bail, NINEA, contrats, rappels d’échéance'),
  team('team', 'Équipe', 'Vendeurs et gérants'),
  assistant('assistant', 'Assistant IA', 'Posez une question sur votre commerce');

  const BizService(this.key, this.label, this.hint);
  final String key;
  final String label;
  final String hint;

  static BizService? of(String key) => values.where((s) => s.key == key).firstOrNull;
}

/// Ce dont chaque métier a besoin au départ : la boutique d'habits n'a pas de réservation,
/// le restaurant et le salon en ont une. Le commerçant peut toujours en ajouter ou en retirer.
Set<BizService> defaultServices(String? trade, {String? focus}) {
  final all = BizService.values.toSet();
  final s = switch (trade) {
    'boutique' || 'mode' || 'cosmetique' || 'alimentation' || 'telephonie' => all.difference({BizService.booking}),
    'quincaillerie' => all.difference({BizService.booking, BizService.loyalty}),
    'restaurant' => all.difference({BizService.invoices}),
    'salon' => all.difference({BizService.delivery, BizService.purchases}),
    'prestataire' => all.difference({BizService.delivery, BizService.purchases, BizService.loyalty}),
    _ => all,
  };
  // Activité de services sans métier précis : les rendez-vous comptent
  return focus == 'services' || focus == 'both' ? {...s, BizService.booking} : s;
}

/// Services affichés pour cette entreprise : son choix, sinon ce que demande son métier.
Set<BizService> enabledServices(CurrentBusiness? b) {
  if (b == null) return BizService.values.toSet();
  final chosen = b.services;
  if (chosen != null) return {for (final k in chosen) ?BizService.of(k)};
  return defaultServices(b.category, focus: b.focus);
}

/// Champs propres au métier dans la fiche produit.
enum TradeField { extras, expiry, serial }

/// Un métier précis ne voit que ses champs ; « Autre » ou sans métier : tous.
bool tradeShows(String? trade, TradeField f) => switch (trade) {
  'restaurant' => f == TradeField.extras || f == TradeField.expiry,
  'alimentation' || 'cosmetique' => f == TradeField.expiry, // parfums, crèmes : date de péremption
  'telephonie' => f == TradeField.serial,
  'quincaillerie' => f == TradeField.serial, // garantie des outils et machines
  'boutique' => f == TradeField.expiry || f == TradeField.serial,
  'mode' => false,
  'salon' => f == TradeField.expiry,
  'prestataire' => false,
  _ => true,
};
