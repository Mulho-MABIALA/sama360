import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:sama360/core/api/api_client.dart';
import 'package:sama360/core/api/session_store.dart';
import 'package:sama360/core/glass.dart';
import 'package:sama360/core/models.dart';
import 'package:sama360/core/providers.dart';
import 'package:sama360/core/repositories.dart';
import 'package:sama360/features/auth/auth_controller.dart';
import 'package:sama360/main.dart';
import 'package:sama360/router.dart';

/// Données de démonstration (persona Awa du cahier des charges).
const demoBusiness = CurrentBusiness(
  id: 'b1',
  name: 'Awa Beauté',
  slug: 'awa-beaute',
  city: 'Dakar',
  phone: '+221 77 123 45 67',
  address: 'Marché Sandaga',
  role: 'owner',
  permissions: ['*'],
  modules: ['sales', 'inventory'],
);
const demoMe = Me(
  id: 'u1',
  phone: '+221771234567',
  fullName: 'Awa Diallo',
  createdAt: null,
  businesses: [
    BusinessLink(id: 'b1', name: 'Awa Beauté', category: 'boutique', role: 'owner', roleName: 'Propriétaire'),
  ],
);
const demoProducts = [
  Product(id: 'p1', name: 'Beurre de karité 250 g', price: 3500, cost: 2000, categoryId: 'c1'),
  Product(
    id: 'p2',
    name: 'Savon noir',
    price: 1500,
    cost: 800,
    categoryId: 'c1',
    barcode: '6001234567891',
    wholesalePrice: 1200,
    wholesaleMinQty: 10,
  ),
  Product(id: 'p3', name: 'Huile de coco 500 ml', price: 4000, cost: 2600, categoryId: 'c1', lowStockThreshold: 5),
  Product(id: 'p4', name: 'Crème éclaircissante bio', price: 6500, cost: 4000, categoryId: 'c2'),
  Product(id: 'p5', name: 'Shampoing aloe vera', price: 2800, cost: 2000, categoryId: 'c2'),
  Product(id: 'p6', name: 'Parfum Thiouraye', price: 5000, cost: 3000, categoryId: 'c2'),
];

StockItem _stock(Product p, double onHand) => StockItem(
  productId: p.id,
  name: p.name,
  price: p.price,
  cost: p.cost,
  threshold: 5,
  onHand: onHand,
  low: onHand <= 5,
);

/// Dépôt factice : enregistre les appels de vente, renvoie des données de démo.
class FakeRepo extends SamaRepository {
  FakeRepo() : super(ApiClient(baseUrl: 'http://localhost', store: MemorySessionStore()));

  final sales = <Map<String, dynamic>>[];
  final createdProducts = <String>[];
  final uploads = <String, int>{}; // productId → taille de la photo envoyée
  int saleCounter = 0;

  @override
  Future<Product> createProduct({
    required String name,
    required int price,
    int cost = 0,
    String? categoryId,
    int lowStockThreshold = 5,
  }) async {
    createdProducts.add(name);
    return Product(id: 'new-${createdProducts.length}', name: name, price: price, cost: cost);
  }

  final savedDrafts = <(String?, ProductDraft)>[];
  final deletedProducts = <String>[];
  final categoryOps = <String>[];

  @override
  Future<Product> saveProduct(ProductDraft d, {String? id}) async {
    savedDrafts.add((id, d));
    if (d.barcode == '0000000000000') {
      throw const ApiException('CONFLICT', 'Ce code-barres est déjà utilisé par « Savon noir »', status: 409);
    }
    if (id == null) createdProducts.add(d.name);
    return Product(
      id: id ?? 'new-${createdProducts.length}',
      name: d.name,
      price: d.price,
      cost: d.cost,
      barcode: d.barcode,
      wholesalePrice: d.wholesalePrice,
      wholesaleMinQty: d.wholesaleMinQty,
    );
  }

  @override
  Future<Product> product(String id) async => demoProducts.firstWhere((p) => p.id == id);

  @override
  Future<Product?> productByCode(String code) async => demoProducts.where((p) => p.barcode == code).firstOrNull;

  @override
  Future<void> deleteProduct(String id) async => deletedProducts.add(id);

  @override
  Future<Category> createCategory(String name) async {
    categoryOps.add('create $name');
    return Category(id: 'cat-${categoryOps.length}', name: name);
  }

  @override
  Future<void> renameCategory(String id, String name) async => categoryOps.add('rename $id $name');

  @override
  Future<void> deleteCategory(String id) async => categoryOps.add('delete $id');

  @override
  Future<Product> uploadProductImage(String productId, List<int> bytes, {String filename = 'photo.jpg'}) async {
    uploads[productId] = bytes.length;
    return Product(id: productId, name: 'x', price: 0, cost: 0, imageFileId: 'f-$productId');
  }

  /// Logo de l'entreprise (null : pas de logo).
  String? logoFileId;
  int logoUploads = 0;

  @override
  Future<CurrentBusiness> currentBusiness() async => logoFileId == null
      ? demoBusiness
      : CurrentBusiness(
          id: demoBusiness.id,
          name: demoBusiness.name,
          slug: demoBusiness.slug,
          city: demoBusiness.city,
          phone: demoBusiness.phone,
          address: demoBusiness.address,
          logoFileId: logoFileId,
          role: demoBusiness.role,
          permissions: demoBusiness.permissions,
          modules: demoBusiness.modules,
        );

  @override
  Future<void> uploadBusinessLogo(List<int> bytes, {String filename = 'logo.png'}) async =>
      logoFileId = 'logo-${++logoUploads}';

  @override
  Future<void> deleteBusinessLogo() async => logoFileId = null;

  @override
  Future<List<int>?> fileBytes(String fileId) async => null;
  @override
  Future<List<Category>> categories() async => const [
    Category(id: 'c1', name: 'Soins', productCount: 3),
    Category(id: 'c2', name: 'Cheveux & parfums', productCount: 3),
  ];
  @override
  Future<List<Product>> products({String? search, String? categoryId}) async => demoProducts;
  @override
  Future<StockOverview> stock({bool lowOnly = false}) async {
    final items = [
      _stock(demoProducts[5], 2),
      _stock(demoProducts[2], 3),
      _stock(demoProducts[0], 24),
      _stock(demoProducts[3], 12),
      _stock(demoProducts[4], 18),
      _stock(demoProducts[1], 40),
    ];
    return StockOverview(items: items, lowStock: 2, stockValue: 1240000);
  }

  @override
  Future<DaySummary> todaySummary() async => const DaySummary(
    salesCount: 12,
    revenue: 86500,
    grossProfit: 23300,
    netProfit: 21300,
    expenses: 2000,
    collected: 52500,
    receivables: 34000,
    bySeller: [
      SellerStat(userId: 'u1', name: 'Awa Diallo', salesCount: 7, revenue: 52000),
      SellerStat(userId: 'u2', name: 'Moussa Fall', salesCount: 4, revenue: 28500),
      SellerStat(userId: 'u3', name: '+221770000099', salesCount: 1, revenue: 6000),
    ],
  );

  @override
  Future<List<Debtor>> debtors() async => [
    Debtor(
      customerId: 'k1',
      name: 'Fatou Ndiaye',
      phone: '+221774120855',
      balance: 17500,
      firstDebtAt: DateTime(2026, 11, 2),
    ),
    Debtor(
      customerId: 'k2',
      name: 'Aminata Ba',
      phone: '+221765551234',
      balance: 10000,
      firstDebtAt: DateTime(2026, 11, 9),
    ),
    Debtor(customerId: 'k3', name: 'Mariama Sow', balance: 6500, firstDebtAt: DateTime(2026, 11, 12)),
  ];

  @override
  Future<Ledger> ledger(String customerId) async => Ledger(
    customer: const Contact(id: 'k1', name: 'Fatou Ndiaye', phone: '+221774120855', balance: 17500),
    balance: 17500,
    entries: [
      LedgerEntry(id: 'e1', type: 'debt', amount: 4000, note: 'VEN-2026-0412', at: DateTime(2026, 11, 14, 10, 32)),
      LedgerEntry(id: 'e2', type: 'repayment', amount: -10000, method: 'wave', at: DateTime(2026, 11, 9, 18, 5)),
      LedgerEntry(id: 'e3', type: 'debt', amount: 8500, note: 'VEN-2026-0388', at: DateTime(2026, 11, 6, 11, 20)),
      LedgerEntry(id: 'e4', type: 'debt', amount: 15000, note: 'VEN-2026-0351', at: DateTime(2026, 11, 2, 16, 47)),
    ],
  );

  // ---------- Clients et crédit ----------
  final savedCustomers = <(String?, Map<String, dynamic>)>[]; // (id modifié, corps envoyé)
  final deletedCustomers = <String>[];
  final adjustments = <(String, int, String)>[];
  final reminders = <(String, String)>[];
  final customerQueries = <(String?, CustomerFilter, CustomerSort)>[];

  static final demoCustomers = [
    CustomerRow(
      id: 'k1',
      name: 'Fatou Ndiaye',
      phone: '+221774120855',
      balance: 17500,
      creditLimit: 25000,
      salesCount: 6,
      totalSpent: 64500,
      lastPurchaseAt: DateTime(2026, 11, 14, 10, 32),
      firstDebtAt: DateTime(2026, 11, 2),
    ),
    CustomerRow(
      id: 'k2',
      name: 'Coumba Diop',
      phone: '+221775550011',
      balance: 12000,
      creditLimit: 10000,
      salesCount: 3,
      totalSpent: 21000,
      lastPurchaseAt: DateTime(2026, 11, 10),
      firstDebtAt: DateTime(2026, 11, 4),
    ),
    CustomerRow(
      id: 'k3',
      name: 'Mariama Sow',
      balance: 6500,
      salesCount: 2,
      totalSpent: 9000,
      lastPurchaseAt: DateTime(2026, 11, 12),
      firstDebtAt: DateTime(2026, 11, 12),
    ),
    CustomerRow(
      id: 'c1',
      name: 'Hôtel Teranga',
      phone: '+221338200000',
      balance: 0,
      salesCount: 12,
      totalSpent: 318000,
      lastPurchaseAt: DateTime(2026, 11, 15),
    ),
    const CustomerRow(id: 'c9', name: 'Ousmane Fall', phone: '+221701234567', balance: 0),
  ];

  @override
  Future<CustomerList> customerList({
    String? search,
    CustomerFilter filter = CustomerFilter.all,
    CustomerSort sort = CustomerSort.name,
  }) async {
    customerQueries.add((search, filter, sort));
    var rows = demoCustomers.where(
      (c) => switch (filter) {
        CustomerFilter.all => true,
        CustomerFilter.debt => c.balance > 0,
        CustomerFilter.overLimit => c.overLimit,
      },
    );
    if (search != null && search.isNotEmpty) {
      rows = rows.where((c) => c.name.toLowerCase().contains(search.toLowerCase()));
    }
    final list = rows.toList()
      ..sort(
        (a, b) => switch (sort) {
          CustomerSort.balance => b.balance.compareTo(a.balance),
          CustomerSort.recent => (b.lastPurchaseAt ?? DateTime(2000)).compareTo(a.lastPurchaseAt ?? DateTime(2000)),
          CustomerSort.name => a.name.compareTo(b.name),
        },
      );
    return CustomerList(
      data: list,
      totals: const CustomerTotals(customers: 5, debtors: 3, totalDue: 36000, overLimit: 1),
    );
  }

  @override
  Future<CustomerOverview> customerOverview(String id) async {
    if (id == 'c9') {
      return const CustomerOverview(
        customer: Contact(id: 'c9', name: 'Ousmane Fall', phone: '+221701234567'),
        balance: 0,
      );
    }
    return CustomerOverview(
      customer: Contact(
        id: 'k1',
        name: 'Fatou Ndiaye',
        phone: '+221774120855',
        address: 'Liberté 6, Dakar',
        notes: 'Paie en fin de mois',
        balance: 17500,
        creditLimit: 25000,
        lastRemindedAt: DateTime.now().subtract(const Duration(days: 3)),
      ),
      balance: 17500,
      availableCredit: 7500,
      oldestUnpaidAt: DateTime.now().subtract(const Duration(days: 14)),
      stats: CustomerStats(
        salesCount: 6,
        totalSpent: 64500,
        totalPaid: 47000,
        averageBasket: 10750,
        firstPurchaseAt: DateTime(2026, 6, 3),
        lastPurchaseAt: DateTime.now().subtract(const Duration(days: 2)),
        openInvoices: 1,
        openInvoicesDue: 30000,
      ),
      topProducts: const [
        CustomerTopProduct(name: 'Beurre de karité 250 g', quantity: 8, total: 28000),
        CustomerTopProduct(name: 'Savon noir', quantity: 12, total: 18000),
      ],
      recentSales: [
        CustomerSale(id: 's1', number: 'VEN-2026-0412', total: 9000, due: 4000, status: 'completed', soldAt: DateTime(2026, 11, 14, 10, 32), itemCount: 3),
        CustomerSale(id: 's2', number: 'VEN-2026-0388', total: 8500, due: 8500, status: 'completed', soldAt: DateTime(2026, 11, 6, 11, 20), itemCount: 2),
      ],
      entries: [
        LedgerEntry(id: 'e1', type: 'debt', amount: 4000, note: 'VEN-2026-0412', at: DateTime(2026, 11, 14, 10, 32), refType: 'sale', balanceAfter: 17500),
        LedgerEntry(id: 'e2', type: 'repayment', amount: -10000, method: 'wave', at: DateTime(2026, 11, 9, 18, 5), balanceAfter: 13500),
        LedgerEntry(id: 'e3', type: 'debt', amount: 8500, note: 'VEN-2026-0388', at: DateTime(2026, 11, 6, 11, 20), refType: 'sale', balanceAfter: 23500),
        LedgerEntry(id: 'e4', type: 'adjustment', amount: 15000, note: 'Cahier papier', at: DateTime(2026, 11, 2, 16, 47), refType: 'opening_debt', balanceAfter: 15000),
      ],
    );
  }

  @override
  Future<Contact> saveCustomer(CustomerDraft draft, {String? id, bool withLimit = true}) async {
    savedCustomers.add((id, draft.toJson(withLimit: withLimit)));
    return Contact(id: id ?? 'new-customer', name: draft.name, phone: draft.phone, creditLimit: draft.creditLimit);
  }

  @override
  Future<void> deleteCustomer(String id) async => deletedCustomers.add(id);

  @override
  Future<int> adjustBalance(String customerId, {required int amount, required String reason}) async {
    adjustments.add((customerId, amount, reason));
    return 17500 + amount;
  }

  @override
  Future<void> markReminded(String customerId, String channel) async => reminders.add((customerId, channel));

  /// Vrai : simule une coupure réseau (toutes les ventes échouent sans réponse).
  bool offline = false;

  /// Identifiants de vente qui seront refusés par le « serveur ».
  final rejectIds = <String>{};

  @override
  Future<SaleResult> postSale(Map<String, dynamic> body, {String? businessId}) async {
    if (offline) throw const ApiException(ApiException.network, 'Connexion impossible au serveur.');
    final id = body['id'] as String;
    if (rejectIds.contains(id)) throw const ApiException('NOT_FOUND', 'Produit introuvable (ligne 1)', status: 404);
    final existing = sales.indexWhere((x) => x['id'] == id);
    if (existing < 0) {
      sales.add(body);
      saleCounter++;
    }
    final items = (body['items'] as List).cast<Map>();
    final total = items.fold<int>(
      0,
      (s, i) => s + (demoProducts.firstWhere((p) => p.id == i['productId']).price * (i['quantity'] as num)).round(),
    );
    final paid = (body['payments'] as List).cast<Map>().fold<int>(0, (s, p) => s + (p['amount'] as num).toInt());
    return SaleResult(id: id, number: 'VEN-2026-000$saleCounter', total: total, paid: paid, due: total - paid);
  }

  // ---------- Équipe ----------
  final team = <Member>[
    const Member(
      id: 'm1',
      userId: 'u1',
      phone: '+221771234567',
      fullName: 'Awa Diallo',
      role: 'owner',
      roleName: 'Propriétaire',
      status: 'active',
    ),
    const Member(
      id: 'm2',
      userId: 'u2',
      phone: '+221781112233',
      fullName: 'Moussa Fall',
      role: 'cashier',
      roleName: 'Vendeur / caissier',
      status: 'active',
    ),
    const Member(
      id: 'm3',
      userId: 'u4',
      phone: '+221765550000',
      fullName: 'Fatou Sarr',
      role: 'manager',
      roleName: 'Gérant',
      status: 'invited',
    ),
  ];
  final invites = <({String phone, String? fullName, TeamRole role})>[];

  @override
  Future<List<Member>> members() async => List.of(team);

  @override
  Future<void> inviteMember({required String phone, String? fullName, required TeamRole role}) async {
    if (team.any((m) => m.phone == phone)) {
      throw const ApiException('CONFLICT', 'Cette personne est déjà membre de l’entreprise', status: 409);
    }
    invites.add((phone: phone, fullName: fullName, role: role));
    team.add(
      Member(
        id: 'm${team.length + 1}',
        userId: 'new',
        phone: phone,
        fullName: fullName,
        role: role.api,
        roleName: role.label,
        status: 'invited',
      ),
    );
  }

  @override
  Future<void> updateMember(String id, {TeamRole? role, String? status}) async {
    final i = team.indexWhere((m) => m.id == id);
    final m = team[i];
    team[i] = Member(
      id: m.id,
      userId: m.userId,
      phone: m.phone,
      fullName: m.fullName,
      role: role?.api ?? m.role,
      roleName: role?.label ?? m.roleName,
      status: status ?? m.status,
    );
  }

  @override
  Future<void> removeMember(String id) async => team.removeWhere((m) => m.id == id);

  @override
  Future<MyDay> myDay() async => const MyDay(salesCount: 3, revenue: 14500, collected: 14500);

  // ---------- Rapports ----------
  final reportRequests = <(DateTime, DateTime)>[];

  @override
  Future<ReportOverview> report(DateTime from, DateTime to) async {
    reportRequests.add((from, to));
    final days = to.difference(from).inDays + 1;
    String d(DateTime x) => x.toIso8601String().substring(0, 10);
    return ReportOverview.fromJson({
      'period': {'from': d(from), 'to': d(to), 'days': days, 'granularity': days > 62 ? 'month' : 'day'},
      'previous': {'revenue': 412000},
      'salesCount': 64,
      'voidedCount': 2,
      'revenue': 486500,
      'cost': 301000,
      'grossProfit': 185500,
      'expenses': 42000,
      'netProfit': 143500,
      'collected': 452500,
      'onCredit': 34000,
      'discounts': 6500,
      'averageBasket': 7602,
      'marginRate': 38.1,
      'change': {'revenue': 18.1, 'netProfit': 12.4, 'salesCount': -3.0},
      'series': [
        for (var i = 0; i < (days > 62 ? 12 : days); i++)
          {
            'period': days > 62
                ? d(DateTime(from.year, from.month + i)).substring(0, 7)
                : d(from.add(Duration(days: i))),
            'salesCount': 6 + (i * 7) % 9,
            'revenue': 42000 + ((i * 37) % 11) * 9000,
            'grossProfit': 15000 + ((i * 37) % 11) * 3200,
          },
      ],
      'byMethod': [
        {'method': 'cash', 'amount': 251000, 'salesCount': 38},
        {'method': 'wave', 'amount': 146500, 'salesCount': 17},
        {'method': 'orange_money', 'amount': 55000, 'salesCount': 7},
      ],
      'topProducts': [
        {'name': 'Beurre de karité 250 g', 'quantity': 38, 'revenue': 133000, 'grossProfit': 57000},
        {'name': 'Parfum Thiouraye', 'quantity': 19, 'revenue': 95000, 'grossProfit': 38000},
        {'name': 'Huile de coco 500 ml', 'quantity': 21, 'revenue': 84000, 'grossProfit': 29400},
        {'name': 'Savon noir', 'quantity': 44, 'revenue': 66000, 'grossProfit': 30800},
      ],
      'bySeller': [
        {'userId': 'u1', 'name': 'Awa Diallo', 'salesCount': 39, 'revenue': 301500},
        {'userId': 'u2', 'name': 'Moussa Fall', 'salesCount': 25, 'revenue': 185000},
      ],
      'expensesByCategory': [
        {'category': 'loyer', 'amount': 25000, 'count': 1},
        {'category': 'transport', 'amount': 12000, 'count': 6},
        {'category': 'électricité', 'amount': 5000, 'count': 1},
      ],
      'invoices': {'invoiced': 185000, 'count': 3, 'received': 80000},
    });
  }

  // ---------- Factures et devis ----------
  final docs = <String, DocDetail>{};
  final docBodies = <String, Map<String, dynamic>>{};
  final docActions = <String>[];
  int _quoteN = 0;
  int _invoiceN = 0;

  DocDetail _build(
    String id,
    DocKind kind,
    Map<String, dynamic> body, {
    String? status,
    int paid = 0,
    List<DocPayment> payments = const [],
    ({String id, String number})? related,
    String? number,
  }) {
    final lines = [
      for (final l in (body['lines'] as List).cast<Map<String, dynamic>>())
        DocLine(
          productId: l['productId'] as String?,
          name: l['name'] as String,
          description: l['description'] as String?,
          quantity: (l['quantity'] as num).toDouble(),
          unitPrice: (l['unitPrice'] as num).toInt(),
          total: ((l['quantity'] as num) * (l['unitPrice'] as num)).round(),
        ),
    ];
    final subtotal = lines.fold(0, (s, l) => s + l.total);
    final discount = (body['discount'] as num?)?.toInt() ?? 0;
    final total = subtotal - discount;
    final year = DateTime.now().year;
    return DocDetail(
      id: id,
      kind: kind,
      number: number ?? (kind == DocKind.quote ? 'DEV-$year-000${++_quoteN}' : 'FAC-$year-000${++_invoiceN}'),
      status:
          status ?? (kind == DocKind.quote ? 'pending' : (paid >= total ? 'paid' : (paid > 0 ? 'partial' : 'unpaid'))),
      customer: const Contact(id: 'c1', name: 'Hôtel Teranga', phone: '+221338200000'),
      issueDate: DateTime(2026, 11, 16),
      dueDate: body['dueDate'] == null ? null : DateTime.parse(body['dueDate'] as String),
      subtotal: subtotal,
      discount: discount,
      total: total,
      paid: paid,
      due: total - paid,
      note: body['note'] as String?,
      lines: lines,
      payments: payments,
      related: related,
    );
  }

  @override
  Future<List<Contact>> customers({String? search}) async => const [
    Contact(id: 'c1', name: 'Hôtel Teranga', phone: '+221338200000'),
    Contact(id: 'k1', name: 'Fatou Ndiaye', phone: '+221774120855', balance: 17500, creditLimit: 25000),
  ];

  @override
  Future<InvoicingSummary> invoicingSummary() async => const InvoicingSummary(
    receivable: 95000,
    openInvoices: 2,
    overdue: 30000,
    overdueInvoices: 1,
    openQuotesTotal: 75000,
    openQuotes: 1,
    invoicedThisMonth: 185000,
  );

  @override
  Future<List<DocSummary>> documents({
    required DocKind kind,
    String? status,
    bool overdue = false,
    String? search,
  }) async => [
    for (final d in docs.values.where((d) => d.kind == kind))
      DocSummary(
        id: d.id,
        kind: d.kind,
        number: d.number,
        status: d.status,
        customerName: d.customer.name,
        issueDate: d.issueDate,
        dueDate: d.dueDate,
        total: d.total,
        due: d.due,
        overdue: d.overdue,
      ),
  ];

  @override
  Future<DocDetail> document(String id) async => docs[id]!;

  @override
  Future<DocDetail> createDocument({
    required String id,
    required DocKind kind,
    required Map<String, dynamic> body,
  }) async {
    docBodies[id] = body;
    return docs[id] ??= _build(id, kind, body);
  }

  @override
  Future<DocDetail> updateQuote(String id, Map<String, dynamic> body) async {
    docBodies[id] = body;
    return docs[id] = _build(id, DocKind.quote, body, number: docs[id]!.number);
  }

  @override
  Future<DocDetail> quoteAction(String id, String action) async {
    docActions.add('$action $id');
    final d = docs[id]!;
    final status = {'accept': 'accepted', 'decline': 'declined', 'reopen': 'pending'}[action]!;
    return docs[id] = _build(id, DocKind.quote, docBodies[id]!, status: status, number: d.number);
  }

  @override
  Future<DocDetail> convertQuote(String id, {DateTime? dueDate}) async {
    final q = docs[id]!;
    final invId = 'inv-$id';
    final inv = docs[invId] ??= _build(invId, DocKind.invoice, docBodies[id]!, related: (id: q.id, number: q.number));
    docBodies[invId] = docBodies[id]!;
    docs[id] = _build(
      id,
      DocKind.quote,
      docBodies[id]!,
      status: 'invoiced',
      number: q.number,
      related: (id: inv.id, number: inv.number),
    );
    return inv;
  }

  @override
  Future<DocDetail> payInvoice(
    String id, {
    required String paymentId,
    required int amount,
    required PayMethod method,
    String? reference,
  }) async {
    final d = docs[id]!;
    final paid = d.paid + amount;
    return docs[id] = _build(
      id,
      DocKind.invoice,
      docBodies[id]!,
      paid: paid,
      number: d.number,
      related: d.related,
      payments: [
        ...d.payments,
        DocPayment(method: method, amount: amount, reference: reference, paidAt: DateTime(2026, 11, 16)),
      ],
    );
  }

  @override
  Future<DocDetail> cancelInvoice(String id, String reason) async {
    final d = docs[id]!;
    return docs[id] = _build(id, DocKind.invoice, docBodies[id]!, status: 'cancelled', number: d.number);
  }

  // ---------- Profil ----------
  Me profile = demoMe;
  int avatarUploads = 0;
  bool loggedOutEverywhere = false;

  @override
  Future<Me> me() async => profile;

  @override
  Future<void> updateProfile({required String fullName, String? email}) async => profile = Me(
    id: profile.id,
    phone: profile.phone,
    fullName: fullName,
    email: (email ?? '').isEmpty ? null : email,
    avatarFileId: profile.avatarFileId,
    businesses: profile.businesses,
  );

  @override
  Future<void> uploadAvatar(List<int> bytes, {String filename = 'photo.jpg'}) async {
    avatarUploads++;
    profile = Me(
      id: profile.id,
      phone: profile.phone,
      fullName: profile.fullName,
      email: profile.email,
      avatarFileId: 'avatar-$avatarUploads',
      businesses: profile.businesses,
    );
  }

  @override
  Future<void> deleteAvatar() async => profile = Me(
    id: profile.id,
    phone: profile.phone,
    fullName: profile.fullName,
    email: profile.email,
    businesses: profile.businesses,
  );

  @override
  Future<void> logoutAll() async => loggedOutEverywhere = true;

  @override
  Future<SaleDetail> sale(String id) async => id == 'voided' ? demoVoidedSale : demoSale;

  @override
  Future<List<SaleSummary>> salesOfDay([DateTime? day, bool mine = false]) async => [
    SaleSummary(
      id: 's2',
      number: 'VEN-2026-0042',
      status: 'completed',
      customerName: 'Aminata Ba',
      total: 9000,
      due: 4000,
      soldAt: DateTime(2026, 11, 16, 11, 20),
    ),
    SaleSummary(
      id: 'voided',
      number: 'VEN-2026-0041',
      status: 'voided',
      total: 3500,
      due: 0,
      soldAt: DateTime(2026, 11, 16, 10, 5),
    ),
    SaleSummary(
      id: 's1',
      number: 'VEN-2026-0040',
      status: 'completed',
      total: 11600,
      due: 0,
      soldAt: DateTime(2026, 11, 16, 9, 42),
    ),
  ];
}

final demoSale = SaleDetail(
  id: 's2',
  number: 'VEN-2026-0042',
  status: 'completed',
  soldAt: DateTime(2026, 11, 16, 11, 20),
  subtotal: 9500,
  discount: 500,
  total: 9000,
  paid: 5000,
  due: 4000,
  lines: const [
    ReceiptLine(name: 'Beurre de karité 250 g', quantity: 2, unitPrice: 3500, total: 7000),
    ReceiptLine(name: 'Savon noir', quantity: 1, unitPrice: 2500, total: 2500),
  ],
  payments: const [(method: PayMethod.wave, amount: 5000)],
  customer: const Contact(id: 'c1', name: 'Aminata Ba', phone: '+221765551234'),
  cashierName: 'Awa Diallo',
);

final demoVoidedSale = SaleDetail(
  id: 'voided',
  number: 'VEN-2026-0041',
  status: 'voided',
  soldAt: DateTime(2026, 11, 16, 10, 5),
  subtotal: 3500,
  discount: 0,
  total: 3500,
  paid: 3500,
  due: 0,
  lines: const [ReceiptLine(name: 'Savon noir', quantity: 1, unitPrice: 3500, total: 3500)],
  payments: const [(method: PayMethod.cash, amount: 3500)],
);

class FakeAuth extends AuthController {
  @override
  Future<AuthState> build() async => const AuthState(me: demoMe, businessId: 'b1');
}

/// Lance l'app complète (vrai routeur, vrais écrans) sur des données factices.
Future<(ProviderContainer, FakeRepo)> pumpSama(
  WidgetTester tester, {
  String location = '/',
  List<Override> overrides = const [],
  FakeRepo? repo,
}) async {
  Motion.enabled = false; // animations d'ambiance infinies : incompatibles avec pumpAndSettle
  await initializeDateFormatting('fr');
  repo ??= FakeRepo();
  final container = ProviderContainer(
    overrides: [
      sessionStoreProvider.overrideWithValue(MemorySessionStore()),
      repoProvider.overrideWithValue(repo),
      authProvider.overrideWith(FakeAuth.new),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const SamaApp(googleFonts: false)));
  await tester.pumpAndSettle();
  if (location != '/') {
    container.read(routerProvider).go(location);
    await tester.pumpAndSettle();
  }
  return (container, repo);
}

GoRouter routerOf(ProviderContainer c) => c.read(routerProvider);

/// Polices réelles (Roboto + icônes Material) pour des captures lisibles.
Future<void> loadTestFonts() async {
  Motion.enabled = false;
  final dir = '${Platform.environment['FLUTTER_ROOT'] ?? '/opt/flutter'}/bin/cache/artifacts/material_fonts';
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final f in files) {
      final bytes = File('$dir/$f').readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await loader.load();
  }

  await load('Roboto', ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf', 'Roboto-Black.ttf']);
  await load('MaterialIcons', ['MaterialIcons-Regular.otf']);
}

/// Écran de téléphone 390 × 844 (densité 2).
void phoneSize(WidgetTester tester) {
  tester.view.physicalSize = const Size(780, 1688);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
}
