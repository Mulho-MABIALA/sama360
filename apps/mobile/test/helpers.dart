import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show Scrollable;
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
import 'package:sama360/core/admin_models.dart';
import 'package:sama360/core/models.dart';
import 'package:sama360/core/offline/kv_store.dart';
import 'package:sama360/core/offline/pending_sales.dart' show keyValueStoreProvider;
import 'package:sama360/core/theme.dart';
import 'package:sama360/core/push.dart';
import 'package:sama360/core/providers.dart';
import 'package:sama360/core/repositories.dart';
import 'package:sama360/features/auth/auth_controller.dart';
import 'package:sama360/admin_main.dart';
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
  Future<Product> product(String id) async => [...demoProducts, ...extraProducts].firstWhere((p) => p.id == id);

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

  /// Comptes de paiement mobile (QR à la caisse).
  Map<PayMethod, PayAccount> payAccounts = {};

  /// Variantes envoyées (produit, options, variantes).
  final variantCalls = <(String, List<VariantAxis>, List<VariantDraft>)>[];

  @override
  Future<List<Product>> setVariants(String productId, List<VariantAxis> axes, List<VariantDraft> variants) async {
    variantCalls.add((productId, axes, variants));
    return [
      for (final (i, v) in variants.indexed)
        Product(id: '$productId-v$i', name: 'x', price: v.price ?? 0, cost: 0, parentId: productId, options: v.options),
    ];
  }

  /// Entrées de stock (produit, quantité, coût unitaire).
  final stockAdds = <(String, double, int?)>[];

  @override
  Future<void> addStock(String productId, double quantity, {int? unitCost}) async =>
      stockAdds.add((productId, quantity, unitCost));

  @override
  Future<void> updatePayAccounts(Map<PayMethod, PayAccount> accounts) async => payAccounts = {
    for (final e in accounts.entries)
      if (!e.value.isEmpty) e.key: e.value,
  };

  @override
  Future<void> updateBrandColor(String? hex) async {
    brandColorUpdates.add(hex);
    brandColor = hex;
  }

  /// Premiers pas : masqué par défaut (les autres tests de l'accueil ne bougent pas).
  Onboarding onboardingValue = const Onboarding(focus: 'products', dismissed: true, steps: []);
  final focusChoices = <String>[];
  var onboardingDismissed = 0;

  @override
  Future<Onboarding> onboarding() async => onboardingValue;

  @override
  Future<void> setFocus(String focus) async {
    focusChoices.add(focus);
    onboardingValue = Onboarding(
      focus: focus,
      dismissed: false,
      steps: [
        OnboardingStep(focus == 'services' ? 'add_services' : 'add_products', true),
        const OnboardingStep('first_sale', false),
        const OnboardingStep('logo_phone', false),
      ],
    );
  }

  @override
  Future<void> dismissOnboarding() async {
    onboardingDismissed++;
    onboardingValue = Onboarding(focus: onboardingValue.focus, dismissed: true, steps: onboardingValue.steps);
  }

  String? businessFocus;
  final createdBusinesses = <Map<String, String?>>[];

  @override
  Future<String> createBusiness({
    required String name,
    String? category,
    String? city,
    String? focus,
    String? country,
    String? referralCode,
  }) async {
    createdBusinesses.add({
      'name': name,
      'category': category,
      'city': city,
      'focus': focus,
      'country': country,
      'referralCode': ?referralCode,
    });
    return 'b2';
  }

  bool requireOpenCash = false;
  Country businessCountry = Country.sn;

  @override
  Future<void> updateRequireOpenCash(bool value) async => requireOpenCash = value;

  /// Métier (null = aucun : tous les services) et services choisis
  String? businessCategory;
  List<String>? businessServices;

  @override
  Future<void> updateTrade({String? category, List<String>? services, bool resetServices = false}) async {
    if (category != null) businessCategory = category;
    if (services != null) businessServices = services;
    if (resetServices) businessServices = null;
  }

  @override
  Future<void> updateCountry(String code) async => businessCountry = Country.fromCode(code);

  @override
  Future<CurrentBusiness> currentBusiness() async => CurrentBusiness(
    id: demoBusiness.id,
    name: demoBusiness.name,
    slug: demoBusiness.slug,
    city: demoBusiness.city,
    phone: demoBusiness.phone,
    address: demoBusiness.address,
    logoFileId: logoFileId,
    brandColor: brandColor,
    requireOpenCash: requireOpenCash,
    payAccounts: payAccounts,
    focus: businessFocus,
    category: businessCategory,
    services: businessServices,
    country: businessCountry,
    proUntil: proUntil,
    trial: proTrial,
    role: demoBusiness.role,
    permissions: demoBusiness.permissions,
    modules: demoBusiness.modules,
  );

  // ── Sama360 Pro et parrainage
  /// Pro jusqu'à… (par défaut : actif, pour ne rien verrouiller dans les autres tests).
  DateTime? proUntil = DateTime(2100);
  bool proTrial = false;
  ProStatus? proStatus;
  final proPayments = <Map<String, Object?>>[];
  ReferralInfo referralInfo = const ReferralInfo(code: 'AWA7K2', bonusDays: 30, daysEarned: 0, referrals: []);
  bool platformAdmin = false;
  final adminQueue = <PaymentRequest>[];
  final adminOps = <(String, String, String?)>[];
  final adminBusinessList = <AdminBusiness>[];
  final adminDetails = <String, AdminBusinessDetail>{};
  final adminPaymentList = <AdminPayment>[];
  final adminQueries = <AdminBusinessQuery>[];
  AdminOverview? overview;

  ProStatus get _defaultPro => ProStatus(
    pro: proUntil != null && proUntil!.isAfter(DateTime.now()),
    state: proUntil == null
        ? ProState.free
        : !proUntil!.isAfter(DateTime.now())
        ? ProState.expired
        : proTrial
        ? ProState.trial
        : ProState.active,
    endsAt: proUntil,
    daysLeft: proUntil == null ? 0 : proUntil!.difference(DateTime.now()).inDays.clamp(0, 99999),
    monthly: 5000,
    yearly: 50000,
    payTo: 'Wave au 77 000 00 00 (Zolaa Tech)',
    methods: businessCountry.mobileMoney,
    referralCode: referralInfo.code,
    online: proOnline,
  );

  /// Paiement en ligne (Chariow) proposé
  bool proOnline = false;
  final onlineCheckouts = <Map<String, String>>[];
  final onlineChecks = <String>[];

  /// État renvoyé pour un paiement en ligne suivi
  String onlineStatus = 'pending';

  @override
  Future<OnlinePayment> startProCheckout({required String cycle, required String email}) async {
    onlineCheckouts.add({'cycle': cycle, 'email': email});
    return OnlinePayment(
      id: 'op${onlineCheckouts.length}',
      checkoutUrl: 'https://pay.chariow.test/c/${onlineCheckouts.length}',
    );
  }

  @override
  Future<OnlinePayment> onlinePayment(String id) async {
    onlineChecks.add(id);
    return OnlinePayment(id: id, status: onlineStatus);
  }

  @override
  Future<ProStatus> subscription() async => proStatus ?? _defaultPro;

  @override
  Future<PaymentRequest> requestProPayment({
    required String cycle,
    required PayMethod method,
    required String reference,
    String? payerPhone,
  }) async {
    proPayments.add({'cycle': cycle, 'method': method, 'reference': reference, 'payerPhone': payerPhone});
    final r = PaymentRequest(
      id: 'pay${proPayments.length}',
      cycle: cycle,
      amount: cycle == 'yearly' ? 50000 : 5000,
      method: method,
      reference: reference,
      payerPhone: payerPhone,
      status: 'pending',
      createdAt: DateTime(2026, 11, 18, 10),
    );
    final base = await subscription();
    proStatus = ProStatus(
      pro: base.pro,
      state: base.state,
      endsAt: base.endsAt,
      daysLeft: base.daysLeft,
      monthly: base.monthly,
      yearly: base.yearly,
      payTo: base.payTo,
      methods: base.methods,
      pending: r,
      history: [r],
      referralCode: base.referralCode,
    );
    return r;
  }

  @override
  Future<ReferralInfo> referrals() async => referralInfo;

  @override
  Future<bool> isPlatformAdmin() async => platformAdmin;

  @override
  Future<List<PaymentRequest>> adminPaymentRequests({String status = 'pending'}) async =>
      adminQueue.where((r) => r.status == status).toList();

  @override
  Future<AdminOverview> adminOverview({int days = 30}) async => overview ?? fakeOverview(days: days);

  /// Suggestions envoyées (profil) et reçues (back office)
  final sentFeedback = <(FeedbackKind, String, String?)>[];
  final feedbackInbox = <AdminFeedback>[];

  @override
  Future<void> sendFeedback(FeedbackKind kind, String message, {String? businessId, String? appVersion}) async =>
      sentFeedback.add((kind, message, businessId));

  @override
  Future<({List<AdminFeedback> items, Map<FeedbackStatus, int> counts})> adminFeedback(FeedbackStatus status) async => (
    items: feedbackInbox.where((f) => f.status == status).toList(),
    counts: {for (final s in FeedbackStatus.values) s: feedbackInbox.where((f) => f.status == s).length},
  );

  @override
  Future<void> adminSetFeedback(String id, FeedbackStatus status) async {
    final i = feedbackInbox.indexWhere((f) => f.id == id);
    final f = feedbackInbox[i];
    feedbackInbox[i] = AdminFeedback(
      id: f.id,
      kind: f.kind,
      message: f.message,
      status: status,
      createdAt: f.createdAt,
      userPhone: f.userPhone,
      userName: f.userName,
      businessId: f.businessId,
      businessName: f.businessName,
      category: f.category,
    );
  }

  @override
  Future<AdminPage<AdminBusiness>> adminBusinesses(AdminBusinessQuery q) async {
    adminQueries.add(q);
    final needle = q.search.toLowerCase();
    final items = adminBusinessList
        .where((b) => needle.isEmpty || b.name.toLowerCase().contains(needle) || b.ownerPhone.contains(needle))
        .where((b) => q.plan == null || b.plan == q.plan)
        .where((b) => q.status == null ? b.status != AdminStatus.deleted : b.status == q.status)
        .toList();
    return AdminPage(items: items, total: items.length, page: 1, pageSize: 25);
  }

  @override
  Future<AdminBusinessDetail> adminBusiness(String id) async => adminDetails[id]!;

  @override
  Future<void> adminGift(String id, int days, String? reason) async => adminOps.add(('gift:$days', id, reason));

  @override
  Future<void> adminSuspend(String id, String reason) async => adminOps.add(('suspend', id, reason));

  @override
  Future<void> adminUnsuspend(String id) async => adminOps.add(('unsuspend', id, null));

  @override
  Future<void> adminRestore(String id) async => adminOps.add(('restore', id, null));

  @override
  Future<({List<AdminPayment> items, bool hasMore})> adminPayments({
    AdminPayStatus? status,
    bool? online,
    int page = 1,
  }) async => (
    items: adminPaymentList
        .where((p) => status == null || p.status == status)
        .where((p) => online == null || p.online == online)
        .toList(),
    hasMore: false,
  );

  @override
  Future<void> approvePayment(String id) async {
    adminOps.add(('approve', id, null));
    adminQueue.removeWhere((r) => r.id == id);
  }

  @override
  Future<void> rejectPayment(String id, String? note) async {
    adminOps.add(('reject', id, note));
    adminQueue.removeWhere((r) => r.id == id);
  }

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

  /// Stock des produits ajoutés au catalogue de démonstration.
  List<StockItem> extraStock = const [];
  @override
  Future<StockOverview> stock({bool lowOnly = false}) async {
    final items = [
      _stock(demoProducts[5], 2),
      _stock(demoProducts[2], 3),
      _stock(demoProducts[0], 24),
      _stock(demoProducts[3], 12),
      _stock(demoProducts[4], 18),
      _stock(demoProducts[1], 40),
      ...extraStock,
    ];
    return StockOverview(items: items, lowStock: 2, stockValue: 1240000);
  }

  @override
  Future<DaySummary> todaySummary() async => DaySummary(
    salesCount: 12,
    revenue: 86500,
    grossProfit: 23300,
    netProfit: 21300,
    expenses: 2000,
    collected: 52500,
    receivables: 34000,
    bySeller: const [
      SellerStat(userId: 'u1', name: 'Awa Diallo', salesCount: 7, revenue: 52000),
      SellerStat(userId: 'u2', name: 'Moussa Fall', salesCount: 4, revenue: 28500),
      SellerStat(userId: 'u3', name: '+221770000099', salesCount: 1, revenue: 6000),
    ],
    last7Days: const [52000, 61000, 48500, 73000, 69000, 91000, 86500],
    previous7DaysRevenue: 427000,
    byLocation: shopLocations.length > 1 && api.locationId == null
        ? [
            for (final (i, l) in shopLocations.indexed)
              LocationStat(id: l.id, name: l.name, salesCount: i == 0 ? 8 : 4, revenue: i == 0 ? 58000 : 28500),
          ]
        : const [],
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

  // ---------- Points de vente ----------
  /// Points de vente du faux serveur ; un seul par défaut (rien ne change à l'écran).
  List<ShopLocation> shopLocations = const [ShopLocation(id: 'loc1', name: 'Boutique principale', isDefault: true)];
  String? lockedLocation; // vendeur rattaché
  final savedLocations = <Map<String, Object?>>[];
  final archivedLocations = <String>[];
  final transferBodies = <Map<String, Object?>>[];
  final memberUpdates = <Map<String, Object?>>[];

  @override
  Future<LocationsState> locations() async => LocationsState(
    list: shopLocations,
    currentId: lockedLocation ?? api.locationId,
    writeTo: lockedLocation ?? api.locationId ?? shopLocations.first.id,
    locked: lockedLocation != null,
  );

  @override
  Future<ShopLocation> saveLocation({String? id, required String name, String? address, String? phone}) async {
    savedLocations.add({'id': id, 'name': name, 'address': address, 'phone': phone});
    final l = ShopLocation(id: id ?? 'loc${shopLocations.length + 1}', name: name, address: address);
    shopLocations = [...shopLocations.where((x) => x.id != l.id), l];
    return l;
  }

  @override
  Future<void> archiveLocation(String id) async {
    archivedLocations.add(id);
    shopLocations = shopLocations.where((l) => l.id != id).toList();
  }

  @override
  Future<void> makeMainLocation(String id) async {}

  @override
  Future<StockTransfer> transferStock({
    required String id,
    required String fromId,
    required String toId,
    required List<({String productId, double quantity})> lines,
    String? note,
  }) async {
    transferBodies.add({
      'fromId': fromId,
      'toId': toId,
      'lines': [for (final l in lines) (l.productId, l.quantity)],
    });
    String name(String id) => shopLocations.firstWhere((l) => l.id == id).name;
    return StockTransfer(
      id: id,
      number: 'TR-2026-0001',
      fromName: name(fromId),
      toName: name(toId),
      lines: const [],
      createdAt: DateTime(2026, 11, 18),
    );
  }

  @override
  Future<List<StockTransfer>> transfers() async => const [];

  /// Facture lue par le faux serveur (null : réponse par défaut ci-dessous).
  InvoiceScan? invoiceScan;
  Object? scanError;
  int scans = 0;

  @override
  Future<InvoiceScan> scanInvoice(List<int> bytes, {String filename = 'facture.jpg'}) async {
    scans++;
    if (scanError != null) throw scanError!;
    return invoiceScan ??
        InvoiceScan.fromJson({
          'readable': true,
          'supplier': {'id': 's1', 'name': 'Grossiste Sandaga', 'phone': '77 300 40 50'},
          'number': 'FA-1187',
          'date': '2026-11-17',
          'total': 61000,
          'remaining': 19,
          'lines': [
            {
              'label': 'BEURRE KARITE 250G',
              'quantity': 12,
              'unitCost': 2000,
              'productId': 'p1',
              'confidence': 'high',
              'candidates': [
                {'id': 'p1', 'name': 'Beurre de karité 250 g', 'unit': 'pièce', 'cost': 2000, 'price': 3500},
              ],
            },
            {
              'label': 'Savon noir artisanal',
              'quantity': 10,
              'unitCost': 1500,
              'productId': null,
              'confidence': 'none',
              'candidates': [],
            },
            {
              'label': 'Transport',
              'quantity': 1,
              'unitCost': 2000,
              'productId': null,
              'confidence': 'none',
              'candidates': [],
            },
          ],
        });
  }

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
      tagline: shopTagline,
      coverFileId: shopCoverFileId,
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

  String? shopCoverFileId;
  String? shopTagline;
  int shopCoverUploads = 0;

  @override
  Future<ShopSettings> uploadShopCover(List<int> bytes, {String filename = 'cover.jpg'}) async {
    shopCoverUploads++;
    shopCoverFileId = 'cover$shopCoverUploads';
    return ShopSettings(enabled: shopEnabled, coverFileId: shopCoverFileId);
  }

  @override
  Future<ShopSettings> deleteShopCover() async {
    shopCoverFileId = null;
    return ShopSettings(enabled: shopEnabled);
  }

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
  Future<void> inviteMember({
    required String phone,
    String? fullName,
    required TeamRole role,
    String? locationId,
  }) async {
    if (locationId != null) memberUpdates.add({'invite': phone, 'locationId': locationId});
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
  Future<void> updateMember(String id, {TeamRole? role, String? status, String? locationId}) async {
    if (locationId != null) memberUpdates.add({'id': id, 'locationId': locationId});
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
      locationId: locationId == null ? m.locationId : (locationId.isEmpty ? null : locationId),
    );
  }

  @override
  Future<void> removeMember(String id) async => team.removeWhere((m) => m.id == id);

  @override
  Future<MyDay> myDay() async => const MyDay(salesCount: 3, revenue: 14500, collected: 14500);

  // ---------- Rapports ----------
  final reportRequests = <(DateTime, DateTime)>[];

  // ---------- Réservation ----------
  BookingSettings bookingSettingsValue = const BookingSettings(bookingPath: '/r/awa-beaute');
  final savedBookingSettings = <BookingSettings>[];

  @override
  Future<BookingSettings> bookingSettings() async => bookingSettingsValue;

  @override
  Future<BookingSettings> saveBookingSettings(BookingSettings s) async {
    savedBookingSettings.add(s);
    return bookingSettingsValue = BookingSettings.fromJson({...s.toJson(), 'bookingPath': '/r/awa-beaute'});
  }

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
  // ── Livraison ──
  final courierList = <Courier>[
    const Courier(id: 'c1', name: 'Moussa Fall', phone: '+221771112233'),
    const Courier(id: 'c2', name: 'Ibou Ndiaye', phone: '+221774445566', vehicle: 'velo'),
  ];
  var ordersToDeliver = <OrderToDeliver>[];
  final deliveryList = <Delivery>[];
  var courierBalances = <CourierBalance>[];
  final deliveryOps = <(String, Object?)>[];

  @override
  Future<List<Courier>> couriers() async => List.of(courierList);

  @override
  Future<Courier> addCourier({required String name, String? phone, String vehicle = 'moto'}) async {
    final c = Courier(id: 'c${courierList.length + 1}', name: name, phone: phone, vehicle: vehicle);
    courierList.add(c);
    deliveryOps.add(('addCourier', name));
    return c;
  }

  @override
  Future<Courier> updateCourier(String id, Map<String, Object?> changes) async {
    deliveryOps.add(('updateCourier', changes));
    final i = courierList.indexWhere((c) => c.id == id);
    final old = courierList[i];
    return courierList[i] = Courier(
      id: id,
      name: changes['name'] as String? ?? old.name,
      phone: changes.containsKey('phone') ? changes['phone'] as String? : old.phone,
      vehicle: changes['vehicle'] as String? ?? old.vehicle,
      active: changes['active'] as bool? ?? old.active,
    );
  }

  @override
  Future<DeliveryBoard> deliveryBoard({bool done = false}) async {
    bool isDone(Delivery d) =>
        {DeliveryStatus.delivered, DeliveryStatus.failed, DeliveryStatus.cancelled}.contains(d.status);
    return DeliveryBoard(
      toAssign: done ? const [] : ordersToDeliver,
      items: deliveryList.where((d) => isDone(d) == done).toList(),
      withCouriers: done ? const [] : courierBalances,
    );
  }

  Delivery _withStatus(Delivery d, {DeliveryStatus? status, Courier? courier, String? failure}) => Delivery(
    id: d.id,
    orderId: d.orderId,
    orderNumber: d.orderNumber,
    customerName: d.customerName,
    customerPhone: d.customerPhone,
    address: d.address,
    note: d.note,
    courierId: courier?.id ?? d.courierId,
    courierName: courier?.name ?? d.courierName,
    courierPhone: courier?.phone ?? d.courierPhone,
    fee: d.fee,
    amountToCollect: d.amountToCollect,
    status: status ?? d.status,
    failureReason: failure ?? d.failureReason,
  );

  @override
  Future<Delivery> createDelivery(Map<String, Object?> data) async {
    deliveryOps.add(('create', data));
    final courier = courierList.where((c) => c.id == data['courierId']).firstOrNull;
    final order = ordersToDeliver.where((o) => o.orderId == data['orderId']).firstOrNull;
    final d = Delivery(
      id: 'dl${deliveryList.length + 1}',
      orderId: order?.orderId,
      orderNumber: order?.number,
      customerName: order?.customerName ?? data['customerName'] as String,
      customerPhone: order?.customerPhone ?? data['customerPhone'] as String?,
      address: order?.address ?? data['address'] as String,
      note: data['note'] as String?,
      courierId: courier?.id,
      courierName: courier?.name,
      courierPhone: courier?.phone,
      fee: data['fee'] as int? ?? 0,
      amountToCollect: order?.total ?? data['amountToCollect'] as int? ?? 0,
      status: courier == null ? DeliveryStatus.pending : DeliveryStatus.assigned,
    );
    if (order != null) ordersToDeliver = ordersToDeliver.where((o) => o != order).toList();
    deliveryList.insert(0, d);
    return d;
  }

  @override
  Future<Delivery> updateDelivery(String id, Map<String, Object?> changes) async {
    deliveryOps.add(('update', {'id': id, ...changes}));
    final i = deliveryList.indexWhere((d) => d.id == id);
    final courier = courierList.where((c) => c.id == changes['courierId']).firstOrNull;
    final status = changes['status'] == null
        ? (courier != null ? DeliveryStatus.assigned : null)
        : DeliveryStatus.of(changes['status'] as String);
    return deliveryList[i] = _withStatus(
      deliveryList[i],
      status: status,
      courier: courier,
      failure: changes['failureReason'] as String?,
    );
  }

  @override
  Future<int> settleCourier(String courierId) async {
    deliveryOps.add(('settle', courierId));
    final owed = courierBalances.firstWhere((c) => c.courierId == courierId).owed;
    courierBalances = courierBalances.where((c) => c.courierId != courierId).toList();
    return owed;
  }

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

  /// Erreur renvoyée par les rapports (ex. limite de la version gratuite)
  Object? reportsError;

  @override
  Future<ReportOverview> report(DateTime from, DateTime to) async {
    if (reportsError != null) throw reportsError!;
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

  // Suppression de boutique et de compte
  final deletedNames = <String>[];
  final accountDeletions = <String>[];
  var deletedList = <DeletedBusiness>[];
  final restored = <String>[];

  Me _withBusinesses(List<BusinessLink> list) => Me(
    id: profile.id,
    phone: profile.phone,
    fullName: profile.fullName,
    email: profile.email,
    avatarFileId: profile.avatarFileId,
    businesses: list,
  );

  @override
  Future<void> deleteBusiness(String confirmName) async {
    deletedNames.add(confirmName);
    final gone = profile.businesses.first;
    profile = _withBusinesses(profile.businesses.skip(1).toList());
    deletedList = [
      DeletedBusiness(
        id: gone.id,
        name: gone.name,
        purgeAt: DateTime.now().add(const Duration(days: 30)),
        daysLeft: 30,
      ),
    ];
  }

  @override
  Future<List<DeletedBusiness>> deletedBusinesses() async => deletedList;

  @override
  Future<void> restoreBusiness(String id) async {
    restored.add(id);
    final b = deletedList.firstWhere((d) => d.id == id);
    deletedList = deletedList.where((d) => d.id != id).toList();
    profile = _withBusinesses([
      ...profile.businesses,
      BusinessLink(id: b.id, name: b.name, role: 'owner', roleName: 'Propriétaire'),
    ]);
  }

  @override
  Future<void> deleteAccount(String confirm) async => accountDeletions.add(confirm);

  // Notifications push
  final pushTokens = <String, String>{};
  @override
  Future<void> registerPushToken(String token, String platform) async => pushTokens[token] = platform;
  @override
  Future<void> unregisterPushToken(String token) async => pushTokens.remove(token);

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
      firstItem: 'Beurre de karité 250 g',
      itemCount: 3,
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
  PushPlatform push = const NoPush(),
  PinStore? pinStore,
  Biometrics? biometrics,
}) async {
  pinUseIsolate = false; // calcul du code secret sur place (temps simulé des tests)
  Motion.enabled = false; // animations d'ambiance infinies : incompatibles avec pumpAndSettle
  await initializeDateFormatting('fr');
  repo ??= FakeRepo();
  final container = ProviderContainer(
    retry: samaRetry,
    overrides: [
      sessionStoreProvider.overrideWithValue(MemorySessionStore()),
      // Code secret : coupé par défaut ; activé quand un test fournit [pinStore]
      pinLockEnabledProvider.overrideWithValue(pinStore != null),
      pinStoreProvider.overrideWithValue(pinStore ?? MemoryPinStore()),
      biometricsProvider.overrideWithValue(biometrics ?? FakeBiometrics()),
      repoProvider.overrideWithValue(repo),
      authProvider.overrideWith(FakeAuth.new),
      // Notifications push : pas de Firebase dans les tests
      pushPlatformProvider.overrideWithValue(push),
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

/// Back office : l'application à part de l'équipe Sama360 (lib/admin_main.dart).
Future<(ProviderContainer, FakeRepo)> pumpAdmin(
  WidgetTester tester, {
  String location = '/admin',
  FakeRepo? repo,
  List<Override> overrides = const [],
}) async {
  Motion.enabled = false;
  await initializeDateFormatting('fr');
  repo ??= FakeRepo()..platformAdmin = true;
  final container = ProviderContainer(
    overrides: [
      sessionStoreProvider.overrideWithValue(MemorySessionStore()),
      repoProvider.overrideWithValue(repo),
      authProvider.overrideWith(FakeAuth.new),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);
  AppColors.palette = SamaPalette.light();
  await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const AdminApp(googleFonts: false)));
  await tester.pumpAndSettle();
  if (location != '/admin') {
    container.read(adminRouterProvider).go(location);
    await tester.pumpAndSettle();
  }
  return (container, repo);
}

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

/// Tableau de bord du back office pour les tests.
AdminOverview fakeOverview({int days = 30}) {
  final today = DateTime(2026, 11, 23);
  List<Map<String, dynamic>> series(int Function(int) f) => [
    for (var i = days - 1; i >= 0; i--)
      {'date': today.subtract(Duration(days: i)).toIso8601String().substring(0, 10), 'value': f(i)},
  ];
  return AdminOverview.fromJson({
    'days': days,
    'businesses': {
      'total': 128,
      'new': 21,
      'newPrevious': 14,
      'active7': 74,
      'everSold': 101,
      'suspended': 1,
      'deleted': 3,
    },
    'users': 212,
    'plans': {'trial': 52, 'active': 31, 'expired': 12, 'free': 33},
    'trialsEnding': [
      {'id': 'b2', 'name': 'Chez Maman Mav', 'ownerPhone': '+242061234567', 'daysLeft': 2},
    ],
    'weeks': [
      for (var i = 0; i < 8; i++)
        {
          'week': DateTime.utc(2026, 9, 28).add(Duration(days: 7 * i)).toIso8601String().substring(0, 10),
          'signups': 10 + i,
          'sold': 6 + i,
          'paid': i == 7 ? 4 : 2,
          'stopped': i == 6 ? 1 : 0,
          'trialsLost': 3,
        },
    ],
    'revenue': {
      'period': 185000,
      'previous': 140000,
      'allTime': 1240000,
      'mrr': 162000,
      'online': 120000,
      'manual': 65000,
      'payments': 31,
    },
    'pendingPayments': 2,
    'merchantsGmv30': 48500000,
    'merchantsSales30': 9120,
    'signupsByDay': series((i) => (i * 7) % 4),
    'revenueByDay': series((i) => i % 5 == 0 ? 15000 : 5000 * (i % 2)),
    'countries': [
      {'code': 'SN', 'name': 'Sénégal', 'count': 84},
      {'code': 'CI', 'name': 'Côte d’Ivoire', 'count': 30},
      {'code': 'CG', 'name': 'Congo', 'count': 14},
    ],
    'topBusinesses': [
      {'id': 'b1', 'name': 'Boutique Awa', 'country': 'SN', 'revenue30': 2450000, 'sales30': 412},
      {'id': 'b3', 'name': 'Koné Market', 'country': 'CI', 'revenue30': 1810000, 'sales30': 298},
    ],
    'latest': [
      {
        'id': 'b2',
        'name': 'Chez Maman Mav',
        'country': 'CG',
        'ownerName': 'Mav',
        'createdAt': '2026-11-22T10:00:00Z',
        'plan': 'trial',
      },
    ],
  });
}

AdminBusiness fakeAdminBusiness(
  String id,
  String name, {
  String plan = 'trial',
  String status = 'active',
  String country = 'SN',
  String phone = '+221771234567',
  int revenue30 = 0,
}) => AdminBusiness.fromJson({
  'id': id,
  'name': name,
  'slug': name.toLowerCase().replaceAll(' ', '-'),
  'country': country,
  'createdAt': '2026-10-02T09:00:00Z',
  'status': status,
  'owner': {'id': 'u-$id', 'name': 'Proprio $name', 'phone': phone},
  'plan': {'state': plan, 'endsAt': '2026-12-20T00:00:00Z', 'daysLeft': 27},
  'everPaid': plan == 'active',
  'members': 2,
  'stats': {
    'sales30': revenue30 == 0 ? 0 : 40,
    'revenue30': revenue30,
    'sales7': revenue30 == 0 ? 0 : 9,
    'lastSaleAt': revenue30 == 0 ? null : '2026-11-22T18:00:00Z',
    'products': 35,
    'customers': 18,
  },
});

/// Écran de téléphone 390 × 844 (densité 2).
void phoneSize(WidgetTester tester) {
  tester.view.physicalSize = const Size(780, 1688);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
}

/// Fait défiler jusqu'à placer l'élément au milieu de l'écran (hors des barres fixes) puis le touche.
Future<void> tapCentered(WidgetTester tester, Finder finder) async {
  await Scrollable.ensureVisible(tester.element(finder.first), alignment: 0.5);
  await tester.pumpAndSettle();
  await tester.tap(finder.first);
}
