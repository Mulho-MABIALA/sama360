/// Modèles alignés sur les réponses de l'API Sama360 (apps/api).
library;

int _int(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
double _num(Object? v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
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
      role: me['role'] as String,
      permissions: List<String>.from(me['permissions'] as List),
      modules: ((j['modules'] as List?) ?? const [])
          .where((m) => (m as Map)['enabled'] == true)
          .map((m) => (m as Map)['module'] as String)
          .toList(),
    );
  }
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
    this.unit = 'pièce',
    this.barcode,
    this.sku,
    this.wholesalePrice,
    this.wholesaleMinQty,
  });
  final String id;
  final String name;
  final int price;
  final int cost;
  final String? categoryId;
  final bool trackStock;
  final int lowStockThreshold;
  final String? imageFileId; // photo principale (GET /v1/files/:id)
  final bool isService;
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
    unit: j['unit'] as String? ?? 'pièce',
    barcode: j['barcode'] as String?,
    sku: j['sku'] as String?,
    wholesalePrice: j['wholesalePrice'] == null ? null : _int(j['wholesalePrice']),
    wholesaleMinQty: j['wholesaleMinQty'] == null ? null : _num(j['wholesaleMinQty']),
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
    this.unit = 'pièce',
    this.barcode,
    this.sku,
    this.trackStock = true,
    this.lowStockThreshold = 5,
    this.wholesalePrice,
    this.wholesaleMinQty,
  });
  final String name;
  final int price;
  final int cost;
  final String? categoryId;
  final bool isService;
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
  });
  final String productId;
  final String name;
  final int price;
  final int cost;
  final int threshold;
  final double onHand;
  final bool low;
  final String? imageFileId;

  factory StockItem.fromJson(Map<String, dynamic> j) => StockItem(
    productId: j['productId'] as String,
    name: j['name'] as String,
    price: _int(j['price']),
    cost: _int(j['cost']),
    threshold: _int(j['threshold']),
    onHand: _num(j['onHand']),
    low: j['low'] as bool? ?? false,
    imageFileId: j['imageFileId'] as String?,
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

  factory DaySummary.fromJson(Map<String, dynamic> j) => DaySummary(
    salesCount: _int(j['salesCount']),
    revenue: _int(j['revenue']),
    grossProfit: _int(j['grossProfit']),
    netProfit: _int(j['netProfit']),
    expenses: _int(j['expenses']),
    collected: _int(j['collected']),
    receivables: _int(j['receivables']),
    bySeller: [for (final v in (j['bySeller'] as List?) ?? const []) SellerStat.fromJson(v as Map<String, dynamic>)],
  );
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
  });
  final String id;
  final String userId;
  final String phone;
  final String? fullName;
  final String role;
  final String roleName;
  final String status; // active, invited, suspended
  final String? avatarFileId;

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
  });
  final String id;
  final String name;
  final String? phone;
  final int balance;
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
  );
}

/// Saisie d'une fiche client (création ou modification).
class CustomerDraft {
  const CustomerDraft({required this.name, this.phone, this.email, this.address, this.notes, this.creditLimit});
  final String name;
  final String? phone;
  final String? email;
  final String? address;
  final String? notes;
  final int? creditLimit;

  Map<String, dynamic> toJson({bool withLimit = true}) => {
    'name': name,
    'phone': phone,
    'email': email,
    'address': address,
    'notes': notes,
    if (withLimit) 'creditLimit': creditLimit,
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

  factory CustomerTopProduct.fromJson(Map<String, dynamic> j) => CustomerTopProduct(
    name: j['name'] as String,
    quantity: (j['quantity'] as num?)?.toDouble() ?? 0,
    total: _int(j['total']),
  );
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
  );
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
