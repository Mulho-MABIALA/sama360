/// Modèles alignés sur les réponses de l'API Sama360 (apps/api).
library;

int _int(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
double _num(Object? v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
DateTime? _date(Object? v) => v == null ? null : DateTime.tryParse('$v');

class Me {
  const Me({required this.id, required this.phone, this.fullName, this.businesses = const []});
  final String id;
  final String phone;
  final String? fullName;
  final List<BusinessLink> businesses;

  factory Me.fromJson(Map<String, dynamic> j) {
    final u = j['user'] as Map<String, dynamic>;
    return Me(
      id: u['id'] as String,
      phone: u['phone'] as String,
      fullName: u['fullName'] as String?,
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
  const Category({required this.id, required this.name});
  final String id;
  final String name;
  factory Category.fromJson(Map<String, dynamic> j) => Category(id: j['id'] as String, name: j['name'] as String);
}

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
  });
  final String id;
  final String name;
  final int price;
  final int cost;
  final String? categoryId;
  final bool trackStock;
  final int lowStockThreshold;
  final String? imageFileId; // photo principale (GET /v1/files/:id)

  factory Product.fromJson(Map<String, dynamic> j) => Product(
    id: j['id'] as String,
    name: j['name'] as String,
    price: _int(j['price']),
    cost: _int(j['cost']),
    categoryId: j['categoryId'] as String?,
    trackStock: j['trackStock'] as bool? ?? true,
    lowStockThreshold: _int(j['lowStockThreshold']),
    imageFileId: ((j['imageFileIds'] as List?) ?? const []).cast<String>().firstOrNull,
  );
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
  });
  final int salesCount;
  final int revenue;
  final int grossProfit;
  final int netProfit;
  final int expenses;
  final int collected;
  final int receivables;

  factory DaySummary.fromJson(Map<String, dynamic> j) => DaySummary(
    salesCount: _int(j['salesCount']),
    revenue: _int(j['revenue']),
    grossProfit: _int(j['grossProfit']),
    netProfit: _int(j['netProfit']),
    expenses: _int(j['expenses']),
    collected: _int(j['collected']),
    receivables: _int(j['receivables']),
  );
}

class Contact {
  const Contact({required this.id, required this.name, this.phone, this.balance = 0});
  final String id;
  final String name;
  final String? phone;
  final int balance;

  factory Contact.fromJson(Map<String, dynamic> j) => Contact(
    id: j['id'] as String,
    name: j['name'] as String,
    phone: j['phone'] as String?,
    balance: _int(j['balance']),
  );
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
  });
  final String id;
  final String type; // debt, repayment, adjustment
  final int amount;
  final String? note;
  final String? method;
  final DateTime at;

  factory LedgerEntry.fromJson(Map<String, dynamic> j) => LedgerEntry(
    id: j['id'] as String,
    type: j['entryType'] as String,
    amount: _int(j['amount']),
    note: j['note'] as String?,
    method: j['method'] as String?,
    at: _date(j['occurredAt']) ?? DateTime.now(),
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
  const ReceiptLine({required this.name, required this.quantity, required this.unitPrice, this.discount = 0, required this.total});
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
    required this.total,
    required this.due,
    required this.soldAt,
  });
  final String id;
  final String number;
  final String status;
  final String? customerName;
  final int total;
  final int due;
  final DateTime soldAt;

  factory SaleSummary.fromJson(Map<String, dynamic> j) => SaleSummary(
    id: j['id'] as String,
    number: j['number'] as String,
    status: j['status'] as String? ?? 'completed',
    customerName: j['customerName'] as String?,
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
  card('card', 'Carte');

  const PayMethod(this.api, this.label);
  final String api;
  final String label;

  static PayMethod? fromApi(String? v) => PayMethod.values.where((m) => m.api == v).firstOrNull;
}
