/// Modèles alignés sur les réponses de l'API Sama360 (apps/api).
library;

import 'countries.dart';

export 'countries.dart' show Country;

int _int(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
double _num(Object? v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
double _dbl(Object? v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
DateTime? _date(Object? v) => v == null ? null : DateTime.tryParse('$v');

class Me {
  const Me({
    required this.id,
    required this.phone,
    this.fullName,
    this.email,
    this.avatarFileId,
    this.createdAt,
    this.businesses = const [],
  });
  final String id;
  final String phone;
  final String? fullName;
  final String? email;
  final String? avatarFileId;
  final DateTime? createdAt;
  final List<BusinessLink> businesses;

  factory Me.fromJson(Map<String, dynamic> j) {
    final u = j['user'] as Map<String, dynamic>;
    return Me(
      id: u['id'] as String,
      phone: u['phone'] as String,
      fullName: u['fullName'] as String?,
      email: u['email'] as String?,
      avatarFileId: u['avatarFileId'] as String?,
      createdAt: _date(u['createdAt']),
      businesses: ((j['businesses'] as List?) ?? const [])
          .map((b) => BusinessLink.fromJson(b as Map<String, dynamic>))
          .toList(),
    );
  }

  bool get needsProfile => (fullName ?? '').trim().isEmpty;
}

/// Entreprise à laquelle l'utilisateur a accès (sélecteur).
class BusinessLink {
  const BusinessLink({required this.id, required this.name, this.category, required this.role, required this.roleName});
  final String id;
  final String name;
  final String? category;
  final String role;
  final String roleName;

  factory BusinessLink.fromJson(Map<String, dynamic> j) => BusinessLink(
    id: j['id'] as String,
    name: j['name'] as String,
    category: j['category'] as String?,
    role: j['role'] as String,
    roleName: j['roleName'] as String? ?? j['role'] as String,
  );
}

/// Entreprise courante (GET /v1/business) avec mes droits.
class CurrentBusiness {
  const CurrentBusiness({
    required this.id,
    required this.name,
    required this.slug,
    this.city,
    this.phone,
    this.address,
    this.ninea,
    this.logoFileId,
    this.brandColor,
    this.requireOpenCash = false,
    this.focus,
    this.country = Country.sn,
    this.proUntil,
    this.trial = false,
    required this.role,
    required this.permissions,
    required this.modules,
  });
  final String id;
  final String name;
  final String slug;
  final String? city;
  final String? phone;
  final String? address;
  final String? ninea;
  final String? logoFileId;

  /// Couleur choisie par le commerçant (« #0A7E4F ») : accents de l'app, reçus, boutique en ligne.
  final String? brandColor;

  /// Option du patron : la caisse doit être ouverte pour vendre.
  final bool requireOpenCash;

  /// Activité : « products », « services », « both » (null : pas encore choisie).
  final String? focus;

  /// Pays : indicatif des numéros, paiements mobiles, identifiant fiscal.
  final Country country;

  /// Fin de Sama360 Pro (essai ou abonnement) ; null = jamais Pro.
  final DateTime? proUntil;

  /// Pro offert pour découvrir (30 jours à l'inscription).
  final bool trial;

  /// Pro actif : boutique en ligne, vendeurs, livraisons, assistant…
  bool get isPro => proUntil != null && proUntil!.isAfter(DateTime.now());

  /// Jours de Pro restants (arrondis au-dessus), 0 si terminé.
  int get proDaysLeft => isPro ? (proUntil!.difference(DateTime.now()).inHours / 24).ceil() : 0;
  final String role;
  final List<String> permissions;
  final List<String> modules;

  factory CurrentBusiness.fromJson(Map<String, dynamic> j) {
    final b = j['business'] as Map<String, dynamic>;
    final me = j['me'] as Map<String, dynamic>;
    return CurrentBusiness(
      id: b['id'] as String,
      name: b['name'] as String,
      slug: b['slug'] as String,
      city: b['city'] as String?,
      phone: b['phone'] as String?,
      address: b['address'] as String?,
      ninea: b['ninea'] as String?,
      logoFileId: b['logoFileId'] as String?,
      brandColor: b['brandColor'] as String?,
      requireOpenCash: b['requireOpenCash'] == true,
      focus: (b['settings'] as Map?)?['focus'] as String?,
      country: Country.fromCode(b['country'] as String?),
      proUntil: _proUntil(j['subscription'] as Map?),
      trial: (j['subscription'] as Map?)?['status'] == 'trialing',
      role: me['role'] as String,
      permissions: List<String>.from(me['permissions'] as List),
      modules: ((j['modules'] as List?) ?? const [])
          .where((m) => (m as Map)['enabled'] == true)
          .map((m) => (m as Map)['module'] as String)
          .toList(),
    );
  }
}

DateTime? _proUntil(Map? sub) {
  if (sub == null || sub['plan'] != 'pro' || sub['currentPeriodEnd'] == null) return null;
  return DateTime.tryParse(sub['currentPeriodEnd'] as String);
}

// ───────────────────────────────────────── Sama360 Pro et parrainage

/// Fonctions réservées à Pro (mêmes clés que l'API : shared/plans.ts).
enum ProFeature {
  team('team', 'Vendeurs et gérants'),
  shop('shop', 'Boutique en ligne et statuts WhatsApp'),
  delivery('delivery', 'Livraisons et livreurs'),
  bookingOnline('booking_online', 'Réservation en ligne'),
  insights('insights', 'Statistiques avancées et rapport de la semaine'),
  assistant('assistant', 'Assistant IA'),
  documents('documents', 'Coffre de documents'),
  invoiceScan('invoice_scan', 'Facture fournisseur en photo'),
  multiShop('multi_shop', 'Plusieurs points de vente');

  const ProFeature(this.key, this.label);
  final String key;
  final String label;

  static ProFeature? of(String? key) => values.where((f) => f.key == key).firstOrNull;
}

enum ProState { trial, active, expired, free }

class PaymentRequest {
  const PaymentRequest({
    required this.id,
    required this.cycle,
    required this.amount,
    required this.method,
    required this.reference,
    required this.status,
    required this.createdAt,
    this.payerPhone,
    this.note,
    this.businessName,
    this.businessCountry,
    this.businessCity,
    this.businessPhone,
  });

  final String id;
  final String cycle; // monthly | yearly
  final int amount;
  final PayMethod method;
  final String reference;
  final String status; // pending | approved | rejected
  final DateTime createdAt;
  final String? payerPhone;
  final String? note;
  // Côté équipe Sama360
  final String? businessName;
  final Country? businessCountry;
  final String? businessCity;
  final String? businessPhone;

  bool get pending => status == 'pending';
  bool get yearly => cycle == 'yearly';

  factory PaymentRequest.fromJson(Map<String, dynamic> j) {
    final b = j['business'] as Map<String, dynamic>?;
    return PaymentRequest(
      id: j['id'] as String,
      cycle: j['cycle'] as String,
      amount: (j['amount'] as num).toInt(),
      method: PayMethod.fromApi(j['method'] as String) ?? PayMethod.wave,
      reference: j['reference'] as String,
      status: j['status'] as String,
      createdAt: DateTime.parse(j['createdAt'] as String),
      payerPhone: j['payerPhone'] as String?,
      note: j['note'] as String?,
      businessName: b?['name'] as String?,
      businessCountry: b == null ? null : Country.fromCode(b['country'] as String?),
      businessCity: b?['city'] as String?,
      businessPhone: b?['phone'] as String?,
    );
  }
}

class ProStatus {
  const ProStatus({
    required this.pro,
    required this.state,
    required this.daysLeft,
    required this.monthly,
    required this.yearly,
    required this.methods,
    this.endsAt,
    this.currency = 'XOF',
    this.payTo,
    this.pending,
    this.history = const [],
    this.referralCode,
  });

  final bool pro;
  final ProState state;
  final DateTime? endsAt;
  final int daysLeft;
  final String currency;
  final int monthly;
  final int yearly;
  final String? payTo;
  final List<PayMethod> methods;
  final PaymentRequest? pending;
  final List<PaymentRequest> history;
  final String? referralCode;

  /// Dernière demande refusée (affichée tant qu'aucune autre n'a suivi).
  PaymentRequest? get lastRejected => history.isNotEmpty && history.first.status == 'rejected' ? history.first : null;

  factory ProStatus.fromJson(Map<String, dynamic> j) {
    final prices = j['prices'] as Map<String, dynamic>;
    return ProStatus(
      pro: j['pro'] == true,
      state: ProState.values.byName(j['state'] as String),
      endsAt: j['endsAt'] == null ? null : DateTime.parse(j['endsAt'] as String),
      daysLeft: (j['daysLeft'] as num?)?.toInt() ?? 0,
      currency: j['currency'] as String? ?? 'XOF',
      monthly: (prices['monthly'] as num).toInt(),
      yearly: (prices['yearly'] as num).toInt(),
      payTo: j['payTo'] as String?,
      methods: [for (final m in (j['methods'] as List? ?? const [])) ?PayMethod.fromApi(m as String)],
      pending: j['pending'] == null ? null : PaymentRequest.fromJson(j['pending'] as Map<String, dynamic>),
      history: [
        for (final h in (j['history'] as List? ?? const [])) PaymentRequest.fromJson(h as Map<String, dynamic>),
      ],
      referralCode: j['referralCode'] as String?,
    );
  }
}

class Referral {
  const Referral({required this.name, required this.joinedAt, required this.rewarded, this.city});
  final String name;
  final String? city;
  final DateTime joinedAt;
  final bool rewarded;
}

class ReferralInfo {
  const ReferralInfo({required this.code, required this.bonusDays, required this.daysEarned, required this.referrals});
  final String code;
  final int bonusDays;
  final int daysEarned;
  final List<Referral> referrals;

  factory ReferralInfo.fromJson(Map<String, dynamic> j) => ReferralInfo(
    code: j['code'] as String,
    bonusDays: (j['bonusDays'] as num).toInt(),
    daysEarned: (j['daysEarned'] as num).toInt(),
    referrals: [
      for (final r in (j['referrals'] as List))
        Referral(
          name: (r as Map)['name'] as String,
          city: r['city'] as String?,
          joinedAt: DateTime.parse(r['joinedAt'] as String),
          rewarded: r['rewarded'] == true,
        ),
    ],
  );
}

class Category {
  const Category({required this.id, required this.name, this.productCount = 0});
  final String id;
  final String name;
  final int productCount;
  factory Category.fromJson(Map<String, dynamic> j) =>
      Category(id: j['id'] as String, name: j['name'] as String, productCount: _int(j['productCount']));
}

/// Unités proposées dans la fiche produit.
const productUnits = ['pièce', 'kg', 'g', 'litre', 'mètre', 'paquet', 'sac', 'carton', 'boîte', 'sachet', 'heure'];

class Product {
  const Product({
    required this.id,
    required this.name,
    required this.price,
    required this.cost,
    this.categoryId,
    this.trackStock = true,
    this.lowStockThreshold = 5,
    this.imageFileId,
    this.isService = false,
    this.durationMinutes,
    this.unit = 'pièce',
    this.barcode,
    this.sku,
    this.wholesalePrice,
    this.wholesaleMinQty,
    this.published = false,
  });
  final String id;
  final String name;
  final int price;
  final int cost;
  final String? categoryId;

  /// Visible dans la boutique en ligne.
  final bool published;
  final bool trackStock;
  final int lowStockThreshold;
  final String? imageFileId; // photo principale (GET /v1/files/:id)
  final bool isService;

  /// Prestation : durée d'un rendez-vous (réservation en ligne).
  final int? durationMinutes;
  final String unit;
  final String? barcode;
  final String? sku;

  /// Prix de gros, à partir de [wholesaleMinQty] unités.
  final int? wholesalePrice;
  final double? wholesaleMinQty;

  bool get hasWholesale => wholesalePrice != null && wholesaleMinQty != null;

  /// Prix unitaire pour une quantité (même règle que le serveur).
  int unitPriceFor(double quantity) => hasWholesale && quantity >= wholesaleMinQty! ? wholesalePrice! : price;

  /// Marge en % du prix de vente.
  int get marginPct => price == 0 ? 0 : (((price - cost) / price) * 100).round();

  factory Product.fromJson(Map<String, dynamic> j) => Product(
    id: j['id'] as String,
    name: j['name'] as String,
    price: _int(j['price']),
    cost: _int(j['cost']),
    categoryId: j['categoryId'] as String?,
    trackStock: j['trackStock'] as bool? ?? true,
    lowStockThreshold: _int(j['lowStockThreshold']),
    imageFileId: ((j['imageFileIds'] as List?) ?? const []).cast<String>().firstOrNull,
    isService: j['type'] == 'service',
    durationMinutes: (j['durationMinutes'] as num?)?.toInt(),
    unit: j['unit'] as String? ?? 'pièce',
    barcode: j['barcode'] as String?,
    sku: j['sku'] as String?,
    wholesalePrice: j['wholesalePrice'] == null ? null : _int(j['wholesalePrice']),
    wholesaleMinQty: j['wholesaleMinQty'] == null ? null : _num(j['wholesaleMinQty']),
    published: j['published'] as bool? ?? false,
  );
}

/// Fiche produit en cours de saisie (création ou modification).
class ProductDraft {
  const ProductDraft({
    required this.name,
    required this.price,
    this.cost = 0,
    this.categoryId,
    this.isService = false,
    this.durationMinutes,
    this.unit = 'pièce',
    this.barcode,
    this.sku,
    this.trackStock = true,
    this.lowStockThreshold = 5,
    this.wholesalePrice,
    this.wholesaleMinQty,
    this.published,
  });
  final String name;
  final int price;

  /// null : ne change pas la visibilité en ligne.
  final bool? published;
  final int cost;
  final String? categoryId;
  final bool isService;
  final int? durationMinutes;
  final String unit;
  final String? barcode;
  final String? sku;
  final bool trackStock;
  final int lowStockThreshold;
  final int? wholesalePrice;
  final double? wholesaleMinQty;

  Map<String, dynamic> toJson() => {
    'type': isService ? 'service' : 'product',
    'name': name.trim(),
    'price': price,
    'cost': cost,
    'categoryId': categoryId,
    'unit': unit,
    'barcode': (barcode ?? '').trim().isEmpty ? null : barcode!.trim(),
    'sku': (sku ?? '').trim().isEmpty ? null : sku!.trim(),
    'trackStock': !isService && trackStock,
    'lowStockThreshold': lowStockThreshold,
    'wholesalePrice': wholesalePrice,
    'wholesaleMinQty': wholesaleMinQty,
    if (isService) 'durationMinutes': durationMinutes,
    'published': ?published,
  };
}

class StockItem {
  const StockItem({
    required this.productId,
    required this.name,
    required this.price,
    required this.cost,
    required this.threshold,
    required this.onHand,
    required this.low,
    this.imageFileId,
    this.byLocation = const {},
  });
  final String productId;
  final String name;
  final int price;
  final int cost;
  final int threshold;
  final double onHand;
  final bool low;
  final String? imageFileId;

  /// Quantité par point de vente (id → quantité), quand on regarde tous les points de vente.
  final Map<String, double> byLocation;

  factory StockItem.fromJson(Map<String, dynamic> j) => StockItem(
    productId: j['productId'] as String,
    name: j['name'] as String,
    price: _int(j['price']),
    cost: _int(j['cost']),
    threshold: _int(j['threshold']),
    onHand: _num(j['onHand']),
    low: j['low'] as bool? ?? false,
    imageFileId: j['imageFileId'] as String?,
    byLocation: {for (final e in ((j['byLocation'] as Map?) ?? const {}).entries) e.key as String: _num(e.value)},
  );

  int get margin => price == 0 ? 0 : (((price - cost) / price) * 100).round();

  StockItem copyWith({double? onHand, bool? low}) => StockItem(
    productId: productId,
    name: name,
    price: price,
    cost: cost,
    threshold: threshold,
    onHand: onHand ?? this.onHand,
    low: low ?? this.low,
    imageFileId: imageFileId,
    byLocation: byLocation,
  );
}

class StockOverview {
  const StockOverview({required this.items, required this.lowStock, required this.stockValue});
  final List<StockItem> items;
  final int lowStock;
  final int stockValue;

  factory StockOverview.fromJson(Map<String, dynamic> j) {
    final t = j['totals'] as Map<String, dynamic>;
    return StockOverview(
      items: (j['items'] as List).map((e) => StockItem.fromJson(e as Map<String, dynamic>)).toList(),
      lowStock: _int(t['lowStock']),
      stockValue: _int(t['stockValue']),
    );
  }
}

class DaySummary {
  const DaySummary({
    required this.salesCount,
    required this.revenue,
    required this.grossProfit,
    required this.netProfit,
    required this.expenses,
    required this.collected,
    required this.receivables,
    this.bySeller = const [],
    this.last7Days = const [],
    this.previous7DaysRevenue = 0,
    this.byLocation = const [],
  });
  final int salesCount;
  final int revenue;
  final int grossProfit;
  final int netProfit;
  final int expenses;
  final int collected;
  final int receivables;

  /// Ventes du jour par vendeur, du plus gros chiffre au plus petit.
  final List<SellerStat> bySeller;

  /// Chiffre d'affaires des 7 derniers jours (le dernier = aujourd'hui) et des 7 jours d'avant.
  final List<int> last7Days;
  final int previous7DaysRevenue;

  /// Chiffre du jour de chaque point de vente (tous les points de vente regardés).
  final List<LocationStat> byLocation;

  factory DaySummary.fromJson(Map<String, dynamic> j) => DaySummary(
    salesCount: _int(j['salesCount']),
    revenue: _int(j['revenue']),
    grossProfit: _int(j['grossProfit']),
    netProfit: _int(j['netProfit']),
    expenses: _int(j['expenses']),
    collected: _int(j['collected']),
    receivables: _int(j['receivables']),
    bySeller: [for (final v in (j['bySeller'] as List?) ?? const []) SellerStat.fromJson(v as Map<String, dynamic>)],
    last7Days: [for (final d in (j['last7Days'] as List?) ?? const []) _int((d as Map)['revenue'])],
    previous7DaysRevenue: _int(j['previous7DaysRevenue']),
    byLocation: [
      for (final l in (j['byLocation'] as List?) ?? const [])
        LocationStat(
          id: (l as Map)['locationId'] as String,
          name: l['name'] as String? ?? '',
          salesCount: _int(l['salesCount']),
          revenue: _int(l['revenue']),
        ),
    ],
  );
}

class LocationStat {
  const LocationStat({required this.id, required this.name, required this.salesCount, required this.revenue});
  final String id;
  final String name;
  final int salesCount;
  final int revenue;
}

class SellerStat {
  const SellerStat({
    required this.userId,
    required this.name,
    this.avatarFileId,
    required this.salesCount,
    required this.revenue,
  });
  final String userId;
  final String name;
  final String? avatarFileId;
  final int salesCount;
  final int revenue;

  factory SellerStat.fromJson(Map<String, dynamic> j) => SellerStat(
    userId: j['userId'] as String,
    name: j['name'] as String? ?? '',
    avatarFileId: j['avatarFileId'] as String?,
    salesCount: _int(j['salesCount']),
    revenue: _int(j['revenue']),
  );
}

/// « Ma journée » du vendeur connecté (sans coûts ni bénéfices).
class MyDay {
  const MyDay({required this.salesCount, required this.revenue, required this.collected});
  final int salesCount;
  final int revenue;
  final int collected;

  factory MyDay.fromJson(Map<String, dynamic> j) =>
      MyDay(salesCount: _int(j['salesCount']), revenue: _int(j['revenue']), collected: _int(j['collected']));
}

/// Rôles proposés à l'invitation (le propriétaire ne s'invite pas).
enum TeamRole {
  manager('manager', 'Gérant', 'Gère tout sauf l’abonnement : ventes, stock, clients, rapports, invitations.'),
  cashier(
    'cashier',
    'Vendeur / caissier',
    'Vend et encaisse, voit le stock et les clients. Ne voit pas les bénéfices.',
  ),
  accountant('accountant', 'Comptable', 'Consulte les ventes, les rapports et les factures. Ne vend pas.');

  const TeamRole(this.api, this.label, this.description);
  final String api;
  final String label;
  final String description;

  static TeamRole? fromApi(String? v) => TeamRole.values.where((r) => r.api == v).firstOrNull;
}

/// Membre de l'équipe (adhésion à l'entreprise).
class Member {
  const Member({
    required this.id,
    required this.userId,
    required this.phone,
    this.fullName,
    required this.role,
    required this.roleName,
    required this.status,
    this.avatarFileId,
    this.locationId,
  });
  final String id;
  final String userId;
  final String phone;
  final String? fullName;
  final String role;
  final String roleName;
  final String status; // active, invited, suspended
  final String? avatarFileId;

  /// Point de vente auquel le membre est rattaché ; null = tous.
  final String? locationId;

  bool get isOwner => role == 'owner';
  String get displayName => (fullName ?? '').trim().isEmpty ? phone : fullName!;

  factory Member.fromJson(Map<String, dynamic> j) => Member(
    id: j['id'] as String,
    userId: j['userId'] as String,
    phone: j['phone'] as String,
    fullName: j['fullName'] as String?,
    role: j['role'] as String,
    roleName: j['roleName'] as String? ?? j['role'] as String,
    status: j['status'] as String? ?? 'active',
    avatarFileId: j['avatarFileId'] as String?,
    locationId: j['locationId'] as String?,
  );
}

class Contact {
  const Contact({
    required this.id,
    required this.name,
    this.phone,
    this.balance = 0,
    this.email,
    this.address,
    this.notes,
    this.creditLimit,
    this.lastRemindedAt,
    this.birthDay,
    this.birthMonth,
  });
  final String id;
  final String name;
  final String? phone;
  final int balance;

  /// Anniversaire (jour, mois), sans l'année.
  final int? birthDay;
  final int? birthMonth;
  final String? email;
  final String? address;
  final String? notes;

  /// Plafond de crédit en FCFA ; null : pas de plafond.
  final int? creditLimit;
  final DateTime? lastRemindedAt;

  factory Contact.fromJson(Map<String, dynamic> j) => Contact(
    id: j['id'] as String,
    name: j['name'] as String,
    phone: j['phone'] as String?,
    email: j['email'] as String?,
    address: j['address'] as String?,
    notes: j['notes'] as String?,
    balance: _int(j['balance']),
    creditLimit: j['creditLimit'] == null ? null : _int(j['creditLimit']),
    lastRemindedAt: _date(j['lastRemindedAt']),
    birthDay: j['birthDay'] == null ? null : _int(j['birthDay']),
    birthMonth: j['birthMonth'] == null ? null : _int(j['birthMonth']),
  );
}

/// Saisie d'une fiche client (création ou modification).
class CustomerDraft {
  const CustomerDraft({
    required this.name,
    this.phone,
    this.email,
    this.address,
    this.notes,
    this.creditLimit,
    this.birthDay,
    this.birthMonth,
  });
  final String name;
  final String? phone;
  final String? email;
  final String? address;
  final String? notes;
  final int? creditLimit;
  final int? birthDay;
  final int? birthMonth;

  Map<String, dynamic> toJson({bool withLimit = true}) => {
    'name': name,
    'phone': phone,
    'email': email,
    'address': address,
    'notes': notes,
    if (withLimit) 'creditLimit': creditLimit,
    'birthDay': birthDay,
    'birthMonth': birthMonth,
  };
}

enum CustomerFilter {
  all('all', 'Tous'),
  debt('debt', 'Doivent de l’argent'),
  overLimit('over_limit', 'Plafond dépassé');

  const CustomerFilter(this.api, this.label);
  final String api;
  final String label;
}

enum CustomerSort {
  name('name', 'Nom'),
  balance('balance', 'Plus grosse dette'),
  recent('recent', 'Achat le plus récent');

  const CustomerSort(this.api, this.label);
  final String api;
  final String label;
}

/// Ligne de l'annuaire clients.
class CustomerRow {
  const CustomerRow({
    required this.id,
    required this.name,
    this.phone,
    required this.balance,
    this.creditLimit,
    this.salesCount = 0,
    this.totalSpent = 0,
    this.lastPurchaseAt,
    this.firstDebtAt,
    this.lastRemindedAt,
  });
  final String id;
  final String name;
  final String? phone;
  final int balance;
  final int? creditLimit;
  final int salesCount;
  final int totalSpent;
  final DateTime? lastPurchaseAt;
  final DateTime? firstDebtAt;
  final DateTime? lastRemindedAt;

  bool get overLimit => creditLimit != null && balance > creditLimit!;

  Contact toContact() => Contact(id: id, name: name, phone: phone, balance: balance, creditLimit: creditLimit);

  factory CustomerRow.fromJson(Map<String, dynamic> j) => CustomerRow(
    id: j['id'] as String,
    name: j['name'] as String,
    phone: j['phone'] as String?,
    balance: _int(j['balance']),
    creditLimit: j['creditLimit'] == null ? null : _int(j['creditLimit']),
    salesCount: _int(j['salesCount']),
    totalSpent: _int(j['totalSpent']),
    lastPurchaseAt: _date(j['lastPurchaseAt']),
    firstDebtAt: _date(j['firstDebtAt']),
    lastRemindedAt: _date(j['lastRemindedAt']),
  );
}

class CustomerTotals {
  const CustomerTotals({this.customers = 0, this.debtors = 0, this.totalDue = 0, this.overLimit = 0});
  final int customers;
  final int debtors;
  final int totalDue;
  final int overLimit;

  factory CustomerTotals.fromJson(Map<String, dynamic> j) => CustomerTotals(
    customers: _int(j['customers']),
    debtors: _int(j['debtors']),
    totalDue: _int(j['totalDue']),
    overLimit: _int(j['overLimit']),
  );
}

class CustomerList {
  const CustomerList({required this.data, required this.totals, this.nextOffset});
  final List<CustomerRow> data;
  final CustomerTotals totals;
  final int? nextOffset;

  factory CustomerList.fromJson(Map<String, dynamic> j) => CustomerList(
    data: (j['data'] as List).map((e) => CustomerRow.fromJson(e as Map<String, dynamic>)).toList(),
    totals: CustomerTotals.fromJson(j['totals'] as Map<String, dynamic>),
    nextOffset: j['nextOffset'] == null ? null : _int(j['nextOffset']),
  );
}

class CustomerStats {
  const CustomerStats({
    this.salesCount = 0,
    this.totalSpent = 0,
    this.totalPaid = 0,
    this.averageBasket = 0,
    this.firstPurchaseAt,
    this.lastPurchaseAt,
    this.openInvoices = 0,
    this.openInvoicesDue = 0,
  });
  final int salesCount;
  final int totalSpent;
  final int totalPaid;
  final int averageBasket;
  final DateTime? firstPurchaseAt;
  final DateTime? lastPurchaseAt;
  final int openInvoices;
  final int openInvoicesDue;

  factory CustomerStats.fromJson(Map<String, dynamic> j) => CustomerStats(
    salesCount: _int(j['salesCount']),
    totalSpent: _int(j['totalSpent']),
    totalPaid: _int(j['totalPaid']),
    averageBasket: _int(j['averageBasket']),
    firstPurchaseAt: _date(j['firstPurchaseAt']),
    lastPurchaseAt: _date(j['lastPurchaseAt']),
    openInvoices: _int(j['openInvoices']),
    openInvoicesDue: _int(j['openInvoicesDue']),
  );
}

class CustomerSale {
  const CustomerSale({
    required this.id,
    required this.number,
    required this.total,
    required this.due,
    required this.status,
    required this.soldAt,
    this.itemCount = 0,
  });
  final String id;
  final String number;
  final int total;
  final int due;
  final String status;
  final DateTime soldAt;
  final int itemCount;

  factory CustomerSale.fromJson(Map<String, dynamic> j) => CustomerSale(
    id: j['id'] as String,
    number: j['number'] as String,
    total: _int(j['total']),
    due: _int(j['due']),
    status: j['status'] as String? ?? 'completed',
    soldAt: _date(j['soldAt']) ?? DateTime.now(),
    itemCount: _int(j['itemCount']),
  );
}

class CustomerTopProduct {
  const CustomerTopProduct({required this.name, required this.quantity, required this.total});
  final String name;
  final double quantity;
  final int total;

  factory CustomerTopProduct.fromJson(Map<String, dynamic> j) =>
      CustomerTopProduct(name: j['name'] as String, quantity: _dbl(j['quantity']), total: _int(j['total']));
}

/// Fiche client complète : solde, plafond, statistiques, achats et relevé du carnet.
class CustomerOverview {
  const CustomerOverview({
    required this.customer,
    required this.balance,
    this.availableCredit,
    this.oldestUnpaidAt,
    this.stats = const CustomerStats(),
    this.topProducts = const [],
    this.recentSales = const [],
    this.entries = const [],
  });
  final Contact customer;
  final int balance;
  final int? availableCredit;
  final DateTime? oldestUnpaidAt;
  final CustomerStats stats;
  final List<CustomerTopProduct> topProducts;
  final List<CustomerSale> recentSales;

  /// Du plus récent au plus ancien, avec le solde après chaque mouvement.
  final List<LedgerEntry> entries;

  int? get creditLimit => customer.creditLimit;

  /// Jours depuis la plus ancienne dette encore impayée.
  int? debtAgeDays([DateTime? now]) =>
      oldestUnpaidAt == null ? null : (now ?? DateTime.now()).difference(oldestUnpaidAt!).inDays;

  factory CustomerOverview.fromJson(Map<String, dynamic> j) {
    final balance = _int(j['balance']);
    final c = j['customer'] as Map<String, dynamic>;
    return CustomerOverview(
      customer: Contact.fromJson({...c, 'balance': balance}),
      balance: balance,
      availableCredit: j['availableCredit'] == null ? null : _int(j['availableCredit']),
      oldestUnpaidAt: _date(j['oldestUnpaidAt']),
      stats: CustomerStats.fromJson(j['stats'] as Map<String, dynamic>),
      topProducts: ((j['topProducts'] as List?) ?? [])
          .map((e) => CustomerTopProduct.fromJson(e as Map<String, dynamic>))
          .toList(),
      recentSales: ((j['recentSales'] as List?) ?? [])
          .map((e) => CustomerSale.fromJson(e as Map<String, dynamic>))
          .toList(),
      entries: ((j['entries'] as List?) ?? []).map((e) => LedgerEntry.fromJson(e as Map<String, dynamic>)).toList(),
    );
  }
}

class Debtor {
  const Debtor({required this.customerId, required this.name, this.phone, required this.balance, this.firstDebtAt});
  final String customerId;
  final String name;
  final String? phone;
  final int balance;
  final DateTime? firstDebtAt;

  factory Debtor.fromJson(Map<String, dynamic> j) => Debtor(
    customerId: j['customerId'] as String,
    name: j['name'] as String,
    phone: j['phone'] as String?,
    balance: _int(j['balance']),
    firstDebtAt: _date(j['firstDebtAt']),
  );
}

class LedgerEntry {
  const LedgerEntry({
    required this.id,
    required this.type,
    required this.amount,
    this.note,
    this.method,
    required this.at,
    this.refType,
    this.refId,
    this.balanceAfter,
  });
  final String id;
  final String type; // debt, repayment, adjustment
  final int amount;
  final String? note;
  final String? method;
  final DateTime at;

  /// sale, sale_void, opening_debt (reprise d'ancienne dette), write_off (remise de dette)
  final String? refType;
  final String? refId;

  /// Solde du client juste après ce mouvement (relevé de compte).
  final int? balanceAfter;

  /// Libellé lisible du mouvement.
  String get label => switch (type) {
    'debt' => 'Vente à crédit${note == null ? '' : ' · $note'}',
    'repayment' => 'Remboursement ${PayMethod.fromApi(method)?.label ?? ''}'.trim(),
    _ => switch (refType) {
      'opening_debt' => 'Ancienne dette${note == null ? '' : ' · $note'}',
      'write_off' => 'Remise de dette${note == null ? '' : ' · $note'}',
      _ => note ?? 'Ajustement',
    },
  };

  factory LedgerEntry.fromJson(Map<String, dynamic> j) => LedgerEntry(
    id: j['id'] as String,
    type: j['entryType'] as String,
    amount: _int(j['amount']),
    note: j['note'] as String?,
    method: j['method'] as String?,
    at: _date(j['occurredAt']) ?? DateTime.now(),
    refType: j['refType'] as String?,
    refId: j['refId'] as String?,
    balanceAfter: j['balanceAfter'] == null ? null : _int(j['balanceAfter']),
  );
}

class Ledger {
  const Ledger({required this.customer, required this.balance, required this.entries});
  final Contact customer;
  final int balance;
  final List<LedgerEntry> entries;

  factory Ledger.fromJson(Map<String, dynamic> j) => Ledger(
    customer: Contact.fromJson(j['customer'] as Map<String, dynamic>),
    balance: _int(j['balance']),
    entries: (j['entries'] as List).map((e) => LedgerEntry.fromJson(e as Map<String, dynamic>)).toList(),
  );
}

class SaleResult {
  const SaleResult({
    required this.id,
    required this.number,
    required this.total,
    required this.paid,
    required this.due,
  });
  final String id;
  final String number;
  final int total;
  final int paid;
  final int due;

  factory SaleResult.fromJson(Map<String, dynamic> j) => SaleResult(
    id: j['id'] as String,
    number: j['number'] as String,
    total: _int(j['total']),
    paid: _int(j['paid']),
    due: _int(j['due']),
  );
}

/// Ligne de ticket.
class ReceiptLine {
  const ReceiptLine({
    required this.name,
    required this.quantity,
    required this.unitPrice,
    this.discount = 0,
    required this.total,
  });
  final String name;
  final double quantity;
  final int unitPrice;
  final int discount;
  final int total;

  factory ReceiptLine.fromJson(Map<String, dynamic> j) => ReceiptLine(
    name: j['name'] as String,
    quantity: _num(j['quantity']),
    unitPrice: _int(j['unitPrice']),
    discount: _int(j['discount']),
    total: _int(j['total']),
  );
}

/// Vente complète (GET /v1/sales/:id) : tout ce qu'il faut pour le reçu.
class SaleDetail {
  const SaleDetail({
    required this.id,
    required this.number,
    required this.status,
    required this.soldAt,
    required this.subtotal,
    required this.discount,
    required this.total,
    required this.paid,
    required this.due,
    required this.lines,
    required this.payments,
    this.customer,
    this.cashierName,
    this.loyalty,
  });
  final String id;
  final String number;
  final String status; // completed, voided
  final DateTime soldAt;
  final int subtotal;
  final int discount;
  final int total;
  final int paid;
  final int due;
  final List<ReceiptLine> lines;
  final List<({PayMethod? method, int amount})> payments;
  final Contact? customer;
  final String? cashierName;

  /// Fidélité : points gagnés et utilisés avec cette vente, solde du client.
  final SaleLoyalty? loyalty;

  bool get voided => status == 'voided';

  factory SaleDetail.fromJson(Map<String, dynamic> j) => SaleDetail(
    id: j['id'] as String,
    number: j['number'] as String,
    status: j['status'] as String? ?? 'completed',
    soldAt: _date(j['soldAt']) ?? DateTime.now(),
    subtotal: _int(j['subtotal']),
    discount: _int(j['discount']),
    total: _int(j['total']),
    paid: _int(j['paid']),
    due: _int(j['due']),
    lines: ((j['items'] as List?) ?? const []).map((e) => ReceiptLine.fromJson(e as Map<String, dynamic>)).toList(),
    payments: [
      for (final p in (j['payments'] as List?) ?? const [])
        (method: PayMethod.fromApi((p as Map)['method'] as String?), amount: _int(p['amount'])),
    ],
    customer: j['customer'] == null ? null : Contact.fromJson(j['customer'] as Map<String, dynamic>),
    cashierName: j['cashierName'] as String?,
    loyalty: j['loyalty'] == null ? null : SaleLoyalty.fromJson(j['loyalty'] as Map<String, dynamic>),
  );
}

class SaleLoyalty {
  const SaleLoyalty({required this.earned, required this.redeemed, required this.balance});
  final int earned;
  final int redeemed;
  final int balance;
  factory SaleLoyalty.fromJson(Map<String, dynamic> j) =>
      SaleLoyalty(earned: _int(j['earned']), redeemed: _int(j['redeemed']), balance: _int(j['balance']));
}

/// Ligne de l'historique des ventes (GET /v1/sales).
class SaleSummary {
  const SaleSummary({
    required this.id,
    required this.number,
    required this.status,
    this.customerName,
    this.cashierName,
    required this.total,
    required this.due,
    required this.soldAt,
  });
  final String id;
  final String number;
  final String status;
  final String? customerName;
  final String? cashierName;
  final int total;
  final int due;
  final DateTime soldAt;

  factory SaleSummary.fromJson(Map<String, dynamic> j) => SaleSummary(
    id: j['id'] as String,
    number: j['number'] as String,
    status: j['status'] as String? ?? 'completed',
    customerName: j['customerName'] as String?,
    cashierName: j['cashierName'] as String?,
    total: _int(j['total']),
    // La liste renvoie « paid » ; le détail renvoie aussi « due ».
    due: j['due'] != null ? _int(j['due']) : _int(j['total']) - _int(j['paid']),
    soldAt: _date(j['soldAt']) ?? DateTime.now(),
  );
}

/// Moyens de paiement acceptés par l'API.
enum PayMethod {
  cash('cash', 'Espèces'),
  wave('wave', 'Wave'),
  orangeMoney('orange_money', 'Orange Money'),
  freeMoney('free_money', 'Free Money'),
  mtnMomo('mtn_momo', 'MTN MoMo'),
  moovMoney('moov_money', 'Moov Money'),
  airtelMoney('airtel_money', 'Airtel Money'),
  card('card', 'Carte'),
  // Factures uniquement
  transfer('transfer', 'Virement'),
  cheque('cheque', 'Chèque');

  const PayMethod(this.api, this.label);
  final String api;
  final String label;

  static PayMethod? fromApi(String? v) => PayMethod.values.where((m) => m.api == v).firstOrNull;
}

// ---------- Factures et devis ----------

enum DocKind {
  quote('quote', 'Devis'),
  invoice('invoice', 'Facture');

  const DocKind(this.api, this.label);
  final String api;
  final String label;

  static DocKind fromApi(String? v) => v == 'quote' ? DocKind.quote : DocKind.invoice;
}

/// Libellé lisible d'un statut de devis ou de facture.
String docStatusLabel(String status, {bool overdue = false}) {
  if (overdue) return 'En retard';
  return switch (status) {
    'pending' => 'En attente',
    'accepted' => 'Accepté',
    'declined' => 'Refusé',
    'invoiced' => 'Facturé',
    'unpaid' => 'À payer',
    'partial' => 'Payé en partie',
    'paid' => 'Payée',
    'cancelled' => 'Annulée',
    _ => status,
  };
}

/// Ligne de la liste des devis / factures.
class DocSummary {
  const DocSummary({
    required this.id,
    required this.kind,
    required this.number,
    required this.status,
    required this.customerName,
    required this.issueDate,
    this.dueDate,
    required this.total,
    required this.due,
    this.overdue = false,
  });
  final String id;
  final DocKind kind;
  final String number;
  final String status;
  final String customerName;
  final DateTime issueDate;
  final DateTime? dueDate;
  final int total;
  final int due;
  final bool overdue;

  factory DocSummary.fromJson(Map<String, dynamic> j) => DocSummary(
    id: j['id'] as String,
    kind: DocKind.fromApi(j['kind'] as String?),
    number: j['number'] as String,
    status: j['status'] as String,
    customerName: j['customerName'] as String? ?? '',
    issueDate: _date(j['issueDate']) ?? DateTime.now(),
    dueDate: _date(j['dueDate']),
    total: _int(j['total']),
    due: _int(j['due']),
    overdue: j['overdue'] as bool? ?? false,
  );
}

class DocLine {
  const DocLine({
    this.productId,
    required this.name,
    this.description,
    required this.quantity,
    required this.unitPrice,
    this.discount = 0,
    required this.total,
  });
  final String? productId;
  final String name;
  final String? description;
  final double quantity;
  final int unitPrice;
  final int discount;
  final int total;

  factory DocLine.fromJson(Map<String, dynamic> j) => DocLine(
    productId: j['productId'] as String?,
    name: j['name'] as String,
    description: j['description'] as String?,
    quantity: _num(j['quantity']),
    unitPrice: _int(j['unitPrice']),
    discount: _int(j['discount']),
    total: _int(j['total']),
  );
}

class DocPayment {
  const DocPayment({required this.method, required this.amount, this.reference, required this.paidAt});
  final PayMethod? method;
  final int amount;
  final String? reference;
  final DateTime paidAt;

  factory DocPayment.fromJson(Map<String, dynamic> j) => DocPayment(
    method: PayMethod.fromApi(j['method'] as String?),
    amount: _int(j['amount']),
    reference: j['reference'] as String?,
    paidAt: _date(j['paidAt']) ?? DateTime.now(),
  );
}

/// Devis ou facture complet (GET /v1/invoicing/documents/:id).
class DocDetail {
  const DocDetail({
    required this.id,
    required this.kind,
    required this.number,
    required this.status,
    required this.customer,
    required this.issueDate,
    this.dueDate,
    required this.subtotal,
    required this.discount,
    required this.total,
    required this.paid,
    required this.due,
    this.overdue = false,
    this.note,
    this.cancelReason,
    this.createdByName,
    this.related,
    required this.lines,
    required this.payments,
  });
  final String id;
  final DocKind kind;
  final String number;
  final String status;
  final Contact customer;
  final DateTime issueDate;
  final DateTime? dueDate;
  final int subtotal;
  final int discount;
  final int total;
  final int paid;
  final int due;
  final bool overdue;
  final String? note;
  final String? cancelReason;
  final String? createdByName;

  /// Devis → facture créée ; facture → devis d'origine.
  final ({String id, String number})? related;
  final List<DocLine> lines;
  final List<DocPayment> payments;

  bool get isQuote => kind == DocKind.quote;
  bool get cancelled => status == 'cancelled';

  factory DocDetail.fromJson(Map<String, dynamic> j) {
    final rel = (j['invoice'] ?? j['quote']) as Map<String, dynamic>?;
    return DocDetail(
      id: j['id'] as String,
      kind: DocKind.fromApi(j['kind'] as String?),
      number: j['number'] as String,
      status: j['status'] as String,
      customer: Contact.fromJson(j['customer'] as Map<String, dynamic>),
      issueDate: _date(j['issueDate']) ?? DateTime.now(),
      dueDate: _date(j['dueDate']),
      subtotal: _int(j['subtotal']),
      discount: _int(j['discount']),
      total: _int(j['total']),
      paid: _int(j['paid']),
      due: _int(j['due']),
      overdue: j['overdue'] as bool? ?? false,
      note: j['note'] as String?,
      cancelReason: j['cancelReason'] as String?,
      createdByName: j['createdByName'] as String?,
      related: rel == null ? null : (id: rel['id'] as String, number: rel['number'] as String),
      lines: [for (final l in (j['lines'] as List?) ?? const []) DocLine.fromJson(l as Map<String, dynamic>)],
      payments: [for (final p in (j['payments'] as List?) ?? const []) DocPayment.fromJson(p as Map<String, dynamic>)],
    );
  }
}

class InvoicingSummary {
  const InvoicingSummary({
    required this.receivable,
    required this.openInvoices,
    required this.overdue,
    required this.overdueInvoices,
    required this.openQuotesTotal,
    required this.openQuotes,
    required this.invoicedThisMonth,
  });
  final int receivable;
  final int openInvoices;
  final int overdue;
  final int overdueInvoices;
  final int openQuotesTotal;
  final int openQuotes;
  final int invoicedThisMonth;

  factory InvoicingSummary.fromJson(Map<String, dynamic> j) => InvoicingSummary(
    receivable: _int(j['receivable']),
    openInvoices: _int(j['openInvoices']),
    overdue: _int(j['overdue']),
    overdueInvoices: _int(j['overdueInvoices']),
    openQuotesTotal: _int(j['openQuotesTotal']),
    openQuotes: _int(j['openQuotes']),
    invoicedThisMonth: _int(j['invoicedThisMonth']),
  );
}

// ---------- Rapports ----------

class ReportPoint {
  const ReportPoint({required this.period, required this.salesCount, required this.revenue, required this.grossProfit});
  final String period; // AAAA-MM-JJ ou AAAA-MM
  final int salesCount;
  final int revenue;
  final int grossProfit;

  factory ReportPoint.fromJson(Map<String, dynamic> j) => ReportPoint(
    period: j['period'] as String,
    salesCount: _int(j['salesCount']),
    revenue: _int(j['revenue']),
    grossProfit: _int(j['grossProfit']),
  );
}

class ReportProduct {
  const ReportProduct({required this.name, required this.quantity, required this.revenue, required this.grossProfit});
  final String name;
  final double quantity;
  final int revenue;
  final int grossProfit;

  factory ReportProduct.fromJson(Map<String, dynamic> j) => ReportProduct(
    name: j['name'] as String,
    quantity: _num(j['quantity']),
    revenue: _int(j['revenue']),
    grossProfit: _int(j['grossProfit']),
  );
}

/// Rapport d'une période (GET /v1/reports/overview).
class ReportOverview {
  const ReportOverview({
    required this.from,
    required this.to,
    required this.days,
    required this.byMonth,
    required this.salesCount,
    required this.voidedCount,
    required this.revenue,
    required this.cost,
    required this.grossProfit,
    required this.expenses,
    required this.netProfit,
    required this.collected,
    required this.onCredit,
    required this.discounts,
    required this.averageBasket,
    required this.marginRate,
    required this.previousRevenue,
    this.revenueChange,
    this.profitChange,
    this.salesChange,
    required this.series,
    required this.byMethod,
    required this.topProducts,
    required this.bySeller,
    required this.expensesByCategory,
    required this.invoiced,
    required this.invoiceCount,
    required this.invoicePayments,
  });
  final DateTime from;
  final DateTime to;
  final int days;
  final bool byMonth;
  final int salesCount;
  final int voidedCount;
  final int revenue;
  final int cost;
  final int grossProfit;
  final int expenses;
  final int netProfit;
  final int collected;
  final int onCredit;
  final int discounts;
  final int averageBasket;
  final double marginRate;
  final int previousRevenue;
  final double? revenueChange;
  final double? profitChange;
  final double? salesChange;
  final List<ReportPoint> series;
  final List<({PayMethod? method, int amount, int salesCount})> byMethod;
  final List<ReportProduct> topProducts;
  final List<SellerStat> bySeller;
  final List<({String category, int amount})> expensesByCategory;
  final int invoiced;
  final int invoiceCount;
  final int invoicePayments;

  factory ReportOverview.fromJson(Map<String, dynamic> j) {
    final p = j['period'] as Map<String, dynamic>;
    final c = (j['change'] as Map<String, dynamic>?) ?? const {};
    final inv = (j['invoices'] as Map<String, dynamic>?) ?? const {};
    double? pct(Object? v) => v == null ? null : (v as num).toDouble();
    return ReportOverview(
      from: DateTime.parse(p['from'] as String),
      to: DateTime.parse(p['to'] as String),
      days: _int(p['days']),
      byMonth: p['granularity'] == 'month',
      salesCount: _int(j['salesCount']),
      voidedCount: _int(j['voidedCount']),
      revenue: _int(j['revenue']),
      cost: _int(j['cost']),
      grossProfit: _int(j['grossProfit']),
      expenses: _int(j['expenses']),
      netProfit: _int(j['netProfit']),
      collected: _int(j['collected']),
      onCredit: _int(j['onCredit']),
      discounts: _int(j['discounts']),
      averageBasket: _int(j['averageBasket']),
      marginRate: _num(j['marginRate']),
      previousRevenue: _int((j['previous'] as Map?)?['revenue']),
      revenueChange: pct(c['revenue']),
      profitChange: pct(c['netProfit']),
      salesChange: pct(c['salesCount']),
      series: [for (final s in (j['series'] as List?) ?? const []) ReportPoint.fromJson(s as Map<String, dynamic>)],
      byMethod: [
        for (final m in (j['byMethod'] as List?) ?? const [])
          (
            method: PayMethod.fromApi((m as Map)['method'] as String?),
            amount: _int(m['amount']),
            salesCount: _int(m['salesCount']),
          ),
      ],
      topProducts: [
        for (final t in (j['topProducts'] as List?) ?? const []) ReportProduct.fromJson(t as Map<String, dynamic>),
      ],
      bySeller: [for (final v in (j['bySeller'] as List?) ?? const []) SellerStat.fromJson(v as Map<String, dynamic>)],
      expensesByCategory: [
        for (final e in (j['expensesByCategory'] as List?) ?? const [])
          (category: (e as Map)['category'] as String, amount: _int(e['amount'])),
      ],
      invoiced: _int(inv['invoiced']),
      invoiceCount: _int(inv['count']),
      invoicePayments: _int(inv['received']),
    );
  }
}

// =====================================================================
// Achats et fournisseurs
// =====================================================================

DateTime? _day(Object? v) {
  if (v == null) return null;
  final s = '$v';
  return DateTime.tryParse(s.length >= 10 ? s.substring(0, 10) : s);
}

enum PurchaseStatus {
  draft('draft', 'Brouillon'),
  ordered('ordered', 'Commandé'),
  partial('partial', 'Reçu en partie'),
  received('received', 'Reçu'),
  cancelled('cancelled', 'Annulé');

  const PurchaseStatus(this.api, this.label);
  final String api;
  final String label;

  static PurchaseStatus fromApi(String? v) => values.firstWhere((s) => s.api == v, orElse: () => ordered);

  bool get open => this == draft || this == ordered || this == partial;
  bool get canReceive => this == ordered || this == partial;
}

enum PurchaseFilter {
  open('open', 'En cours'),
  unpaid('unpaid', 'À payer'),
  received('received', 'Reçues'),
  all('all', 'Toutes');

  const PurchaseFilter(this.api, this.label);
  final String api;
  final String label;
}

class PurchaseSummary {
  const PurchaseSummary({
    required this.id,
    required this.number,
    required this.status,
    required this.supplierId,
    required this.supplierName,
    required this.orderDate,
    this.expectedDate,
    required this.total,
    this.receivedTotal = 0,
    this.paid = 0,
    this.due = 0,
    this.lineCount = 0,
  });
  final String id;
  final String number;
  final PurchaseStatus status;
  final String supplierId;
  final String supplierName;
  final DateTime orderDate;
  final DateTime? expectedDate;
  final int total;
  final int receivedTotal;
  final int paid;
  final int due;
  final int lineCount;

  /// Livraison attendue dépassée et marchandise pas encore toute reçue.
  bool late([DateTime? now]) {
    if (expectedDate == null || !status.canReceive) return false;
    final n = now ?? DateTime.now();
    return expectedDate!.isBefore(DateTime(n.year, n.month, n.day));
  }

  factory PurchaseSummary.fromJson(Map<String, dynamic> j) => PurchaseSummary(
    id: j['id'] as String,
    number: j['number'] as String,
    status: PurchaseStatus.fromApi(j['status'] as String?),
    supplierId: j['supplierId'] as String,
    supplierName: j['supplierName'] as String? ?? '',
    orderDate: _day(j['orderDate']) ?? DateTime.now(),
    expectedDate: _day(j['expectedDate']),
    total: _int(j['total']),
    receivedTotal: _int(j['receivedTotal']),
    paid: _int(j['paid']),
    due: _int(j['due']),
    lineCount: _int(j['lineCount']),
  );
}

class PurchaseTotals {
  const PurchaseTotals({this.openOrders = 0, this.toReceive = 0, this.totalDue = 0, this.suppliersOwed = 0});
  final int openOrders;
  final int toReceive;
  final int totalDue;
  final int suppliersOwed;

  factory PurchaseTotals.fromJson(Map<String, dynamic> j) => PurchaseTotals(
    openOrders: _int(j['openOrders']),
    toReceive: _int(j['toReceive']),
    totalDue: _int(j['totalDue']),
    suppliersOwed: _int(j['suppliersOwed']),
  );
}

class PurchaseList {
  const PurchaseList({required this.data, required this.totals});
  final List<PurchaseSummary> data;
  final PurchaseTotals totals;

  factory PurchaseList.fromJson(Map<String, dynamic> j) => PurchaseList(
    data: (j['data'] as List).map((e) => PurchaseSummary.fromJson(e as Map<String, dynamic>)).toList(),
    totals: PurchaseTotals.fromJson(j['totals'] as Map<String, dynamic>),
  );
}

class PurchaseLine {
  const PurchaseLine({
    required this.id,
    required this.productId,
    required this.name,
    this.unit = 'pièce',
    required this.quantity,
    this.receivedQty = 0,
    required this.unitCost,
    required this.total,
  });
  final String id;
  final String productId;
  final String name;
  final String unit;
  final double quantity;
  final double receivedQty;
  final int unitCost;
  final int total;

  double get remaining => ((quantity - receivedQty) * 1000).round() / 1000;

  factory PurchaseLine.fromJson(Map<String, dynamic> j) => PurchaseLine(
    id: j['id'] as String,
    productId: j['productId'] as String,
    name: j['name'] as String,
    unit: j['unit'] as String? ?? 'pièce',
    quantity: _dbl(j['quantity']),
    receivedQty: _dbl(j['receivedQty']),
    unitCost: _int(j['unitCost']),
    total: _int(j['total']),
  );
}

class PurchaseReceipt {
  const PurchaseReceipt({required this.id, required this.total, this.note, required this.receivedAt, this.receivedBy});
  final String id;
  final int total;
  final String? note;
  final DateTime receivedAt;
  final String? receivedBy;

  factory PurchaseReceipt.fromJson(Map<String, dynamic> j) => PurchaseReceipt(
    id: j['id'] as String,
    total: _int(j['total']),
    note: j['note'] as String?,
    receivedAt: _date(j['receivedAt']) ?? DateTime.now(),
    receivedBy: j['receivedBy'] as String?,
  );
}

class PurchasePayment {
  const PurchasePayment({
    required this.id,
    required this.method,
    required this.amount,
    this.reference,
    required this.paidAt,
    this.number,
    this.orderId,
  });
  final String id;
  final PayMethod? method;
  final int amount;
  final String? reference;
  final DateTime paidAt;

  /// Fiche fournisseur : bon concerné.
  final String? number;
  final String? orderId;

  factory PurchasePayment.fromJson(Map<String, dynamic> j) => PurchasePayment(
    id: j['id'] as String,
    method: PayMethod.fromApi(j['method'] as String?),
    amount: _int(j['amount']),
    reference: j['reference'] as String?,
    paidAt: _date(j['paidAt']) ?? DateTime.now(),
    number: j['number'] as String?,
    orderId: j['orderId'] as String?,
  );
}

class PurchaseDetail {
  const PurchaseDetail({
    required this.summary,
    required this.supplier,
    this.note,
    this.lines = const [],
    this.receipts = const [],
    this.payments = const [],
  });
  final PurchaseSummary summary;
  final Contact supplier;
  final String? note;
  final List<PurchaseLine> lines;
  final List<PurchaseReceipt> receipts;
  final List<PurchasePayment> payments;

  String get id => summary.id;
  String get number => summary.number;
  PurchaseStatus get status => summary.status;

  /// On peut payer d'avance jusqu'au montant commandé, ou ce qui a été reçu s'il est plus élevé.
  int get payable => summary.status == PurchaseStatus.cancelled || summary.status == PurchaseStatus.draft
      ? 0
      : (summary.total > summary.receivedTotal ? summary.total : summary.receivedTotal) - summary.paid;

  bool get editable =>
      (status == PurchaseStatus.draft || status == PurchaseStatus.ordered) &&
      summary.receivedTotal == 0 &&
      summary.paid == 0;

  factory PurchaseDetail.fromJson(Map<String, dynamic> j) => PurchaseDetail(
    summary: PurchaseSummary.fromJson({...j, 'supplierName': (j['supplier'] as Map)['name']}),
    supplier: Contact.fromJson(j['supplier'] as Map<String, dynamic>),
    note: j['note'] as String?,
    lines: ((j['lines'] as List?) ?? []).map((e) => PurchaseLine.fromJson(e as Map<String, dynamic>)).toList(),
    receipts: ((j['receipts'] as List?) ?? []).map((e) => PurchaseReceipt.fromJson(e as Map<String, dynamic>)).toList(),
    payments: ((j['payments'] as List?) ?? []).map((e) => PurchasePayment.fromJson(e as Map<String, dynamic>)).toList(),
  );
}

/// Ligne d'un bon en cours de saisie.
class PurchaseLineDraft {
  const PurchaseLineDraft({
    required this.productId,
    required this.name,
    required this.quantity,
    required this.unitCost,
    this.unit = 'pièce',
    this.scanLabel,
  });
  final String productId;
  final String name;
  final double quantity;
  final int unitCost;
  final String unit;

  /// Libellé lu sur la facture en photo : le serveur retient l'association pour la prochaine fois.
  final String? scanLabel;

  int get total => (quantity * unitCost).round();

  PurchaseLineDraft copyWith({double? quantity, int? unitCost}) => PurchaseLineDraft(
    productId: productId,
    name: name,
    quantity: quantity ?? this.quantity,
    unitCost: unitCost ?? this.unitCost,
    unit: unit,
    scanLabel: scanLabel,
  );

  Map<String, dynamic> toJson() => {
    'productId': productId,
    'quantity': quantity,
    'unitCost': unitCost,
    'scanLabel': ?scanLabel,
  };

  factory PurchaseLineDraft.fromLine(PurchaseLine l) =>
      PurchaseLineDraft(productId: l.productId, name: l.name, quantity: l.quantity, unitCost: l.unitCost, unit: l.unit);
}

class SupplierRow {
  const SupplierRow({
    required this.id,
    required this.name,
    this.phone,
    this.address,
    this.ordersCount = 0,
    this.purchased = 0,
    this.due = 0,
    this.openOrders = 0,
    this.lastOrderAt,
  });
  final String id;
  final String name;
  final String? phone;
  final String? address;
  final int ordersCount;
  final int purchased;
  final int due;
  final int openOrders;
  final DateTime? lastOrderAt;

  Contact toContact() => Contact(id: id, name: name, phone: phone, address: address);

  factory SupplierRow.fromJson(Map<String, dynamic> j) => SupplierRow(
    id: j['id'] as String,
    name: j['name'] as String,
    phone: j['phone'] as String?,
    address: j['address'] as String?,
    ordersCount: _int(j['ordersCount']),
    purchased: _int(j['purchased']),
    due: _int(j['due']),
    openOrders: _int(j['openOrders']),
    lastOrderAt: _day(j['lastOrderAt']),
  );
}

class SupplierProduct {
  const SupplierProduct({required this.productId, required this.name, required this.quantity, required this.lastCost});
  final String productId;
  final String name;
  final double quantity;
  final int lastCost;

  factory SupplierProduct.fromJson(Map<String, dynamic> j) => SupplierProduct(
    productId: j['productId'] as String,
    name: j['name'] as String,
    quantity: _dbl(j['quantity']),
    lastCost: _int(j['lastCost']),
  );
}

class SupplierOverview {
  const SupplierOverview({
    required this.supplier,
    required this.due,
    this.ordersCount = 0,
    this.purchased = 0,
    this.paid = 0,
    this.openOrders = 0,
    this.lastOrderAt,
    this.orders = const [],
    this.payments = const [],
    this.products = const [],
  });
  final Contact supplier;
  final int due;
  final int ordersCount;
  final int purchased;
  final int paid;
  final int openOrders;
  final DateTime? lastOrderAt;
  final List<PurchaseSummary> orders;
  final List<PurchasePayment> payments;
  final List<SupplierProduct> products;

  factory SupplierOverview.fromJson(Map<String, dynamic> j) {
    final s = j['stats'] as Map<String, dynamic>;
    return SupplierOverview(
      supplier: Contact.fromJson(j['supplier'] as Map<String, dynamic>),
      due: _int(j['due']),
      ordersCount: _int(s['ordersCount']),
      purchased: _int(s['purchased']),
      paid: _int(s['paid']),
      openOrders: _int(s['openOrders']),
      lastOrderAt: _day(s['lastOrderAt']),
      orders: ((j['orders'] as List?) ?? []).map((e) => PurchaseSummary.fromJson(e as Map<String, dynamic>)).toList(),
      payments: ((j['payments'] as List?) ?? [])
          .map((e) => PurchasePayment.fromJson(e as Map<String, dynamic>))
          .toList(),
      products: ((j['products'] as List?) ?? [])
          .map((e) => SupplierProduct.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

// =====================================================================
// Boutique en ligne
// =====================================================================

class ShopSettings {
  const ShopSettings({
    this.enabled = false,
    this.title,
    this.description,
    this.whatsapp,
    this.pickup = true,
    this.delivery = true,
    this.deliveryFee = 0,
    this.deliveryZone,
    this.minOrder = 0,
  });
  final bool enabled;
  final String? title;
  final String? description;
  final String? whatsapp;
  final bool pickup;
  final bool delivery;
  final int deliveryFee;
  final String? deliveryZone;
  final int minOrder;

  factory ShopSettings.fromJson(Map<String, dynamic> j) => ShopSettings(
    enabled: j['enabled'] as bool? ?? false,
    title: j['title'] as String?,
    description: j['description'] as String?,
    whatsapp: j['whatsapp'] as String?,
    pickup: j['pickup'] as bool? ?? true,
    delivery: j['delivery'] as bool? ?? true,
    deliveryFee: _int(j['deliveryFee']),
    deliveryZone: j['deliveryZone'] as String?,
    minOrder: _int(j['minOrder']),
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'title': title ?? '',
    'description': description ?? '',
    'whatsapp': whatsapp ?? '',
    'pickup': pickup,
    'delivery': delivery,
    'deliveryFee': deliveryFee,
    'deliveryZone': deliveryZone ?? '',
    'minOrder': minOrder,
  };
}

class ShopOverview {
  const ShopOverview({
    required this.slug,
    required this.path,
    required this.settings,
    this.newOrders = 0,
    this.openOrders = 0,
    this.monthOrders = 0,
    this.monthRevenue = 0,
    this.publishedProducts = 0,
    this.totalProducts = 0,
  });
  final String slug;
  final String path;
  final ShopSettings settings;
  final int newOrders;
  final int openOrders;
  final int monthOrders;
  final int monthRevenue;
  final int publishedProducts;
  final int totalProducts;

  factory ShopOverview.fromJson(Map<String, dynamic> j) {
    final s = j['stats'] as Map<String, dynamic>;
    return ShopOverview(
      slug: j['slug'] as String,
      path: j['path'] as String,
      settings: ShopSettings.fromJson(j['settings'] as Map<String, dynamic>),
      newOrders: _int(s['newOrders']),
      openOrders: _int(s['openOrders']),
      monthOrders: _int(s['monthOrders']),
      monthRevenue: _int(s['monthRevenue']),
      publishedProducts: _int(s['publishedProducts']),
      totalProducts: _int(s['totalProducts']),
    );
  }
}

enum ShopOrderStatus {
  newOrder('new', 'Nouvelle'),
  confirmed('confirmed', 'Confirmée'),
  ready('ready', 'Prête'),
  delivering('delivering', 'En livraison'),
  completed('completed', 'Livrée'),
  cancelled('cancelled', 'Annulée');

  const ShopOrderStatus(this.api, this.label);
  final String api;
  final String label;

  static ShopOrderStatus fromApi(String? v) => values.firstWhere((s) => s.api == v, orElse: () => newOrder);

  bool get done => this == completed || this == cancelled;
}

enum ShopOrderFilter {
  open('open', 'En cours'),
  newOnly('new', 'Nouvelles'),
  done('done', 'Terminées'),
  all('all', 'Toutes');

  const ShopOrderFilter(this.api, this.label);
  final String api;
  final String label;
}

class ShopOrderLine {
  const ShopOrderLine({
    required this.id,
    required this.productId,
    required this.name,
    this.unit = 'pièce',
    required this.quantity,
    required this.unitPrice,
    required this.total,
    this.imageFileId,
  });
  final String id;
  final String productId;
  final String name;
  final String unit;
  final double quantity;
  final int unitPrice;
  final int total;
  final String? imageFileId;

  factory ShopOrderLine.fromJson(Map<String, dynamic> j) => ShopOrderLine(
    id: j['id'] as String,
    productId: j['productId'] as String,
    name: j['name'] as String,
    unit: j['unit'] as String? ?? 'pièce',
    quantity: _dbl(j['quantity']),
    unitPrice: _int(j['unitPrice']),
    total: _int(j['total']),
    imageFileId: j['imageFileId'] as String?,
  );
}

class ShopOrder {
  const ShopOrder({
    required this.id,
    required this.number,
    required this.status,
    required this.customerName,
    required this.customerPhone,
    required this.delivery,
    required this.total,
    this.lineCount = 0,
    required this.createdAt,
    this.contactId,
    this.address,
    this.note,
    this.subtotal = 0,
    this.deliveryFee = 0,
    this.saleId,
    this.cancelReason,
    this.lines = const [],
  });
  final String id;
  final String number;
  final ShopOrderStatus status;
  final String customerName;
  final String customerPhone;

  /// Livraison (sinon retrait en boutique).
  final bool delivery;
  final int total;
  final int lineCount;
  final DateTime createdAt;
  final String? contactId;
  final String? address;
  final String? note;
  final int subtotal;
  final int deliveryFee;
  final String? saleId;
  final String? cancelReason;
  final List<ShopOrderLine> lines;

  /// Étapes suivantes proposées au commerçant (la livraison seulement si commandée en livraison).
  List<ShopOrderStatus> get nextSteps => switch (status) {
    ShopOrderStatus.newOrder => const [ShopOrderStatus.confirmed],
    ShopOrderStatus.confirmed => const [ShopOrderStatus.ready],
    ShopOrderStatus.ready => delivery ? const [ShopOrderStatus.delivering] : const [ShopOrderStatus.completed],
    ShopOrderStatus.delivering => const [ShopOrderStatus.completed],
    _ => const [],
  };

  factory ShopOrder.fromJson(Map<String, dynamic> j) => ShopOrder(
    id: j['id'] as String,
    number: j['number'] as String,
    status: ShopOrderStatus.fromApi(j['status'] as String?),
    customerName: j['customerName'] as String,
    customerPhone: j['customerPhone'] as String,
    delivery: j['mode'] == 'delivery',
    total: _int(j['total']),
    lineCount: _int(j['lineCount']),
    createdAt: _date(j['createdAt']) ?? DateTime.now(),
    contactId: j['contactId'] as String?,
    address: j['address'] as String?,
    note: j['note'] as String?,
    subtotal: _int(j['subtotal']),
    deliveryFee: _int(j['deliveryFee']),
    saleId: j['saleId'] as String?,
    cancelReason: j['cancelReason'] as String?,
    lines: ((j['lines'] as List?) ?? []).map((e) => ShopOrderLine.fromJson(e as Map<String, dynamic>)).toList(),
  );
}

// =====================================================================
// Caisse : ouverture, mouvements, clôture (rapport Z)
// =====================================================================

/// Montants d'une session pour un moyen de paiement.
class CashMethodLine {
  const CashMethodLine({
    required this.method,
    this.opening = 0,
    this.sales = 0,
    this.repayments = 0,
    this.invoices = 0,
    this.expenses = 0,
    this.suppliers = 0,
    this.movementsIn = 0,
    this.movementsOut = 0,
    required this.expected,
  });
  final PayMethod method;
  final int opening;
  final int sales;
  final int repayments;
  final int invoices;
  final int expenses;
  final int suppliers;
  final int movementsIn;
  final int movementsOut;
  final int expected;

  /// Détail lisible : seulement les postes non nuls.
  List<(String, int)> get breakdown => [
    if (opening != 0) ('Fond de caisse', opening),
    if (sales != 0) ('Ventes', sales),
    if (repayments != 0) ('Remboursements de crédit', repayments),
    if (invoices != 0) ('Factures encaissées', invoices),
    if (movementsIn != 0) ('Entrées d’argent', movementsIn),
    if (expenses != 0) ('Dépenses', -expenses),
    if (suppliers != 0) ('Paiements fournisseurs', -suppliers),
    if (movementsOut != 0) ('Sorties d’argent', -movementsOut),
  ];

  factory CashMethodLine.fromJson(Map<String, dynamic> j) => CashMethodLine(
    method: PayMethod.fromApi(j['method'] as String?) ?? PayMethod.cash,
    opening: _int(j['opening']),
    sales: _int(j['sales']),
    repayments: _int(j['repayments']),
    invoices: _int(j['invoices']),
    expenses: _int(j['expenses']),
    suppliers: _int(j['suppliers']),
    movementsIn: _int(j['movementsIn']),
    movementsOut: _int(j['movementsOut']),
    expected: _int(j['expected']),
  );
}

class CashReport {
  const CashReport({
    this.salesCount = 0,
    this.salesTotal = 0,
    this.creditTotal = 0,
    this.discountTotal = 0,
    this.voidedCount = 0,
    this.voidedTotal = 0,
    this.methods = const [],
    this.expectedTotal = 0,
  });
  final int salesCount;
  final int salesTotal;
  final int creditTotal;
  final int discountTotal;
  final int voidedCount;
  final int voidedTotal;
  final List<CashMethodLine> methods;
  final int expectedTotal;

  int get expectedCash => methods.where((m) => m.method == PayMethod.cash).firstOrNull?.expected ?? 0;

  factory CashReport.fromJson(Map<String, dynamic> j) => CashReport(
    salesCount: _int(j['salesCount']),
    salesTotal: _int(j['salesTotal']),
    creditTotal: _int(j['creditTotal']),
    discountTotal: _int(j['discountTotal']),
    voidedCount: _int(j['voidedCount']),
    voidedTotal: _int(j['voidedTotal']),
    methods: ((j['methods'] as List?) ?? []).map((e) => CashMethodLine.fromJson(e as Map<String, dynamic>)).toList(),
    expectedTotal: _int(j['expectedTotal']),
  );
}

/// Attendu, compté et écart d'un moyen de paiement à la clôture.
class CashCountLine {
  const CashCountLine({required this.method, required this.expected, required this.counted, required this.difference});
  final PayMethod method;
  final int expected;
  final int counted;
  final int difference;

  factory CashCountLine.fromJson(Map<String, dynamic> j) => CashCountLine(
    method: PayMethod.fromApi(j['method'] as String?) ?? PayMethod.cash,
    expected: _int(j['expected']),
    counted: _int(j['counted']),
    difference: _int(j['difference']),
  );
}

class CashMovement {
  const CashMovement({
    required this.id,
    required this.isIn,
    required this.amount,
    required this.reason,
    required this.createdAt,
    this.createdByName,
  });
  final String id;
  final bool isIn;
  final int amount;
  final String reason;
  final DateTime createdAt;
  final String? createdByName;

  factory CashMovement.fromJson(Map<String, dynamic> j) => CashMovement(
    id: j['id'] as String,
    isIn: j['direction'] == 'in',
    amount: _int(j['amount']),
    reason: j['reason'] as String,
    createdAt: _date(j['createdAt']) ?? DateTime.now(),
    createdByName: j['createdByName'] as String?,
  );
}

class CashSession {
  const CashSession({
    required this.id,
    required this.number,
    required this.open,
    required this.userId,
    this.userName,
    this.openingFloat = 0,
    this.openingNote,
    required this.openedAt,
    this.closedAt,
    this.closedByName,
    this.closingNote,
    this.report = const CashReport(),
    this.difference,
    this.lines,
    this.movements = const [],
  });
  final String id;
  final String number;
  final bool open;
  final String userId;
  final String? userName;
  final int openingFloat;
  final String? openingNote;
  final DateTime openedAt;
  final DateTime? closedAt;
  final String? closedByName;
  final String? closingNote;
  final CashReport report;

  /// Total compté − total attendu (clôturée seulement).
  final int? difference;
  final List<CashCountLine>? lines;
  final List<CashMovement> movements;

  factory CashSession.fromJson(Map<String, dynamic> j) => CashSession(
    id: j['id'] as String,
    number: j['number'] as String,
    open: j['status'] == 'open',
    userId: j['userId'] as String,
    userName: j['userName'] as String?,
    openingFloat: _int(j['openingFloat']),
    openingNote: j['openingNote'] as String?,
    openedAt: _date(j['openedAt']) ?? DateTime.now(),
    closedAt: _date(j['closedAt']),
    closedByName: j['closedByName'] as String?,
    closingNote: j['closingNote'] as String?,
    report: CashReport.fromJson((j['report'] as Map<String, dynamic>?) ?? const {}),
    difference: j['difference'] == null ? null : _int(j['difference']),
    lines: (j['lines'] as List?)?.map((e) => CashCountLine.fromJson(e as Map<String, dynamic>)).toList(),
    movements: ((j['movements'] as List?) ?? []).map((e) => CashMovement.fromJson(e as Map<String, dynamic>)).toList(),
  );
}

class CashSessionSummary {
  const CashSessionSummary({
    required this.id,
    required this.number,
    required this.open,
    this.userName,
    this.openingFloat = 0,
    required this.openedAt,
    this.closedAt,
    this.salesTotal,
    this.salesCount,
    this.countedTotal,
    this.difference,
  });
  final String id;
  final String number;
  final bool open;
  final String? userName;
  final int openingFloat;
  final DateTime openedAt;
  final DateTime? closedAt;
  final int? salesTotal;
  final int? salesCount;
  final int? countedTotal;
  final int? difference;

  factory CashSessionSummary.fromJson(Map<String, dynamic> j) => CashSessionSummary(
    id: j['id'] as String,
    number: j['number'] as String,
    open: j['status'] == 'open',
    userName: j['userName'] as String?,
    openingFloat: _int(j['openingFloat']),
    openedAt: _date(j['openedAt']) ?? DateTime.now(),
    closedAt: _date(j['closedAt']),
    salesTotal: j['salesTotal'] == null ? null : _int(j['salesTotal']),
    salesCount: j['salesCount'] == null ? null : _int(j['salesCount']),
    countedTotal: j['countedTotal'] == null ? null : _int(j['countedTotal']),
    difference: j['difference'] == null ? null : _int(j['difference']),
  );
}

/// Notification de la cloche de l'accueil.
class AppNotification {
  const AppNotification({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.createdAt,
    this.link,
    this.read = false,
  });
  final String id;
  final String kind;
  final String title;
  final String body;
  final String? link;
  final DateTime createdAt;
  final bool read;

  AppNotification copyWith({bool? read}) => AppNotification(
    id: id,
    kind: kind,
    title: title,
    body: body,
    link: link,
    createdAt: createdAt,
    read: read ?? this.read,
  );

  factory AppNotification.fromJson(Map<String, dynamic> j) => AppNotification(
    id: j['id'] as String,
    kind: j['kind'] as String,
    title: j['title'] as String,
    body: (j['body'] as String?) ?? '',
    link: j['link'] as String?,
    createdAt: (_date(j['createdAt']) ?? DateTime.now()).toLocal(),
    read: j['read'] == true,
  );
}

class NotificationsPage {
  const NotificationsPage({required this.items, required this.unread});
  final List<AppNotification> items;
  final int unread;

  factory NotificationsPage.fromJson(Map<String, dynamic> j) => NotificationsPage(
    items: [for (final n in (j['items'] as List? ?? const [])) AppNotification.fromJson(n as Map<String, dynamic>)],
    unread: _int(j['unread']),
  );
}

/// Une ligne de la file des relances : le crédit d'un client ou une facture impayée.
class ReminderItem {
  const ReminderItem({
    required this.kind,
    required this.id,
    required this.customerId,
    required this.name,
    required this.amount,
    required this.daysLate,
    required this.due,
    this.phone,
    this.since,
    this.invoiceNumber,
    this.lastRemindedAt,
  });
  final String kind; // credit, invoice
  final String id;
  final String customerId;
  final String name;
  final String? phone;
  final int amount;
  final DateTime? since;
  final int daysLate;
  final String? invoiceNumber;
  final DateTime? lastRemindedAt;
  final bool due;

  bool get isInvoice => kind == 'invoice';
  bool get hasPhone => (phone ?? '').trim().isNotEmpty;

  factory ReminderItem.fromJson(Map<String, dynamic> j) => ReminderItem(
    kind: j['kind'] as String,
    id: j['id'] as String,
    customerId: j['customerId'] as String,
    name: j['name'] as String,
    phone: j['phone'] as String?,
    amount: _int(j['amount']),
    since: _date(j['since']),
    daysLate: _int(j['daysLate']),
    invoiceNumber: j['invoiceNumber'] as String?,
    lastRemindedAt: _date(j['lastRemindedAt']),
    due: j['due'] == true,
  );
}

class ReminderLog {
  const ReminderLog({
    required this.id,
    required this.channel,
    required this.amount,
    required this.at,
    required this.customerId,
    required this.customerName,
    this.invoiceId,
    this.invoiceNumber,
    this.byName,
  });
  final String id;
  final String channel; // whatsapp, sms, call
  final int amount;
  final DateTime at;
  final String customerId;
  final String customerName;
  final String? invoiceId;
  final String? invoiceNumber;
  final String? byName;

  factory ReminderLog.fromJson(Map<String, dynamic> j) => ReminderLog(
    id: j['id'] as String,
    channel: j['channel'] as String,
    amount: _int(j['amount']),
    at: _date(j['at']) ?? DateTime.now(),
    customerId: j['customerId'] as String,
    customerName: j['customerName'] as String,
    invoiceId: j['invoiceId'] as String?,
    invoiceNumber: j['invoiceNumber'] as String?,
    byName: j['byName'] as String?,
  );
}

class ReminderQueue {
  const ReminderQueue({
    required this.items,
    required this.history,
    required this.dueCount,
    required this.dueAmount,
    required this.totalAmount,
    required this.remindedThisWeek,
  });
  final List<ReminderItem> items;
  final List<ReminderLog> history;
  final int dueCount;
  final int dueAmount;
  final int totalAmount;
  final int remindedThisWeek;

  List<ReminderItem> get dueItems => items.where((i) => i.due).toList();

  factory ReminderQueue.fromJson(Map<String, dynamic> j) {
    final s = (j['summary'] as Map<String, dynamic>?) ?? const {};
    return ReminderQueue(
      items: [for (final i in (j['items'] as List? ?? const [])) ReminderItem.fromJson(i as Map<String, dynamic>)],
      history: [for (final h in (j['history'] as List? ?? const [])) ReminderLog.fromJson(h as Map<String, dynamic>)],
      dueCount: _int(s['dueCount']),
      dueAmount: _int(s['dueAmount']),
      totalAmount: _int(s['totalAmount']),
      remindedThisWeek: _int(s['remindedThisWeek']),
    );
  }
}

// =====================================================================
// Fidélité
// =====================================================================

class LoyaltySettings {
  const LoyaltySettings({this.enabled = false, this.earnPer = 1000, this.rewardPoints = 100, this.rewardValue = 2000});
  final bool enabled;
  final int earnPer; // F dépensés pour 1 point
  final int rewardPoints; // points pour une récompense
  final int rewardValue; // remise d'une récompense (F)

  /// Part reversée au client (ex. 0,02 = 2 %).
  double get rate => rewardValue / (rewardPoints * earnPer);
  int pointsFor(int total) => enabled && total > 0 ? total ~/ earnPer : 0;
  int rewardsFor(int balance) => enabled && balance > 0 ? balance ~/ rewardPoints : 0;

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'earnPer': earnPer,
    'rewardPoints': rewardPoints,
    'rewardValue': rewardValue,
  };

  factory LoyaltySettings.fromJson(Map<String, dynamic> j) => LoyaltySettings(
    enabled: j['enabled'] == true,
    earnPer: _int(j['earnPer']),
    rewardPoints: _int(j['rewardPoints']),
    rewardValue: _int(j['rewardValue']),
  );
}

class LoyaltyEntry {
  const LoyaltyEntry({
    required this.id,
    required this.kind,
    required this.points,
    required this.at,
    this.saleId,
    this.note,
  });
  final String id;
  final String kind; // earn, redeem, reverse, adjust
  final int points;
  final DateTime at;
  final String? saleId;
  final String? note;
  factory LoyaltyEntry.fromJson(Map<String, dynamic> j) => LoyaltyEntry(
    id: j['id'] as String,
    kind: j['kind'] as String,
    points: _int(j['points']),
    at: _date(j['at']) ?? DateTime.now(),
    saleId: j['saleId'] as String?,
    note: j['note'] as String?,
  );
}

/// Carte de fidélité d'un client.
class LoyaltyCard {
  const LoyaltyCard({
    required this.settings,
    required this.balance,
    required this.rewardsAvailable,
    required this.pointsToNextReward,
    this.history = const [],
  });
  final LoyaltySettings settings;
  final int balance;
  final int rewardsAvailable;
  final int pointsToNextReward;
  final List<LoyaltyEntry> history;

  /// Avancée vers la prochaine récompense (0 à 1).
  double get progress => settings.rewardPoints == 0
      ? 0
      : ((settings.rewardPoints - pointsToNextReward) / settings.rewardPoints).clamp(0, 1);

  factory LoyaltyCard.fromJson(Map<String, dynamic> j) => LoyaltyCard(
    settings: LoyaltySettings.fromJson(j['settings'] as Map<String, dynamic>),
    balance: _int(j['balance']),
    rewardsAvailable: _int(j['rewardsAvailable']),
    pointsToNextReward: _int(j['pointsToNextReward']),
    history: [for (final h in (j['history'] as List?) ?? const []) LoyaltyEntry.fromJson(h as Map<String, dynamic>)],
  );
}

class TopCustomer {
  const TopCustomer({
    required this.customerId,
    required this.name,
    required this.visits,
    required this.spent,
    required this.lastVisit,
    required this.points,
    this.phone,
  });
  final String customerId;
  final String name;
  final String? phone;
  final int visits;
  final int spent;
  final DateTime lastVisit;
  final int points;
  factory TopCustomer.fromJson(Map<String, dynamic> j) => TopCustomer(
    customerId: j['customerId'] as String,
    name: j['name'] as String,
    phone: j['phone'] as String?,
    visits: _int(j['visits']),
    spent: _int(j['spent']),
    lastVisit: _date(j['lastVisit']) ?? DateTime.now(),
    points: _int(j['points']),
  );
}

class UpcomingBirthday {
  const UpcomingBirthday({
    required this.customerId,
    required this.name,
    required this.day,
    required this.month,
    required this.inDays,
    required this.points,
    this.phone,
  });
  final String customerId;
  final String name;
  final String? phone;
  final int day;
  final int month;
  final int inDays;
  final int points;
  factory UpcomingBirthday.fromJson(Map<String, dynamic> j) => UpcomingBirthday(
    customerId: j['customerId'] as String,
    name: j['name'] as String,
    phone: j['phone'] as String?,
    day: _int(j['day']),
    month: _int(j['month']),
    inDays: _int(j['inDays']),
    points: _int(j['points']),
  );
}

class LoyaltyDashboard {
  const LoyaltyDashboard({
    required this.settings,
    required this.members,
    required this.pointsIssued,
    required this.pointsRedeemed,
    required this.pointsOutstanding,
    this.top = const [],
    this.birthdays = const [],
  });
  final LoyaltySettings settings;
  final int members;
  final int pointsIssued;
  final int pointsRedeemed;
  final int pointsOutstanding;
  final List<TopCustomer> top;
  final List<UpcomingBirthday> birthdays;
  factory LoyaltyDashboard.fromJson(Map<String, dynamic> j) {
    final s = (j['stats'] as Map<String, dynamic>?) ?? const {};
    return LoyaltyDashboard(
      settings: LoyaltySettings.fromJson(j['settings'] as Map<String, dynamic>),
      members: _int(s['members']),
      pointsIssued: _int(s['pointsIssued']),
      pointsRedeemed: _int(s['pointsRedeemed']),
      pointsOutstanding: _int(s['pointsOutstanding']),
      top: [for (final t in (j['top'] as List?) ?? const []) TopCustomer.fromJson(t as Map<String, dynamic>)],
      birthdays: [
        for (final b in (j['birthdays'] as List?) ?? const []) UpcomingBirthday.fromJson(b as Map<String, dynamic>),
      ],
    );
  }
}

// ---------- Analyses ----------

/// Produit en stock qui ne se vend plus.
class DormantProduct {
  const DormantProduct({
    required this.productId,
    required this.name,
    required this.onHand,
    required this.stockValue,
    this.lastSoldAt,
    this.daysSinceSale,
  });
  final String productId;
  final String name;
  final double onHand;
  final int stockValue;
  final DateTime? lastSoldAt;
  final int? daysSinceSale;

  factory DormantProduct.fromJson(Map<String, dynamic> j) => DormantProduct(
    productId: j['productId'] as String,
    name: j['name'] as String,
    onHand: _dbl(j['onHand']),
    stockValue: _int(j['stockValue']),
    lastSoldAt: j['lastSoldAt'] == null ? null : DateTime.parse(j['lastSoldAt'] as String),
    daysSinceSale: (j['daysSinceSale'] as num?)?.toInt(),
  );
}

class RhythmStat {
  const RhythmStat({required this.key, required this.salesCount, required this.revenue});
  final int key; // heure 0–23, ou jour 1 (lundi) – 7 (dimanche)
  final int salesCount;
  final int revenue;
}

/// Créneau le plus chargé, ex. 18 h – 20 h (34 % des ventes).
class PeakWindow {
  const PeakWindow({required this.from, required this.to, required this.share});
  final int from;
  final int to;
  final int share;
  String get label => '$from\u00a0h – $to\u00a0h';

  static PeakWindow? fromJson(Map<String, dynamic>? j) =>
      j == null ? null : PeakWindow(from: _int(j['from']), to: _int(j['to']), share: _int(j['share']));
}

class ProductMargin {
  const ProductMargin({
    this.productId,
    required this.name,
    required this.quantity,
    required this.revenue,
    required this.cost,
    required this.profit,
    this.marginRate,
    required this.costKnown,
  });
  final String? productId;
  final String name;
  final double quantity;
  final int revenue;
  final int cost;
  final int profit;
  final double? marginRate;
  final bool costKnown;

  factory ProductMargin.fromJson(Map<String, dynamic> j) => ProductMargin(
    productId: j['productId'] as String?,
    name: j['name'] as String,
    quantity: _dbl(j['quantity']),
    revenue: _int(j['revenue']),
    cost: _int(j['cost']),
    profit: _int(j['profit']),
    marginRate: (j['marginRate'] as num?)?.toDouble(),
    costKnown: j['costKnown'] as bool? ?? false,
  );
}

class Insights {
  const Insights({
    required this.days,
    required this.dormantCount,
    required this.dormantValue,
    required this.dormant,
    required this.byHour,
    required this.byWeekday,
    this.peak,
    this.bestWeekday,
    required this.marginRate,
    required this.lowMarginThreshold,
    required this.unknownCostCount,
    required this.products,
    required this.lowMargin,
  });
  final int days;
  final int dormantCount;
  final int dormantValue;
  final List<DormantProduct> dormant;
  final List<RhythmStat> byHour;
  final List<RhythmStat> byWeekday;
  final PeakWindow? peak;
  final int? bestWeekday;
  final double? marginRate;
  final int lowMarginThreshold;
  final int unknownCostCount;
  final List<ProductMargin> products;
  final List<ProductMargin> lowMargin;

  bool get hasSales => byHour.any((h) => h.salesCount > 0);

  factory Insights.fromJson(Map<String, dynamic> j) {
    final d = j['dormant'] as Map<String, dynamic>;
    final m = j['margins'] as Map<String, dynamic>;
    List<RhythmStat> stats(String key, String field) => [
      for (final r in (j[key] as List).cast<Map<String, dynamic>>())
        RhythmStat(key: _int(r[field]), salesCount: _int(r['salesCount']), revenue: _int(r['revenue'])),
    ];
    List<ProductMargin> margins(String key) => [
      for (final p in (m[key] as List).cast<Map<String, dynamic>>()) ProductMargin.fromJson(p),
    ];
    return Insights(
      days: _int((j['period'] as Map<String, dynamic>)['days']),
      dormantCount: _int(d['count']),
      dormantValue: _int(d['stockValue']),
      dormant: [for (final x in (d['items'] as List).cast<Map<String, dynamic>>()) DormantProduct.fromJson(x)],
      byHour: stats('byHour', 'hour'),
      byWeekday: stats('byWeekday', 'weekday'),
      peak: PeakWindow.fromJson(j['peak'] as Map<String, dynamic>?),
      bestWeekday: (j['bestWeekday'] as num?)?.toInt(),
      marginRate: (m['marginRate'] as num?)?.toDouble(),
      lowMarginThreshold: _int(m['lowMarginThreshold']),
      unknownCostCount: _int(m['unknownCostCount']),
      products: margins('products'),
      lowMargin: margins('lowMargin'),
    );
  }
}

/// Rapport de la semaine (lundi → dimanche), avec le texte prêt pour WhatsApp.
class WeeklyReport {
  const WeeklyReport({
    required this.from,
    required this.to,
    required this.salesCount,
    required this.revenue,
    required this.netProfit,
    this.revenueChange,
    this.peak,
    this.bestWeekday,
    required this.dormantCount,
    required this.lowMarginCount,
    required this.text,
  });
  final DateTime from;
  final DateTime to;
  final int salesCount;
  final int revenue;
  final int netProfit;
  final double? revenueChange;
  final PeakWindow? peak;
  final int? bestWeekday;
  final int dormantCount;
  final int lowMarginCount;
  final String text;

  factory WeeklyReport.fromJson(Map<String, dynamic> j) => WeeklyReport(
    from: DateTime.parse(j['from'] as String),
    to: DateTime.parse(j['to'] as String),
    salesCount: _int(j['salesCount']),
    revenue: _int(j['revenue']),
    netProfit: _int(j['netProfit']),
    revenueChange: (j['revenueChange'] as num?)?.toDouble(),
    peak: PeakWindow.fromJson(j['peak'] as Map<String, dynamic>?),
    bestWeekday: ((j['bestDay'] as Map<String, dynamic>?)?['weekday'] as num?)?.toInt(),
    dormantCount: _int((j['dormant'] as Map<String, dynamic>?)?['count']),
    lowMarginCount: (j['lowMargin'] as List? ?? const []).length,
    text: j['text'] as String,
  );
}

// ---------- Documents ----------

enum DocCategory {
  admin('admin', 'Administratif', 'Registre, NINEA, autorisations'),
  supplierInvoice('supplier_invoice', 'Factures fournisseurs', 'Achats, marchandises'),
  contract('contract', 'Contrats', 'Bail, assurance, accords'),
  delivery('delivery', 'Livraisons', 'Bons de livraison'),
  receipt('receipt', 'Reçus', 'Électricité, eau, taxes'),
  other('other', 'Autres', 'Tout le reste');

  const DocCategory(this.key, this.label, this.hint);
  final String key;
  final String label;
  final String hint;

  static DocCategory of(String key) => values.firstWhere((c) => c.key == key, orElse: () => other);
}

class BusinessDocument {
  const BusinessDocument({
    required this.id,
    required this.title,
    required this.category,
    this.note,
    this.expiresOn,
    this.expiresInDays,
    this.expiry,
    required this.mime,
    required this.size,
    required this.createdAt,
    this.createdByName,
  });
  final String id;
  final String title;
  final DocCategory category;
  final String? note;
  final DateTime? expiresOn;
  final int? expiresInDays;

  /// « expired », « soon » (≤ 30 jours) ou null.
  final String? expiry;
  final String mime;
  final int size;
  final DateTime createdAt;
  final String? createdByName;

  bool get isPdf => mime == 'application/pdf';

  factory BusinessDocument.fromJson(Map<String, dynamic> j) => BusinessDocument(
    id: j['id'] as String,
    title: j['title'] as String,
    category: DocCategory.of(j['category'] as String),
    note: j['note'] as String?,
    expiresOn: j['expiresOn'] == null ? null : DateTime.parse(j['expiresOn'] as String),
    expiresInDays: (j['expiresInDays'] as num?)?.toInt(),
    expiry: j['expiry'] as String?,
    mime: j['mime'] as String,
    size: _int(j['size']),
    createdAt: DateTime.parse(j['createdAt'] as String),
    createdByName: j['createdByName'] as String?,
  );
}

class DocumentList {
  const DocumentList({required this.items, required this.counts, required this.total, required this.attention});
  final List<BusinessDocument> items;
  final Map<DocCategory, int> counts;
  final int total;

  /// Échéances dépassées ou dans les 30 jours.
  final int attention;

  factory DocumentList.fromJson(Map<String, dynamic> j) => DocumentList(
    items: [for (final d in (j['items'] as List).cast<Map<String, dynamic>>()) BusinessDocument.fromJson(d)],
    counts: {
      for (final e in ((j['counts'] as Map?) ?? const {}).entries) DocCategory.of(e.key as String): _int(e.value),
    },
    total: _int(j['total']),
    attention: _int(j['attention']),
  );
}

// ---------- Assistant IA ----------

class AssistantStatus {
  const AssistantStatus({required this.enabled, required this.remaining, required this.suggestions});
  final bool enabled;
  final int remaining;
  final List<String> suggestions;

  factory AssistantStatus.fromJson(Map<String, dynamic> j) => AssistantStatus(
    enabled: j['enabled'] == true,
    remaining: _int(j['remaining']),
    suggestions: List<String>.from((j['suggestions'] as List?) ?? const []),
  );
}

class ChatMessage {
  const ChatMessage({required this.fromUser, required this.text, this.failed = false});
  final bool fromUser;
  final String text;

  /// Question restée sans réponse (réseau, limite…) : on peut la renvoyer.
  final bool failed;

  Map<String, String> toJson() => {'role': fromUser ? 'user' : 'assistant', 'content': text};
}

class AssistantReply {
  const AssistantReply({required this.reply, required this.remaining});
  final String reply;
  final int remaining;

  factory AssistantReply.fromJson(Map<String, dynamic> j) =>
      AssistantReply(reply: j['reply'] as String, remaining: _int(j['remaining']));
}

// ---------- Réservation ----------

enum AppointmentStatus {
  booked('booked', 'Prévu'),
  done('done', 'Venu'),
  noShow('no_show', 'Absent'),
  cancelled('cancelled', 'Annulé');

  const AppointmentStatus(this.key, this.label);
  final String key;
  final String label;

  static AppointmentStatus of(String k) => values.firstWhere((s) => s.key == k, orElse: () => booked);
}

class Appointment {
  const Appointment({
    required this.id,
    this.customerId,
    required this.customerName,
    this.customerPhone,
    this.serviceId,
    required this.serviceName,
    required this.price,
    required this.startsAt,
    required this.durationMinutes,
    required this.status,
    this.note,
    this.overlaps = false,
    this.online = false,
  });
  final String id;
  final String? customerId;
  final String customerName;
  final String? customerPhone;
  final String? serviceId;
  final String serviceName;
  final int price;
  final DateTime startsAt;
  final int durationMinutes;
  final AppointmentStatus status;
  final String? note;

  /// Croise un autre rendez-vous actif (avertissement, sans blocage).
  final bool overlaps;

  /// Pris par le client sur la page de réservation en ligne.
  final bool online;

  DateTime get endsAt => startsAt.add(Duration(minutes: durationMinutes));

  factory Appointment.fromJson(Map<String, dynamic> j) => Appointment(
    id: j['id'] as String,
    customerId: j['customerId'] as String?,
    customerName: j['customerName'] as String,
    customerPhone: j['customerPhone'] as String?,
    serviceId: j['serviceId'] as String?,
    serviceName: j['serviceName'] as String,
    price: _int(j['price']),
    startsAt: DateTime.parse(j['startsAt'] as String).toLocal(),
    durationMinutes: _int(j['durationMinutes']),
    status: AppointmentStatus.of(j['status'] as String),
    note: j['note'] as String?,
    overlaps: j['overlaps'] == true,
    online: j['source'] == 'online',
  );
}

class AppointmentList {
  const AppointmentList({required this.items, required this.bookedByDay});
  final List<Appointment> items;

  /// « 2026-11-17 » → nombre de rendez-vous prévus (points sur la bande des jours).
  final Map<String, int> bookedByDay;

  factory AppointmentList.fromJson(Map<String, dynamic> j) => AppointmentList(
    items: [for (final a in (j['items'] as List).cast<Map<String, dynamic>>()) Appointment.fromJson(a)],
    bookedByDay: {for (final e in ((j['bookedByDay'] as Map?) ?? const {}).entries) e.key as String: _int(e.value)},
  );
}

/// Ce qu'on envoie pour créer ou modifier un rendez-vous.
class AppointmentDraft {
  const AppointmentDraft({
    this.customerId,
    this.customerName,
    this.customerPhone,
    this.serviceId,
    this.serviceName,
    this.price,
    required this.startsAt,
    required this.durationMinutes,
    this.note,
  });
  final String? customerId;
  final String? customerName;
  final String? customerPhone;
  final String? serviceId;
  final String? serviceName;
  final int? price;
  final DateTime startsAt;
  final int durationMinutes;
  final String? note;

  Map<String, Object?> toJson() => {
    'customerId': customerId,
    'customerName': customerId == null ? customerName : null,
    'customerPhone': customerId == null && (customerPhone ?? '').isNotEmpty ? customerPhone : null,
    'serviceId': serviceId,
    'serviceName': serviceId == null ? serviceName : null,
    'price': price,
    'startsAt': startsAt.toUtc().toIso8601String(),
    'durationMinutes': durationMinutes,
    'note': (note ?? '').trim().isEmpty ? null : note!.trim(),
  };
}

/// Réglages de la réservation en ligne.
class BookingSettings {
  const BookingSettings({
    this.onlineEnabled = false,
    this.openDays = const [1, 2, 3, 4, 5, 6],
    this.openTime = '09:00',
    this.closeTime = '19:00',
    this.slotMinutes = 30,
    this.capacity = 1,
    this.minNoticeMinutes = 60,
    this.maxDaysAhead = 30,
    this.bookingPath,
  });
  final bool onlineEnabled;
  final List<int> openDays; // 1 = lundi … 7 = dimanche
  final String openTime;
  final String closeTime;
  final int slotMinutes;
  final int capacity;
  final int minNoticeMinutes;
  final int maxDaysAhead;

  /// « /r/awa-beaute » : page publique de réservation.
  final String? bookingPath;

  BookingSettings copyWith({
    bool? onlineEnabled,
    List<int>? openDays,
    String? openTime,
    String? closeTime,
    int? slotMinutes,
    int? capacity,
    int? minNoticeMinutes,
    int? maxDaysAhead,
  }) => BookingSettings(
    onlineEnabled: onlineEnabled ?? this.onlineEnabled,
    openDays: openDays ?? this.openDays,
    openTime: openTime ?? this.openTime,
    closeTime: closeTime ?? this.closeTime,
    slotMinutes: slotMinutes ?? this.slotMinutes,
    capacity: capacity ?? this.capacity,
    minNoticeMinutes: minNoticeMinutes ?? this.minNoticeMinutes,
    maxDaysAhead: maxDaysAhead ?? this.maxDaysAhead,
    bookingPath: bookingPath,
  );

  factory BookingSettings.fromJson(Map<String, dynamic> j) => BookingSettings(
    onlineEnabled: j['onlineEnabled'] == true,
    openDays: [for (final d in (j['openDays'] as List? ?? const [])) _int(d)],
    openTime: j['openTime'] as String? ?? '09:00',
    closeTime: j['closeTime'] as String? ?? '19:00',
    slotMinutes: _int(j['slotMinutes']),
    capacity: _int(j['capacity']),
    minNoticeMinutes: _int(j['minNoticeMinutes']),
    maxDaysAhead: _int(j['maxDaysAhead']),
    bookingPath: j['bookingPath'] as String?,
  );

  Map<String, Object> toJson() => {
    'onlineEnabled': onlineEnabled,
    'openDays': openDays,
    'openTime': openTime,
    'closeTime': closeTime,
    'slotMinutes': slotMinutes,
    'capacity': capacity,
    'minNoticeMinutes': minNoticeMinutes,
    'maxDaysAhead': maxDaysAhead,
  };
}

// ---------- Premiers pas ----------

class OnboardingStep {
  const OnboardingStep(this.key, this.done);
  final String key;
  final bool done;
}

class Onboarding {
  const Onboarding({this.focus, required this.dismissed, required this.steps});

  /// « products », « services », « both » ; null : pas encore répondu.
  final String? focus;
  final bool dismissed;
  final List<OnboardingStep> steps;

  factory Onboarding.fromJson(Map<String, dynamic> j) => Onboarding(
    focus: j['focus'] as String?,
    dismissed: j['dismissed'] == true,
    steps: [
      for (final s in (j['steps'] as List).cast<Map<String, dynamic>>())
        OnboardingStep(s['key'] as String, s['done'] == true),
    ],
  );
}

// ---------- Livraison ----------

const vehicleLabels = {'moto': 'Moto', 'voiture': 'Voiture', 'velo': 'Vélo', 'pied': 'À pied'};

class Courier {
  const Courier({required this.id, required this.name, this.phone, this.vehicle = 'moto', this.active = true});
  final String id;
  final String name;
  final String? phone;
  final String vehicle;
  final bool active;

  factory Courier.fromJson(Map<String, dynamic> j) => Courier(
    id: j['id'] as String,
    name: j['name'] as String,
    phone: j['phone'] as String?,
    vehicle: j['vehicle'] as String? ?? 'moto',
    active: j['active'] != false,
  );
}

enum DeliveryStatus {
  pending('pending', 'À assigner'),
  assigned('assigned', 'Assignée'),
  picked('picked', 'En route'),
  delivered('delivered', 'Livrée'),
  failed('failed', 'Échec'),
  cancelled('cancelled', 'Annulée');

  const DeliveryStatus(this.key, this.label);
  final String key;
  final String label;

  static DeliveryStatus of(String k) => values.firstWhere((s) => s.key == k, orElse: () => pending);
}

class Delivery {
  const Delivery({
    required this.id,
    this.orderId,
    this.orderNumber,
    required this.customerName,
    this.customerPhone,
    required this.address,
    this.note,
    this.courierId,
    this.courierName,
    this.courierPhone,
    this.fee = 0,
    this.amountToCollect = 0,
    required this.status,
    this.failureReason,
    this.settled = false,
  });
  final String id;
  final String? orderId;
  final String? orderNumber;
  final String customerName;
  final String? customerPhone;
  final String address;
  final String? note;
  final String? courierId;
  final String? courierName;
  final String? courierPhone;
  final int fee;
  final int amountToCollect;
  final DeliveryStatus status;
  final String? failureReason;
  final bool settled;

  factory Delivery.fromJson(Map<String, dynamic> j) => Delivery(
    id: j['id'] as String,
    orderId: j['orderId'] as String?,
    orderNumber: j['orderNumber'] as String?,
    customerName: j['customerName'] as String,
    customerPhone: j['customerPhone'] as String?,
    address: j['address'] as String,
    note: j['note'] as String?,
    courierId: j['courierId'] as String?,
    courierName: j['courierName'] as String?,
    courierPhone: j['courierPhone'] as String?,
    fee: _int(j['fee']),
    amountToCollect: _int(j['amountToCollect']),
    status: DeliveryStatus.of(j['status'] as String),
    failureReason: j['failureReason'] as String?,
    settled: j['settled'] == true,
  );
}

/// Commande en ligne confirmée, à confier à un livreur.
class OrderToDeliver {
  const OrderToDeliver({
    required this.orderId,
    required this.number,
    required this.customerName,
    required this.customerPhone,
    required this.address,
    required this.total,
  });
  final String orderId;
  final String number;
  final String customerName;
  final String customerPhone;
  final String address;
  final int total;

  factory OrderToDeliver.fromJson(Map<String, dynamic> j) => OrderToDeliver(
    orderId: j['orderId'] as String,
    number: j['number'] as String,
    customerName: j['customerName'] as String,
    customerPhone: j['customerPhone'] as String,
    address: j['address'] as String? ?? '',
    total: _int(j['total']),
  );
}

/// Argent encaissé par un livreur, pas encore remis.
class CourierBalance {
  const CourierBalance({
    required this.courierId,
    required this.name,
    this.phone,
    required this.owed,
    required this.deliveries,
  });
  final String courierId;
  final String name;
  final String? phone;
  final int owed;
  final int deliveries;

  factory CourierBalance.fromJson(Map<String, dynamic> j) => CourierBalance(
    courierId: j['courierId'] as String,
    name: j['name'] as String,
    phone: j['phone'] as String?,
    owed: _int(j['owed']),
    deliveries: _int(j['deliveries']),
  );
}

class DeliveryBoard {
  const DeliveryBoard({required this.toAssign, required this.items, required this.withCouriers});
  final List<OrderToDeliver> toAssign;
  final List<Delivery> items;
  final List<CourierBalance> withCouriers;

  factory DeliveryBoard.fromJson(Map<String, dynamic> j) => DeliveryBoard(
    toAssign: [for (final o in (j['toAssign'] as List).cast<Map<String, dynamic>>()) OrderToDeliver.fromJson(o)],
    items: [for (final d in (j['items'] as List).cast<Map<String, dynamic>>()) Delivery.fromJson(d)],
    withCouriers: [
      for (final c in (j['withCouriers'] as List).cast<Map<String, dynamic>>()) CourierBalance.fromJson(c),
    ],
  );
}

// ---------- Facture fournisseur en photo ----------

/// Degré de certitude du rapprochement d'une ligne de facture avec un produit.
enum ScanConfidence {
  memory, // déjà associé chez ce fournisseur
  high,
  low,
  none;

  static ScanConfidence of(String? v) => values.where((c) => c.name == v).firstOrNull ?? none;
}

class ScanCandidate {
  const ScanCandidate({
    required this.id,
    required this.name,
    required this.unit,
    required this.cost,
    required this.price,
  });
  final String id;
  final String name;
  final String unit;
  final int cost;
  final int price;

  factory ScanCandidate.fromJson(Map<String, dynamic> j) => ScanCandidate(
    id: j['id'] as String,
    name: j['name'] as String,
    unit: (j['unit'] as String?) ?? 'pièce',
    cost: (j['cost'] as num?)?.toInt() ?? 0,
    price: (j['price'] as num?)?.toInt() ?? 0,
  );
}

class ScannedLine {
  const ScannedLine({
    required this.label,
    required this.quantity,
    required this.unitCost,
    required this.productId,
    required this.confidence,
    required this.candidates,
  });
  final String label;
  final double quantity;
  final int unitCost;
  final String? productId;
  final ScanConfidence confidence;
  final List<ScanCandidate> candidates;

  ScanCandidate? get product => candidates.where((c) => c.id == productId).firstOrNull;

  factory ScannedLine.fromJson(Map<String, dynamic> j) => ScannedLine(
    label: j['label'] as String,
    quantity: (j['quantity'] as num).toDouble(),
    unitCost: (j['unitCost'] as num).toInt(),
    productId: j['productId'] as String?,
    confidence: ScanConfidence.of(j['confidence'] as String?),
    candidates: [
      for (final c in (j['candidates'] as List? ?? const [])) ScanCandidate.fromJson(c as Map<String, dynamic>),
    ],
  );
}

/// Ce que le serveur a lu sur la photo, rapproché du catalogue (rien n'est encore enregistré).
class InvoiceScan {
  const InvoiceScan({
    required this.readable,
    required this.supplierId,
    required this.supplierName,
    required this.supplierPhone,
    required this.number,
    required this.date,
    required this.total,
    required this.lines,
    required this.remaining,
  });
  final bool readable;
  final String? supplierId;
  final String? supplierName;
  final String? supplierPhone;
  final String? number;
  final DateTime? date;
  final int? total;
  final List<ScannedLine> lines;
  final int remaining;

  factory InvoiceScan.fromJson(Map<String, dynamic> j) {
    final s = (j['supplier'] as Map<String, dynamic>?) ?? const {};
    return InvoiceScan(
      readable: j['readable'] as bool? ?? false,
      supplierId: s['id'] as String?,
      supplierName: s['name'] as String?,
      supplierPhone: s['phone'] as String?,
      number: j['number'] as String?,
      date: DateTime.tryParse((j['date'] as String?) ?? ''),
      total: (j['total'] as num?)?.toInt(),
      lines: [for (final l in (j['lines'] as List? ?? const [])) ScannedLine.fromJson(l as Map<String, dynamic>)],
      remaining: (j['remaining'] as num?)?.toInt() ?? 0,
    );
  }
}

// ---------- Points de vente ----------

/// Point de vente (boutique) : son stock, sa caisse, ses ventes ; catalogue et clients communs.
class ShopLocation {
  const ShopLocation({
    required this.id,
    required this.name,
    this.address,
    this.phone,
    this.isDefault = false,
    this.members = 0,
    this.todayRevenue = 0,
    this.stockValue = 0,
  });
  final String id;
  final String name;
  final String? address;
  final String? phone;
  final bool isDefault;
  final int members;
  final int todayRevenue;
  final int stockValue;

  factory ShopLocation.fromJson(Map<String, dynamic> j) => ShopLocation(
    id: j['id'] as String,
    name: j['name'] as String,
    address: j['address'] as String?,
    phone: j['phone'] as String?,
    isDefault: j['isDefault'] == true,
    members: _int(j['members']),
    todayRevenue: _int(j['todayRevenue']),
    stockValue: _int(j['stockValue']),
  );
}

/// Points de vente ouverts et celui actif pour moi.
class LocationsState {
  const LocationsState({required this.list, this.currentId, required this.writeTo, this.locked = false});
  final List<ShopLocation> list;

  /// Point de vente regardé ; null = tous.
  final String? currentId;

  /// Où vont mes ventes, ma caisse et mes mouvements de stock.
  final String writeTo;

  /// Vendeur rattaché à un point de vente : il ne peut pas en changer.
  final bool locked;

  bool get several => list.length > 1;
  ShopLocation? byId(String? id) => list.where((l) => l.id == id).firstOrNull;
  ShopLocation? get current => byId(currentId);
  ShopLocation? get writeLocation => byId(writeTo);
  String nameOf(String? id) => byId(id)?.name ?? 'Point de vente fermé';

  factory LocationsState.fromJson(Map<String, dynamic> j) {
    final c = (j['current'] as Map<String, dynamic>?) ?? const {};
    return LocationsState(
      list: [for (final l in j['data'] as List) ShopLocation.fromJson(l as Map<String, dynamic>)],
      currentId: c['id'] as String?,
      writeTo: c['writeTo'] as String? ?? '',
      locked: c['locked'] == true,
    );
  }
}

class StockTransfer {
  const StockTransfer({
    required this.id,
    required this.number,
    required this.fromName,
    required this.toName,
    required this.lines,
    this.createdByName,
    required this.createdAt,
  });
  final String id;
  final String number;
  final String fromName;
  final String toName;
  final List<({String productId, String name, double quantity})> lines;
  final String? createdByName;
  final DateTime createdAt;

  factory StockTransfer.fromJson(Map<String, dynamic> j) => StockTransfer(
    id: j['id'] as String,
    number: j['number'] as String,
    fromName: (j['from'] as Map)['name'] as String,
    toName: (j['to'] as Map)['name'] as String,
    lines: [
      for (final l in j['lines'] as List)
        (productId: (l as Map)['productId'] as String, name: l['name'] as String, quantity: _num(l['quantity'])),
    ],
    createdByName: j['createdByName'] as String?,
    createdAt: DateTime.parse(j['createdAt'] as String).toLocal(),
  );
}
