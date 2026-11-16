import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:sama360/core/api/api_client.dart';
import 'package:sama360/core/api/session_store.dart';
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
  businesses: [BusinessLink(id: 'b1', name: 'Awa Beauté', category: 'boutique', role: 'owner', roleName: 'Propriétaire')],
);
const demoProducts = [
  Product(id: 'p1', name: 'Beurre de karité 250 g', price: 3500, cost: 2000, categoryId: 'c1'),
  Product(id: 'p2', name: 'Savon noir', price: 1500, cost: 800, categoryId: 'c1'),
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

  final sales = <Map<String, Object?>>[];
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

  @override
  Future<Product> uploadProductImage(String productId, List<int> bytes, {String filename = 'photo.jpg'}) async {
    uploads[productId] = bytes.length;
    return Product(id: productId, name: 'x', price: 0, cost: 0, imageFileId: 'f-$productId');
  }

  @override
  Future<CurrentBusiness> currentBusiness() async => demoBusiness;
  @override
  Future<List<Category>> categories() async => const [Category(id: 'c1', name: 'Soins'), Category(id: 'c2', name: 'Cheveux & parfums')];
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
  );

  @override
  Future<List<Debtor>> debtors() async => [
    Debtor(customerId: 'k1', name: 'Fatou Ndiaye', phone: '+221774120855', balance: 17500, firstDebtAt: DateTime(2026, 11, 2)),
    Debtor(customerId: 'k2', name: 'Aminata Ba', phone: '+221765551234', balance: 10000, firstDebtAt: DateTime(2026, 11, 9)),
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

  @override
  Future<SaleResult> createSale({
    required String id,
    String? customerId,
    required List<({String productId, double quantity})> items,
    required List<({PayMethod method, int amount})> payments,
  }) async {
    sales.add({'id': id, 'customerId': customerId, 'items': items, 'payments': payments});
    saleCounter++;
    final total = items.fold<int>(0, (s, i) => s + (demoProducts.firstWhere((p) => p.id == i.productId).price * i.quantity).round());
    final paid = payments.fold<int>(0, (s, p) => s + p.amount);
    return SaleResult(id: id, number: 'VEN-2026-000$saleCounter', total: total, paid: paid, due: total - paid);
  }

  @override
  Future<SaleDetail> sale(String id) async => id == 'voided' ? demoVoidedSale : demoSale;

  @override
  Future<List<SaleSummary>> salesOfDay([DateTime? day]) async => [
    SaleSummary(id: 's2', number: 'VEN-2026-0042', status: 'completed', customerName: 'Aminata Ba', total: 9000, due: 4000, soldAt: DateTime(2026, 11, 16, 11, 20)),
    SaleSummary(id: 'voided', number: 'VEN-2026-0041', status: 'voided', total: 3500, due: 0, soldAt: DateTime(2026, 11, 16, 10, 5)),
    SaleSummary(id: 's1', number: 'VEN-2026-0040', status: 'completed', total: 11600, due: 0, soldAt: DateTime(2026, 11, 16, 9, 42)),
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
}) async {
  await initializeDateFormatting('fr');
  final repo = FakeRepo();
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
