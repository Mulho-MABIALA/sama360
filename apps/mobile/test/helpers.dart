import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:sama360/core/biometrics.dart';
import 'package:sama360/core/pin_lock.dart';
import 'package:sama360/core/api/api_client.dart';
import 'package:sama360/core/api/session_store.dart';
import 'package:sama360/core/glass.dart';
import 'package:sama360/core/models.dart';
import 'package:sama360/core/offline/kv_store.dart';
import 'package:sama360/core/offline/pending_sales.dart' show keyValueStoreProvider;
import 'package:sama360/core/theme.dart';
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

/// Image PNG de 1 × 1 pixel (aperçus de photos dans les tests).
final tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
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

  /// Couleur de la boutique (null : vert Sama360).
  String? brandColor;
  final brandColorUpdates = <String?>[];

  @override
  Future<void> updateBrandColor(String? hex) async {
    brandColorUpdates.add(hex);
    brandColor = hex;
  }

  bool requireOpenCash = false;

  @override
  Future<void> updateRequireOpenCash(bool value) async => requireOpenCash = value;

  @override
  Future<CurrentBusiness> currentBusiness() async => logoFileId == null && brandColor == null && !requireOpenCash
      ? demoBusiness
      : CurrentBusiness(
          id: demoBusiness.id,
          name: demoBusiness.name,
          slug: demoBusiness.slug,
          city: demoBusiness.city,
          phone: demoBusiness.phone,
          address: demoBusiness.address,
          logoFileId: logoFileId,
          brandColor: brandColor,
          requireOpenCash: requireOpenCash,
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
  Future<List<Product>> products({String? search, String? categoryId}) async => [...demoProducts, ...extraProducts];

  /// Produits ajoutés par un test (ex. prestations pour la réservation).
  List<Product> extraProducts = const [];
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
    last7Days: [52000, 61000, 48500, 73000, 69000, 91000, 86500],
    previous7DaysRevenue: 427000,
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
  final savedTypes = <String>[];
  final deletedCustomers = <String>[];
  final adjustments = <(String, int, String)>[];
  final customerReminders = <(String, String)>[];
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
        CustomerSale(
          id: 's1',
          number: 'VEN-2026-0412',
          total: 9000,
          due: 4000,
          status: 'completed',
          soldAt: DateTime(2026, 11, 14, 10, 32),
          itemCount: 3,
        ),
        CustomerSale(
          id: 's2',
          number: 'VEN-2026-0388',
          total: 8500,
          due: 8500,
          status: 'completed',
          soldAt: DateTime(2026, 11, 6, 11, 20),
          itemCount: 2,
        ),
      ],
      entries: [
        LedgerEntry(
          id: 'e1',
          type: 'debt',
          amount: 4000,
          note: 'VEN-2026-0412',
          at: DateTime(2026, 11, 14, 10, 32),
          refType: 'sale',
          balanceAfter: 17500,
        ),
        LedgerEntry(
          id: 'e2',
          type: 'repayment',
          amount: -10000,
          method: 'wave',
          at: DateTime(2026, 11, 9, 18, 5),
          balanceAfter: 13500,
        ),
        LedgerEntry(
          id: 'e3',
          type: 'debt',
          amount: 8500,
          note: 'VEN-2026-0388',
          at: DateTime(2026, 11, 6, 11, 20),
          refType: 'sale',
          balanceAfter: 23500,
        ),
        LedgerEntry(
          id: 'e4',
          type: 'adjustment',
          amount: 15000,
          note: 'Cahier papier',
          at: DateTime(2026, 11, 2, 16, 47),
          refType: 'opening_debt',
          balanceAfter: 15000,
        ),
      ],
    );
  }

  @override
  Future<Contact> saveCustomer(
    CustomerDraft draft, {
    String? id,
    bool withLimit = true,
    String type = 'customer',
  }) async {
    savedCustomers.add((id, draft.toJson(withLimit: withLimit)));
    savedTypes.add(type);
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
  Future<void> markReminded(String customerId, String channel) async => customerReminders.add((customerId, channel));

  // ---------- Achats et fournisseurs ----------
  final purchaseBodies = <Map<String, dynamic>>[];
  final purchaseUpdates = <(String, Map<String, dynamic>)>[];
  final confirmed = <String>[];
  final cancelledPurchases = <String>[];
  final receptions =
      <(String, List<({String lineId, double quantity, int unitCost})>, String?, ({int amount, PayMethod method})?)>[];
  final purchasePayments = <(String, int, PayMethod)>[];
  final supplierPayments = <(String, int, PayMethod)>[];
  final purchaseQueries = <(PurchaseFilter, String?)>[];

  static final demoPurchases = [
    PurchaseSummary(
      id: 'po1',
      number: 'BC-2026-0007',
      status: PurchaseStatus.ordered,
      supplierId: 's1',
      supplierName: 'Grossiste Sandaga',
      orderDate: DateTime(2026, 11, 10),
      expectedDate: DateTime(2026, 11, 13),
      total: 88000,
      lineCount: 2,
    ),
    PurchaseSummary(
      id: 'po2',
      number: 'BC-2026-0005',
      status: PurchaseStatus.partial,
      supplierId: 's2',
      supplierName: 'Cosmétiques Dakar SARL',
      orderDate: DateTime(2026, 11, 6),
      total: 120000,
      receivedTotal: 60000,
      paid: 40000,
      due: 20000,
      lineCount: 3,
    ),
    PurchaseSummary(
      id: 'po3',
      number: 'BC-2026-0003',
      status: PurchaseStatus.received,
      supplierId: 's1',
      supplierName: 'Grossiste Sandaga',
      orderDate: DateTime(2026, 11, 2),
      total: 22500,
      receivedTotal: 22500,
      paid: 0,
      due: 22500,
      lineCount: 1,
    ),
    PurchaseSummary(
      id: 'po4',
      number: 'BC-2026-0008',
      status: PurchaseStatus.draft,
      supplierId: 's2',
      supplierName: 'Cosmétiques Dakar SARL',
      orderDate: DateTime(2026, 11, 15),
      total: 26000,
      lineCount: 1,
    ),
  ];

  @override
  Future<PurchaseList> purchases({PurchaseFilter filter = PurchaseFilter.all, String? supplierId}) async {
    purchaseQueries.add((filter, supplierId));
    final rows = demoPurchases.where(
      (p) => switch (filter) {
        PurchaseFilter.open => p.status.open,
        PurchaseFilter.unpaid => p.due > 0,
        PurchaseFilter.received => p.status == PurchaseStatus.received,
        PurchaseFilter.all => true,
      },
    );
    return PurchaseList(
      data: rows.toList(),
      totals: const PurchaseTotals(openOrders: 3, toReceive: 148000, totalDue: 42500, suppliersOwed: 2),
    );
  }

  PurchaseDetail _detail(String id) {
    final summary = demoPurchases.firstWhere((p) => p.id == id);
    final lines = switch (id) {
      'po2' => const [
        PurchaseLine(
          id: 'l21',
          productId: 'p4',
          name: 'Crème éclaircissante bio',
          quantity: 20,
          receivedQty: 10,
          unitCost: 4000,
          total: 80000,
        ),
        PurchaseLine(
          id: 'l22',
          productId: 'p5',
          name: 'Shampoing aloe vera',
          quantity: 20,
          receivedQty: 10,
          unitCost: 2000,
          total: 40000,
        ),
      ],
      'po4' => const [
        PurchaseLine(
          id: 'l41',
          productId: 'p3',
          name: 'Huile de coco 500 ml',
          quantity: 10,
          unitCost: 2600,
          total: 26000,
        ),
      ],
      _ => const [
        PurchaseLine(
          id: 'l11',
          productId: 'p1',
          name: 'Beurre de karité 250 g',
          quantity: 24,
          unitCost: 2000,
          total: 48000,
        ),
        PurchaseLine(id: 'l12', productId: 'p2', name: 'Savon noir', quantity: 50, unitCost: 800, total: 40000),
      ],
    };
    return PurchaseDetail(
      summary: summary,
      supplier: Contact(
        id: summary.supplierId,
        name: summary.supplierName,
        phone: summary.supplierId == 's1' ? '+221773004050' : null,
      ),
      note: id == 'po1' ? 'Livrer à la boutique de Sandaga' : null,
      lines: lines,
      receipts: id == 'po2'
          ? [
              PurchaseReceipt(
                id: 'r1',
                total: 60000,
                note: 'Premier carton',
                receivedAt: DateTime(2026, 11, 8, 9, 30),
                receivedBy: 'Awa Diallo',
              ),
            ]
          : const [],
      payments: id == 'po2'
          ? [PurchasePayment(id: 'pp1', method: PayMethod.wave, amount: 40000, paidAt: DateTime(2026, 11, 8, 10))]
          : const [],
    );
  }

  @override
  Future<PurchaseDetail> purchase(String id) async => _detail(id);

  @override
  Future<PurchaseDetail> createPurchase(Map<String, dynamic> body) async {
    purchaseBodies.add(body);
    return _detail('po1');
  }

  @override
  Future<PurchaseDetail> updatePurchase(String id, Map<String, dynamic> body) async {
    purchaseUpdates.add((id, body));
    return _detail(id);
  }

  @override
  Future<PurchaseDetail> confirmPurchase(String id) async {
    confirmed.add(id);
    return _detail(id);
  }

  @override
  Future<PurchaseDetail> cancelPurchase(String id) async {
    cancelledPurchases.add(id);
    return _detail(id);
  }

  @override
  Future<PurchaseDetail> receivePurchase(
    String id, {
    List<({String lineId, double quantity, int unitCost})> lines = const [],
    String? note,
    ({int amount, PayMethod method})? payment,
  }) async {
    receptions.add((id, lines, note, payment));
    return _detail(id);
  }

  @override
  Future<PurchaseDetail> payPurchase(
    String id, {
    required int amount,
    required PayMethod method,
    String? paymentId,
  }) async {
    purchasePayments.add((id, amount, method));
    return _detail(id);
  }

  @override
  Future<List<SupplierRow>> suppliers({String? search}) async => [
    SupplierRow(
      id: 's1',
      name: 'Grossiste Sandaga',
      phone: '+221773004050',
      ordersCount: 6,
      purchased: 410000,
      due: 22500,
      openOrders: 1,
      lastOrderAt: DateTime.now().subtract(const Duration(days: 6)),
    ),
    SupplierRow(id: 's2', name: 'Cosmétiques Dakar SARL', ordersCount: 3, purchased: 240000, due: 20000, openOrders: 2),
    const SupplierRow(id: 's3', name: 'Imprimerie du Port', phone: '+221338210000'),
  ].where((r) => search == null || search.isEmpty || r.name.toLowerCase().contains(search.toLowerCase())).toList();

  @override
  Future<SupplierOverview> supplierOverview(String id) async => SupplierOverview(
    supplier: const Contact(
      id: 's1',
      name: 'Grossiste Sandaga',
      phone: '+221773004050',
      address: 'Avenue Lamine Guèye',
      notes: 'Livre le mardi et le vendredi',
    ),
    due: 22500,
    ordersCount: 6,
    purchased: 410000,
    paid: 387500,
    openOrders: 1,
    lastOrderAt: DateTime.now().subtract(const Duration(days: 6)),
    orders: [demoPurchases[0], demoPurchases[2]],
    payments: [
      PurchasePayment(
        id: 'sp1',
        method: PayMethod.cash,
        amount: 50000,
        paidAt: DateTime(2026, 11, 1, 17),
        number: 'BC-2026-0001',
      ),
    ],
    products: const [
      SupplierProduct(productId: 'p1', name: 'Beurre de karité 250 g', quantity: 96, lastCost: 2000),
      SupplierProduct(productId: 'p2', name: 'Savon noir', quantity: 200, lastCost: 800),
    ],
  );

  @override
  Future<int> paySupplier(String id, {required int amount, required PayMethod method}) async {
    supplierPayments.add((id, amount, method));
    return 22500 - amount;
  }

  // ---------- Boutique en ligne ----------
  bool shopEnabled = true;
  int publishedCount = 4;
  final shopSettingsSaved = <ShopSettings>[];
  final publishCalls = <(List<String>?, bool)>[];
  final shopStatusCalls = <(String, ShopOrderStatus, String?, ({int amount, PayMethod method})?)>[];
  final shopQueries = <ShopOrderFilter>[];

  static final demoShopOrders = [
    ShopOrder(
      id: 'so1',
      number: 'CMD-2026-0012',
      status: ShopOrderStatus.newOrder,
      customerName: 'Ndèye Sarr',
      customerPhone: '+221765554433',
      delivery: true,
      total: 23000,
      subtotal: 22000,
      deliveryFee: 1000,
      lineCount: 2,
      createdAt: DateTime(2026, 11, 16, 9, 42),
      contactId: 'k1',
      address: 'Ouakam, près de la mosquée',
      note: 'Appeler avant de passer',
      lines: const [
        ShopOrderLine(
          id: 'sl1',
          productId: 'p1',
          name: 'Beurre de karité 250 g',
          quantity: 2,
          unitPrice: 3500,
          total: 7000,
        ),
        ShopOrderLine(id: 'sl2', productId: 'p6', name: 'Parfum Thiouraye', quantity: 3, unitPrice: 5000, total: 15000),
      ],
    ),
    ShopOrder(
      id: 'so2',
      number: 'CMD-2026-0011',
      status: ShopOrderStatus.confirmed,
      customerName: 'Aïssatou Ba',
      customerPhone: '+221778889900',
      delivery: false,
      total: 7000,
      subtotal: 7000,
      lineCount: 1,
      createdAt: DateTime(2026, 11, 15, 18, 5),
      lines: const [
        ShopOrderLine(
          id: 'sl3',
          productId: 'p1',
          name: 'Beurre de karité 250 g',
          quantity: 2,
          unitPrice: 3500,
          total: 7000,
        ),
      ],
    ),
    ShopOrder(
      id: 'so3',
      number: 'CMD-2026-0010',
      status: ShopOrderStatus.completed,
      customerName: 'Fatou Ndiaye',
      customerPhone: '+221774120855',
      delivery: true,
      total: 9000,
      subtotal: 8000,
      deliveryFee: 1000,
      lineCount: 1,
      createdAt: DateTime(2026, 11, 14, 11),
      saleId: 's1',
      lines: const [
        ShopOrderLine(
          id: 'sl4',
          productId: 'p3',
          name: 'Huile de coco 500 ml',
          quantity: 2,
          unitPrice: 4000,
          total: 8000,
        ),
      ],
    ),
  ];

  @override
  Future<ShopOverview> shop() async => ShopOverview(
    slug: 'awa-beaute',
    path: '/s/awa-beaute',
    settings: ShopSettings(
      enabled: shopEnabled,
      title: shopEnabled ? 'Awa Beauté en ligne' : null,
      whatsapp: shopEnabled ? '+221771112233' : null,
      deliveryFee: 1000,
      deliveryZone: 'Dakar',
    ),
    newOrders: 1,
    openOrders: 1,
    monthOrders: 7,
    monthRevenue: 184500,
    publishedProducts: shopEnabled ? publishedCount : 0,
    totalProducts: 6,
  );

  @override
  Future<ShopSettings> saveShopSettings(ShopSettings s) async {
    shopSettingsSaved.add(s);
    return s;
  }

  @override
  Future<int> publishProducts({List<String>? productIds, required bool published}) async {
    publishCalls.add((productIds, published));
    return productIds?.length ?? 6;
  }

  @override
  Future<List<ShopOrder>> shopOrders({ShopOrderFilter filter = ShopOrderFilter.open}) async {
    shopQueries.add(filter);
    return demoShopOrders
        .where(
          (o) => switch (filter) {
            ShopOrderFilter.open => !o.status.done,
            ShopOrderFilter.newOnly => o.status == ShopOrderStatus.newOrder,
            ShopOrderFilter.done => o.status.done,
            ShopOrderFilter.all => true,
          },
        )
        .toList();
  }

  @override
  Future<ShopOrder> shopOrder(String id) async => demoShopOrders.firstWhere((o) => o.id == id);

  @override
  Future<ShopOrder> setShopOrderStatus(
    String id,
    ShopOrderStatus status, {
    String? reason,
    ({int amount, PayMethod method})? payment,
  }) async {
    shopStatusCalls.add((id, status, reason, payment));
    return demoShopOrders.firstWhere((o) => o.id == id);
  }

  // ---------- Caisse ----------
  bool cashOpen = true;
  final cashOpenings = <(int, String?)>[];
  final cashMovements = <(bool, int, String)>[];
  final cashClosings = <(String?, Map<PayMethod, int>, String?)>[];

  static final demoCashSession = CashSession(
    id: 'cs1',
    number: 'Z-2026-0007',
    open: true,
    userId: 'u1',
    userName: 'Awa Diallo',
    openingFloat: 10000,
    openedAt: DateTime(2026, 11, 16, 8, 12),
    report: const CashReport(
      salesCount: 14,
      salesTotal: 86500,
      creditTotal: 7500,
      methods: [
        CashMethodLine(
          method: PayMethod.cash,
          opening: 10000,
          sales: 52000,
          repayments: 5000,
          expenses: 3500,
          movementsOut: 20000,
          expected: 43500,
        ),
        CashMethodLine(method: PayMethod.wave, sales: 21000, expected: 21000),
        CashMethodLine(method: PayMethod.orangeMoney, sales: 6000, expected: 6000),
      ],
      expectedTotal: 70500,
    ),
    movements: [
      CashMovement(
        id: 'm1',
        isIn: false,
        amount: 20000,
        reason: 'Dépôt à la banque',
        createdAt: DateTime(2026, 11, 16, 12, 40),
      ),
    ],
  );

  static final demoClosedSession = CashSession(
    id: 'cs0',
    number: 'Z-2026-0006',
    open: false,
    userId: 'u2',
    userName: 'Moussa Sow',
    openingFloat: 5000,
    openedAt: DateTime(2026, 11, 15, 8, 30),
    closedAt: DateTime(2026, 11, 15, 19, 5),
    closedByName: 'Moussa Sow',
    closingNote: 'Billet de 500 F déchiré',
    report: const CashReport(
      salesCount: 9,
      salesTotal: 41000,
      methods: [
        CashMethodLine(method: PayMethod.cash, opening: 5000, sales: 29000, expected: 34000),
        CashMethodLine(method: PayMethod.wave, sales: 12000, expected: 12000),
      ],
      expectedTotal: 46000,
    ),
    difference: -500,
    lines: const [
      CashCountLine(method: PayMethod.cash, expected: 34000, counted: 33500, difference: -500),
      CashCountLine(method: PayMethod.wave, expected: 12000, counted: 12000, difference: 0),
    ],
  );

  // ---------- Fidélité ----------
  LoyaltySettings loyalty = const LoyaltySettings(enabled: true, earnPer: 1000, rewardPoints: 100, rewardValue: 2000);
  final savedLoyalty = <LoyaltySettings>[];
  final loyaltyGifts = <(String, int, String)>[];

  @override
  Future<LoyaltySettings> loyaltySettings() async => loyalty;

  @override
  Future<LoyaltySettings> saveLoyaltySettings(LoyaltySettings s) async {
    savedLoyalty.add(s);
    return loyalty = s;
  }

  @override
  Future<LoyaltyCard> loyaltyCard(String customerId) async => LoyaltyCard(
    settings: loyalty,
    balance: customerId == 'k1' ? 135 : 20,
    rewardsAvailable: customerId == 'k1' ? 1 : 0,
    pointsToNextReward: customerId == 'k1' ? 65 : 80,
    history: [LoyaltyEntry(id: 'l1', kind: 'earn', points: 31, at: DateTime(2026, 11, 14), note: 'VEN-2026-0412')],
  );

  @override
  Future<int> adjustLoyalty(String customerId, int points, String reason) async {
    loyaltyGifts.add((customerId, points, reason));
    return 135 + points;
  }

  @override
  Future<LoyaltyDashboard> loyaltyDashboard() async => LoyaltyDashboard(
    settings: loyalty,
    members: 24,
    pointsIssued: 3120,
    pointsRedeemed: 900,
    pointsOutstanding: 2220,
    top: [
      TopCustomer(
        customerId: 'k1',
        name: 'Fatou Ndiaye',
        phone: '+221774120855',
        visits: 14,
        spent: 186500,
        lastVisit: DateTime(2026, 11, 14),
        points: 135,
      ),
      TopCustomer(
        customerId: 'k4',
        name: 'Hôtel Teranga',
        visits: 12,
        spent: 318000,
        lastVisit: DateTime(2026, 11, 15),
        points: 318,
      ),
      TopCustomer(
        customerId: 'k2',
        name: 'Aminata Ba',
        visits: 6,
        spent: 41000,
        lastVisit: DateTime(2026, 11, 9),
        points: 41,
      ),
    ],
    birthdays: const [
      UpcomingBirthday(
        customerId: 'k6',
        name: 'Khady Ndiaye',
        phone: '+221776401122',
        day: 17,
        month: 11,
        inDays: 0,
        points: 17,
      ),
      UpcomingBirthday(
        customerId: 'k2',
        name: 'Aminata Ba',
        phone: '+221765551234',
        day: 20,
        month: 11,
        inDays: 3,
        points: 41,
      ),
    ],
  );

  // ---------- Relances ----------
  late ReminderQueue demoReminders = ReminderQueue(
    items: [
      ReminderItem(
        kind: 'credit',
        id: 'k1',
        customerId: 'k1',
        name: 'Ndèye Sarr',
        phone: '+221765554433',
        amount: 11000,
        since: DateTime.now().subtract(const Duration(days: 40)),
        daysLate: 40,
        due: true,
      ),
      ReminderItem(
        kind: 'invoice',
        id: 'inv7',
        customerId: 'k9',
        name: 'Restaurant Le Lagon',
        phone: '+221338210000',
        amount: 120000,
        since: DateTime.now().subtract(const Duration(days: 3)),
        daysLate: 3,
        invoiceNumber: 'FAC-2026-0007',
        due: true,
      ),
      ReminderItem(
        kind: 'credit',
        id: 'k5',
        customerId: 'k5',
        name: 'Pape Diouf',
        amount: 2500,
        since: DateTime.now().subtract(const Duration(days: 12)),
        daysLate: 12,
        due: true,
      ),
      ReminderItem(
        kind: 'credit',
        id: 'k3',
        customerId: 'k3',
        name: 'Binta Sow',
        phone: '+221772223344',
        amount: 14000,
        since: DateTime.now().subtract(const Duration(days: 20)),
        daysLate: 20,
        lastRemindedAt: DateTime.now().subtract(const Duration(days: 2)),
        due: false,
      ),
    ],
    history: [
      ReminderLog(
        id: 'r1',
        channel: 'whatsapp',
        amount: 14000,
        at: DateTime.now().subtract(const Duration(days: 2)),
        customerId: 'k3',
        customerName: 'Binta Sow',
        byName: 'Awa Diallo',
      ),
    ],
    dueCount: 3,
    dueAmount: 133500,
    totalAmount: 147500,
    remindedThisWeek: 1,
  );
  final recordedReminders = <(String, String, String)>[];

  @override
  Future<ReminderQueue> reminders() async => demoReminders;

  @override
  Future<void> recordReminder({required String kind, required String id, required String channel}) async {
    recordedReminders.add((kind, id, channel));
  }

  // ---------- Notifications ----------
  late List<AppNotification> demoNotifications = [
    AppNotification(
      id: 'n1',
      kind: 'shop_order',
      title: 'Nouvelle commande CMD-2026-0012',
      body: 'Ndèye Sarr · 31\u202f000 F · à livrer',
      link: '/cash',
      createdAt: DateTime.now().subtract(const Duration(minutes: 12)),
    ),
    AppNotification(
      id: 'n2',
      kind: 'stock_low',
      title: 'Stock bas : Huile de coco 500 ml',
      body: 'Il en reste 4 (seuil d’alerte : 5).',
      link: '/stock',
      createdAt: DateTime.now().subtract(const Duration(hours: 2)),
    ),
    AppNotification(
      id: 'n3',
      kind: 'invoices_overdue',
      title: '2 factures en retard',
      body: '45\u202f000 F à encaisser. Relancez vos clients.',
      link: '/invoices',
      createdAt: DateTime.now().subtract(const Duration(days: 1, hours: 1)),
    ),
    AppNotification(
      id: 'n4',
      kind: 'cash_open_team',
      title: 'Une caisse est restée ouverte',
      body: 'Ouverte(s) avant aujourd’hui : vérifiez le comptage avant de clôturer.',
      link: '/cash/history',
      createdAt: DateTime.now().subtract(const Duration(days: 3)),
      read: true,
    ),
  ];
  final notificationReads = <String>[];
  int readAllCalls = 0;

  int get _unread => demoNotifications.where((n) => !n.read).length;

  @override
  Future<NotificationsPage> notifications() async => NotificationsPage(items: demoNotifications, unread: _unread);

  @override
  Future<int> unreadNotifications() async => _unread;

  @override
  Future<int> markNotificationRead(String id) async {
    notificationReads.add(id);
    demoNotifications = [for (final n in demoNotifications) n.id == id ? n.copyWith(read: true) : n];
    return _unread;
  }

  @override
  Future<void> markAllNotificationsRead() async {
    readAllCalls++;
    demoNotifications = [for (final n in demoNotifications) n.copyWith(read: true)];
  }

  @override
  Future<CashSession?> cashCurrent() async => cashOpen ? demoCashSession : null;

  @override
  Future<CashSession> openCash({required int openingFloat, String? note}) async {
    cashOpenings.add((openingFloat, note));
    cashOpen = true;
    return demoCashSession;
  }

  @override
  Future<CashSession> cashMovement({required bool isIn, required int amount, required String reason}) async {
    cashMovements.add((isIn, amount, reason));
    return demoCashSession;
  }

  @override
  Future<CashSession> closeCash({String? sessionId, required Map<PayMethod, int> counted, String? note}) async {
    cashClosings.add((sessionId, counted, note));
    cashOpen = false;
    return demoClosedSession;
  }

  @override
  Future<List<CashSessionSummary>> cashSessions() async => [
    CashSessionSummary(
      id: 'cs1',
      number: 'Z-2026-0007',
      open: true,
      userName: 'Awa Diallo',
      openedAt: DateTime(2026, 11, 16, 8, 12),
    ),
    CashSessionSummary(
      id: 'cs0',
      number: 'Z-2026-0006',
      open: false,
      userName: 'Moussa Sow',
      openedAt: DateTime(2026, 11, 15, 8, 30),
      closedAt: DateTime(2026, 11, 15, 19, 5),
      salesTotal: 41000,
      salesCount: 9,
      countedTotal: 45500,
      difference: -500,
    ),
  ];

  @override
  Future<CashSession> cashSession(String id) async => id == 'cs0' ? demoClosedSession : demoCashSession;

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

  // ---------- Réservation ----------
  final appointmentList = <Appointment>[];
  final createdAppointments = <Map<String, Object?>>[];
  final appointmentChanges = <(String, Map<String, Object?>)>[];

  @override
  Future<AppointmentList> appointments(DateTime day) async {
    final items =
        appointmentList
            .where((a) => a.startsAt.year == day.year && a.startsAt.month == day.month && a.startsAt.day == day.day)
            .toList()
          ..sort((a, b) => a.startsAt.compareTo(b.startsAt));
    final counts = <String, int>{};
    for (final a in appointmentList.where((a) => a.status == AppointmentStatus.booked)) {
      final k = a.startsAt.toIso8601String().substring(0, 10);
      counts[k] = (counts[k] ?? 0) + 1;
    }
    return AppointmentList(items: items, bookedByDay: counts);
  }

  @override
  Future<Appointment> createAppointment(AppointmentDraft d) async {
    createdAppointments.add(d.toJson());
    final a = Appointment(
      id: 'a${appointmentList.length + 1}',
      customerId: d.customerId,
      customerName: d.customerName ?? 'Client',
      customerPhone: d.customerPhone,
      serviceId: d.serviceId,
      serviceName: d.serviceName ?? 'Prestation',
      price: d.price ?? 0,
      startsAt: d.startsAt,
      durationMinutes: d.durationMinutes,
      status: AppointmentStatus.booked,
    );
    appointmentList.add(a);
    return a;
  }

  @override
  Future<Appointment> updateAppointment(String id, Map<String, Object?> changes) async {
    appointmentChanges.add((id, changes));
    final i = appointmentList.indexWhere((a) => a.id == id);
    final a = appointmentList[i];
    final updated = Appointment(
      id: a.id,
      customerId: a.customerId,
      customerName: a.customerName,
      customerPhone: a.customerPhone,
      serviceId: a.serviceId,
      serviceName: a.serviceName,
      price: a.price,
      startsAt: changes['startsAt'] == null ? a.startsAt : DateTime.parse(changes['startsAt']! as String).toLocal(),
      durationMinutes: (changes['durationMinutes'] as int?) ?? a.durationMinutes,
      status: changes['status'] == null ? a.status : AppointmentStatus.of(changes['status']! as String),
      note: a.note,
    );
    appointmentList[i] = updated;
    return updated;
  }

  // ---------- Assistant IA ----------
  bool assistantEnabled = true;
  Object? assistantError;
  final assistantQuestions = <List<ChatMessage>>[];

  @override
  Future<AssistantStatus> assistantStatus() async => AssistantStatus(
    enabled: assistantEnabled,
    remaining: 60,
    suggestions: const ["Combien j'ai vendu aujourd'hui ?", 'Qui me doit le plus ?'],
  );

  @override
  Future<AssistantReply> askAssistant(List<ChatMessage> history) async {
    assistantQuestions.add(history);
    if (assistantError != null) throw assistantError!;
    return AssistantReply(
      reply: "Aujourd'hui vous avez fait **12 ventes** pour **86 500 F**.\n- Meilleur produit : Beurre de karité",
      remaining: 60 - assistantQuestions.length,
    );
  }

  // ---------- Documents ----------
  final storedDocs = <BusinessDocument>[
    BusinessDocument(
      id: 'd1',
      title: 'Bail boutique Sandaga',
      category: DocCategory.contract,
      note: 'Loyer payé le 5 du mois',
      expiresOn: DateTime(2026, 11, 27),
      expiresInDays: 10,
      expiry: 'soon',
      mime: 'application/pdf',
      size: 245 * 1024,
      createdAt: DateTime(2026, 9, 1),
      createdByName: 'Awa Diallo',
    ),
    BusinessDocument(
      id: 'd2',
      title: 'NINEA',
      category: DocCategory.admin,
      mime: 'image/png',
      size: 1900 * 1024,
      createdAt: DateTime(2026, 8, 12),
      createdByName: 'Awa Diallo',
    ),
  ];
  final docQueries = <(DocCategory?, String?)>[];
  final uploadedDocs = <Map<String, Object?>>[];
  final deletedDocs = <String>[];

  @override
  Future<DocumentList> storedDocuments({DocCategory? category, String? search}) async {
    docQueries.add((category, search));
    final items = storedDocs
        .where((d) => category == null || d.category == category)
        .where((d) => search == null || search.isEmpty || d.title.toLowerCase().contains(search.toLowerCase()))
        .toList();
    final counts = <DocCategory, int>{};
    for (final d in storedDocs) {
      counts[d.category] = (counts[d.category] ?? 0) + 1;
    }
    return DocumentList(
      items: items,
      counts: counts,
      total: storedDocs.length,
      attention: storedDocs.where((d) => d.expiry != null).length,
    );
  }

  @override
  Future<BusinessDocument> storedDocument(String id) async => storedDocs.firstWhere((d) => d.id == id);

  @override
  Future<List<int>> storedDocumentBytes(String id) async => tinyPng;

  @override
  Future<BusinessDocument> uploadStoredDocument({
    required List<int> bytes,
    required String filename,
    required String title,
    required DocCategory category,
    String? note,
    DateTime? expiresOn,
  }) async {
    uploadedDocs.add({
      'filename': filename,
      'title': title,
      'category': category,
      'note': note,
      'expiresOn': expiresOn,
    });
    final d = BusinessDocument(
      id: 'd${storedDocs.length + 1}',
      title: title,
      category: category,
      note: note,
      expiresOn: expiresOn,
      mime: 'image/png',
      size: bytes.length,
      createdAt: DateTime(2026, 11, 17),
      createdByName: 'Awa Diallo',
    );
    storedDocs.insert(0, d);
    return d;
  }

  @override
  Future<void> deleteStoredDocument(String id) async {
    deletedDocs.add(id);
    storedDocs.removeWhere((d) => d.id == id);
  }

  final insightRequests = <int>[];
  final weeklyRequests = <DateTime?>[];

  @override
  Future<Insights> insights(int days) async {
    insightRequests.add(days);
    final hours = {9: 3, 10: 4, 12: 6, 13: 5, 17: 9, 18: 14, 19: 11, 20: 4};
    return Insights.fromJson({
      'period': {'from': '2026-10-18', 'to': '2026-11-16', 'days': days},
      'dormant': {
        'days': days,
        'count': 3,
        'stockValue': 52000,
        'items': [
          {
            'productId': 'p9',
            'name': 'Parfum Oud 50 ml',
            'onHand': 4,
            'stockValue': 32000,
            'lastSoldAt': '2026-09-02T10:00:00Z',
            'daysSinceSale': 76,
          },
          {
            'productId': 'p8',
            'name': 'Henné naturel',
            'onHand': 10,
            'stockValue': 15000,
            'lastSoldAt': null,
            'daysSinceSale': null,
          },
          {
            'productId': 'p7',
            'name': 'Crème éclaircissante',
            'onHand': 2,
            'stockValue': 5000,
            'lastSoldAt': '2026-10-01T10:00:00Z',
            'daysSinceSale': 47,
          },
        ],
      },
      'byHour': [
        for (var h = 0; h < 24; h++) {'hour': h, 'salesCount': hours[h] ?? 0, 'revenue': (hours[h] ?? 0) * 7500},
      ],
      'byWeekday': [
        for (var d = 1; d <= 7; d++) {'weekday': d, 'salesCount': d * 3, 'revenue': d == 6 ? 120000 : d * 12000},
      ],
      'peak': {'from': 18, 'to': 20, 'share': 45},
      'bestWeekday': 6,
      'margins': {
        'revenue': 318500,
        'profit': 96000,
        'marginRate': 30.1,
        'lowMarginThreshold': 15,
        'unknownCostCount': 2,
        'products': [
          {
            'productId': 'p1',
            'name': 'Beurre de karité 250 g',
            'quantity': 18,
            'revenue': 68400,
            'cost': 36000,
            'profit': 32400,
            'marginRate': 47.4,
            'costKnown': true,
          },
          {
            'productId': 'p3',
            'name': 'Savon noir',
            'quantity': 12,
            'revenue': 18000,
            'cost': 10800,
            'profit': 7200,
            'marginRate': 40,
            'costKnown': true,
          },
          {
            'productId': 'p2',
            'name': 'Huile de coco 500 ml',
            'quantity': 6,
            'revenue': 15000,
            'cost': 13750,
            'profit': 1250,
            'marginRate': 8.3,
            'costKnown': true,
          },
        ],
        'lowMargin': [
          {
            'productId': 'p2',
            'name': 'Huile de coco 500 ml',
            'quantity': 6,
            'revenue': 15000,
            'cost': 13750,
            'profit': 1250,
            'marginRate': 8.3,
            'costKnown': true,
          },
        ],
      },
    });
  }

  @override
  Future<WeeklyReport> weeklyReport([DateTime? week]) async {
    weeklyRequests.add(week);
    final from = week == null ? DateTime(2026, 11, 9) : week.subtract(Duration(days: week.weekday - 1));
    final to = from.add(const Duration(days: 6));
    String d(DateTime x) => x.toIso8601String().substring(0, 10);
    return WeeklyReport.fromJson({
      'from': d(from),
      'to': d(to),
      'salesCount': 42,
      'revenue': 318500,
      'netProfit': 96000,
      'revenueChange': 12.5,
      'peak': {'from': 18, 'to': 20, 'share': 34},
      'bestDay': {'weekday': 6, 'revenue': 82000},
      'dormant': {'count': 3},
      'lowMargin': [
        {'name': 'Huile de coco 500 ml', 'marginRate': 8.3},
      ],
      'text':
          '📊 *Awa Beauté — semaine du ${from.day} nov. au ${to.day} nov.*\n\n💰 Chiffre d\'affaires : *318 500 F* (+12,5 % ↗)\n⏰ Heure de pointe : 18 h – 20 h (34 % des ventes)\n\n_Envoyé depuis Sama360_',
    });
  }

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
  Future<SaleDetail> sale(String id) async => id == 'voided' || voidedSales.containsKey(id) ? demoVoidedSale : demoSale;

  final voidedSales = <String, String>{};

  @override
  Future<void> voidSale(String id, String reason) async => voidedSales[id] = reason;

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

/// Empreinte / Face ID simulés : [kind] null = le téléphone n'en a pas.
class FakeBiometrics implements Biometrics {
  FakeBiometrics({this.kindValue, this.result = true});
  final BiometricKind? kindValue;
  bool result;
  final prompts = <String>[];

  @override
  Future<BiometricKind?> kind() async => kindValue;

  @override
  Future<bool> authenticate(String reason) async {
    prompts.add(reason);
    return result;
  }
}

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
  bool dark = false,
  PinStore? pinStore,
  Biometrics? biometrics,
}) async {
  pinUseIsolate = false; // calcul du code secret sur place (temps simulé des tests)
  Motion.enabled = false; // animations d'ambiance infinies : incompatibles avec pumpAndSettle
  await initializeDateFormatting('fr');
  repo ??= FakeRepo();
  final container = ProviderContainer(
    overrides: [
      sessionStoreProvider.overrideWithValue(MemorySessionStore()),
      // Code secret : coupé par défaut ; activé quand un test fournit [pinStore]
      pinLockEnabledProvider.overrideWithValue(pinStore != null),
      pinStoreProvider.overrideWithValue(pinStore ?? MemoryPinStore()),
      biometricsProvider.overrideWithValue(biometrics ?? FakeBiometrics()),
      repoProvider.overrideWithValue(repo),
      authProvider.overrideWith(FakeAuth.new),
      if (dark) keyValueStoreProvider.overrideWithValue(MemoryStore()..data['display.settings'] = '{"mode":"dark"}'),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);
  AppColors.palette = SamaPalette.light(); // chaque test repart du mode clair
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
