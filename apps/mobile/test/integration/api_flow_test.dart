@Tags(['integration'])
library;

/// Parcours réel contre l'API Sama360 (pas de données factices).
/// Prérequis : API + worker démarrés, et SAMA_API_URL / SAMA_OTP_LOG (journal de l'API
/// où s'affichent les codes OTP en développement).
///   SAMA_API_URL=http://localhost:3000 SAMA_OTP_LOG=/tmp/api.log flutter test --tags integration
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sama360/core/api/api_client.dart';
import 'package:sama360/core/api/session_store.dart';
import 'package:sama360/core/models.dart';
import 'package:sama360/core/offline/kv_store.dart';
import 'package:sama360/core/offline/pending_sales.dart';
import 'package:sama360/core/providers.dart';
import 'package:sama360/core/repositories.dart';
import 'package:uuid/uuid.dart';

final _api = Platform.environment['SAMA_API_URL'];
final _otpLog = Platform.environment['SAMA_OTP_LOG'];

Future<String> _otpFor(String phone) async {
  for (var i = 0; i < 40; i++) {
    final lines = File(_otpLog!).readAsLinesSync().where((l) => l.contains('Code de connexion pour $phone'));
    if (lines.isNotEmpty) {
      return RegExp(r'(\d{6})\s*$').firstMatch(lines.last.replaceAll(RegExp(r'\x1b\[[0-9;]*m'), ''))!.group(1)!;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError('Code OTP introuvable dans $_otpLog');
}

Future<T> _eventually<T>(Future<T> Function() read, bool Function(T) ok) async {
  for (var i = 0; i < 60; i++) {
    final v = await read();
    if (ok(v)) return v;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  throw StateError('Condition non atteinte');
}

void main() {
  final skip = _api == null || _otpLog == null ? 'SAMA_API_URL et SAMA_OTP_LOG requis' : false;

  test(
    'parcours complet du commerçant',
    () async {
      final store = MemorySessionStore();
      final client = ApiClient(baseUrl: _api!, store: store);
      final repo = SamaRepository(client);
      final phone = '+22177${Random().nextInt(9000000) + 1000000}';

      // Connexion OTP
      final normalized = await repo.requestOtp(phone.substring(4)); // « 77xxxxxxx », sans indicatif
      expect(normalized, phone);
      await expectLater(
        repo.verifyOtp(phone, '000000'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'OTP_INVALID')
              .having((e) => e.detailInt('remainingAttempts'), 'reste', 4),
        ),
      );
      final t = await repo.verifyOtp(phone, await _otpFor(phone));
      await store.save(Session(accessToken: t.access, refreshToken: t.refresh));

      var me = await repo.me();
      expect(me.needsProfile, isTrue);
      await repo.updateName('Awa Diallo');
      me = await repo.me();
      expect(me.fullName, 'Awa Diallo');
      expect(me.businesses, isEmpty);

      // Entreprise
      client.businessId = await repo.createBusiness(name: 'Awa Beauté test', category: 'boutique', city: 'Dakar');
      final biz = await repo.currentBusiness();
      expect(biz.role, 'owner');
      expect(biz.permissions, ['*']);
      expect(biz.modules, containsAll(['sales', 'inventory']));
      final cats = await _eventually(repo.categories, (c) => c.length >= 2); // créées par le worker
      expect(cats.map((c) => c.name), ['Général', 'Nouveautés']);

      // Produits et stock
      final karite = await repo.createProduct(
        name: 'Beurre de karité 250 g',
        price: 3500,
        cost: 2000,
        categoryId: cats.first.id,
      );
      final huile = await repo.createProduct(
        name: 'Huile de coco 500 ml',
        price: 4000,
        cost: 2600,
        lowStockThreshold: 5,
      );
      await repo.addStock(karite.id, 20);
      await repo.addStock(huile.id, 8);
      expect(
        (await repo.products()).map((p) => p.name),
        containsAll(['Beurre de karité 250 g', 'Huile de coco 500 ml']),
      );

      // Photo du produit : envoi, puis lecture publique comme l'app l'affiche
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
      );
      final withPhoto = await repo.uploadProductImage(karite.id, png, filename: 'karite.png');
      expect(withPhoto.imageFileId, isNotNull);
      final img = await Dio().get<List<int>>(
        repo.fileUrl(withPhoto.imageFileId!),
        options: Options(responseType: ResponseType.bytes),
      );
      expect(img.headers.value('content-type'), 'image/png');
      expect(img.data, png);
      expect((await repo.stock()).items.firstWhere((i) => i.productId == karite.id).imageFileId, withPhoto.imageFileId);
      await expectLater(
        repo.uploadProductImage(karite.id, utf8.encode('pas une image'), filename: 'x.jpg'),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'VALIDATION_FAILED')),
      );

      // Vente au comptant (Wave), idempotente
      final id = const Uuid().v7();
      final items = [(productId: karite.id, quantity: 2.0), (productId: huile.id, quantity: 1.0)];
      final cash = await repo.createSale(id: id, items: items, payments: [(method: PayMethod.wave, amount: 11000)]);
      expect(cash.total, 11000);
      expect(cash.due, 0);
      final again = await repo.createSale(id: id, items: items, payments: [(method: PayMethod.wave, amount: 11000)]);
      expect(again.number, cash.number);

      // Vente à crédit avec acompte
      final aminata = await repo.createCustomer(name: 'Aminata Ba', phone: '+221765551234');
      final credit = await repo.createSale(
        id: const Uuid().v7(),
        customerId: aminata.id,
        items: [(productId: huile.id, quantity: 4.0)],
        payments: [(method: PayMethod.cash, amount: 6000)],
      );
      expect(credit.due, 10000);
      await expectLater(
        repo.createSale(id: const Uuid().v7(), items: [(productId: huile.id, quantity: 1.0)], payments: const []),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'CREDIT_REQUIRES_CUSTOMER')),
      );

      // Stock décrémenté par le worker : huile 8 − 1 − 4 = 3 (≤ seuil 5)
      final stock = await _eventually(
        repo.stock,
        (s) => s.items.firstWhere((i) => i.productId == huile.id).onHand == 3,
      );
      expect(stock.items.firstWhere((i) => i.productId == huile.id).low, isTrue);
      expect(stock.lowStock, 1);

      // Résumé du jour
      final s = await repo.todaySummary();
      expect(s.salesCount, 2);
      expect(s.revenue, 27000);
      expect(s.collected, 17000);
      expect(s.receivables, 10000);
      expect(s.grossProfit, 27000 - (2 * 2000 + 2600 + 4 * 2600));

      // Carnet de crédit
      final debtors = await repo.debtors();
      expect(debtors.single.name, 'Aminata Ba');
      expect(debtors.single.balance, 10000);
      expect(await repo.repay(aminata.id, 4000, PayMethod.orangeMoney), 6000);
      final ledger = await repo.ledger(aminata.id);
      expect(ledger.balance, 6000);
      expect(ledger.entries.map((e) => e.type), ['repayment', 'debt']);
      expect(ledger.customer.phone, '+221765551234');
      expect((await repo.customers(search: 'Aminata')).single.id, aminata.id);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'session expirée : un seul rafraîchissement pour des requêtes simultanées',
    () async {
      final store = MemorySessionStore();
      var expired = false;
      final client = ApiClient(baseUrl: _api!, store: store, onSessionExpired: () => expired = true);
      final repo = SamaRepository(client);
      final phone = '+22178${Random().nextInt(9000000) + 1000000}';
      await repo.requestOtp(phone);
      final t = await repo.verifyOtp(phone, await _otpFor(phone));
      await store.save(Session(accessToken: t.access, refreshToken: t.refresh));
      await repo.updateName('Moussa Fall');

      // L'API de test émet des jetons d'accès de 3 s (JWT_ACCESS_TTL=3s).
      await Future<void>.delayed(const Duration(seconds: 4));
      final results = await Future.wait([repo.me(), repo.me(), repo.me()]);
      expect(results.map((m) => m.fullName).toSet(), {'Moussa Fall'});
      expect(expired, isFalse);
      expect((await store.read())!.refreshToken, isNot(t.refresh)); // jeton renouvelé une fois
      expect((await repo.me()).fullName, 'Moussa Fall'); // la nouvelle session fonctionne
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'hors ligne réel : lecture depuis le cache, vente gardée puis envoyée au retour du réseau',
    () async {
      final store = MemorySessionStore();
      final client = ApiClient(baseUrl: _api!, store: store);
      final cache = MemoryStore();
      final repo = SamaRepository(client, cache: cache);
      final phone = '+22176${Random().nextInt(9000000) + 1000000}';
      await repo.requestOtp(phone);
      final t = await repo.verifyOtp(phone, await _otpFor(phone));
      await store.save(Session(accessToken: t.access, refreshToken: t.refresh));
      await repo.updateName('Fatou Sarr');
      client.businessId = await repo.createBusiness(name: 'Fatou Tissus test', category: 'boutique', city: 'Thiès');
      final bazin = await repo.createProduct(name: 'Bazin riche 1 m', price: 5000, cost: 3000);
      await repo.addStock(bazin.id, 10);
      await _eventually(repo.stock, (s) => s.items.any((i) => i.productId == bazin.id && i.onHand == 10));
      await repo.products(); // l'app a chargé la caisse une fois avec du réseau

      // Coupure : l'API n'est plus joignable
      client.dio.options.baseUrl = 'http://127.0.0.1:9';
      expect((await repo.products()).single.name, 'Bazin riche 1 m');
      expect(client.online.value, isFalse);

      final container = ProviderContainer(
        overrides: [
          sessionStoreProvider.overrideWithValue(store),
          keyValueStoreProvider.overrideWithValue(MemoryStore()),
          repoProvider.overrideWithValue(repo),
        ],
      );
      addTearDown(container.dispose);
      final soldAt = DateTime.now().subtract(const Duration(minutes: 20));
      final saleId = const Uuid().v7();
      final outcome = await container
          .read(pendingSalesProvider.notifier)
          .checkout(
            id: saleId,
            businessId: client.businessId!,
            lines: [(product: bazin, quantity: 2.0)],
            payments: [(method: PayMethod.cash, amount: 10000)],
            total: 10000,
            now: soldAt,
          );
      expect(outcome, isA<SaleQueued>());

      // Retour du réseau
      client.dio.options.baseUrl = _api!;
      final report = await container.read(pendingSalesProvider.notifier).sync();
      expect(report.sent, 1);
      expect(container.read(pendingSalesProvider), isEmpty);

      final sale = await repo.sale(saleId);
      expect(sale.total, 10000);
      expect(sale.soldAt.toUtc().difference(soldAt.toUtc()).inSeconds.abs(), lessThan(1)); // heure du téléphone gardée
      final stock = await _eventually(repo.stock, (s) => s.items.single.onHand == 8);
      expect(stock.items.single.onHand, 8);

      // Renvoi (réponse perdue) : toujours une seule vente
      await container
          .read(pendingSalesProvider.notifier)
          .checkout(
            id: saleId,
            businessId: client.businessId!,
            lines: [(product: bazin, quantity: 2.0)],
            payments: [(method: PayMethod.cash, amount: 10000)],
            total: 10000,
            now: soldAt,
          );
      expect((await repo.salesOfDay()).where((x) => x.id == saleId), hasLength(1));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'équipe réelle : invitation d’un vendeur, ventes par vendeur, retrait',
    () async {
      Future<(ApiClient, SamaRepository)> signIn(String phone, String name) async {
        final store = MemorySessionStore();
        final client = ApiClient(baseUrl: _api!, store: store);
        final repo = SamaRepository(client);
        await repo.requestOtp(phone);
        final t = await repo.verifyOtp(phone, await _otpFor(phone));
        await store.save(Session(accessToken: t.access, refreshToken: t.refresh));
        await repo.updateName(name);
        return (client, repo);
      }

      final ownerPhone = '+22177${Random().nextInt(9000000) + 1000000}';
      final sellerPhone = '+22170${Random().nextInt(9000000) + 1000000}';
      final (ownerApi, owner) = await signIn(ownerPhone, 'Khady Diop');
      ownerApi.businessId = await owner.createBusiness(name: 'Khady Mode test', category: 'boutique', city: 'Dakar');
      final pagne = await owner.createProduct(name: 'Pagne wax', price: 6000, cost: 3500);
      await owner.addStock(pagne.id, 10);

      // Invitation du vendeur (numéro saisi sans indicatif, comme dans l'app)
      await owner.inviteMember(phone: sellerPhone, fullName: 'Ibou Ndiaye', role: TeamRole.cashier);
      var team = await owner.members();
      expect(team.firstWhere((m) => m.phone == sellerPhone).status, 'invited');

      // Première connexion du vendeur : l'adhésion s'active
      final (sellerApi, seller) = await signIn(sellerPhone, 'Ibou Ndiaye');
      sellerApi.businessId = ownerApi.businessId;
      final sellerBiz = await seller.currentBusiness();
      expect(sellerBiz.role, 'cashier');
      team = await owner.members();
      expect(team.firstWhere((m) => m.phone == sellerPhone).status, 'active');

      // Chacun vend
      await owner.createSale(
        id: const Uuid().v7(),
        items: [(productId: pagne.id, quantity: 1.0)],
        payments: [(method: PayMethod.cash, amount: 6000)],
      );
      await seller.createSale(
        id: const Uuid().v7(),
        items: [(productId: pagne.id, quantity: 2.0)],
        payments: [(method: PayMethod.wave, amount: 12000)],
      );

      final summary = await owner.todaySummary();
      expect(summary.bySeller.map((v) => (v.name, v.salesCount, v.revenue)), [
        ('Ibou Ndiaye', 1, 12000),
        ('Khady Diop', 1, 6000),
      ]);
      final my = await seller.myDay();
      expect((my.salesCount, my.revenue), (1, 12000));
      expect((await seller.salesOfDay(null, true)).single.cashierName, 'Ibou Ndiaye');
      await expectLater(seller.todaySummary(), throwsA(isA<ApiException>().having((e) => e.status, 'statut', 403)));
      await expectLater(seller.members(), throwsA(isA<ApiException>().having((e) => e.status, 'statut', 403)));

      // Retrait : le vendeur n'a plus accès, ses ventes restent
      final member = team.firstWhere((m) => m.phone == sellerPhone);
      await owner.removeMember(member.id);
      await expectLater(seller.currentBusiness(), throwsA(isA<ApiException>().having((e) => e.status, 'statut', 403)));
      expect((await owner.todaySummary()).salesCount, 2);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'factures réelles : devis, facture, paiements, stock',
    () async {
      final store = MemorySessionStore();
      final client = ApiClient(baseUrl: _api!, store: store);
      final repo = SamaRepository(client);
      final phone = '+22177${Random().nextInt(9000000) + 1000000}';
      await repo.requestOtp(phone);
      final t = await repo.verifyOtp(phone, await _otpFor(phone));
      await store.save(Session(accessToken: t.access, refreshToken: t.refresh));
      await repo.updateName('Mame Diarra');
      client.businessId = await repo.createBusiness(name: 'Diarra Couture test', category: 'atelier', city: 'Dakar');
      final tissu = await repo.createProduct(name: 'Bazin 3 m', price: 15000, cost: 9000);
      await repo.addStock(tissu.id, 10);
      final hotel = await repo.createCustomer(name: 'Hôtel Teranga', phone: '33 820 00 00');

      final quoteId = const Uuid().v7();
      final now = DateTime.now();
      final body = SamaRepository.documentBody(
        customerId: hotel.id,
        lines: [
          DocLineDraft(productId: tissu.id, name: tissu.name, quantity: 4, unitPrice: tissu.price),
          const DocLineDraft(name: 'Confection', description: '4 tenues', quantity: 4, unitPrice: 10000),
        ],
        discount: 5000,
        issueDate: DateTime(now.year, now.month, now.day),
        dueDate: DateTime(now.year, now.month, now.day).add(const Duration(days: 30)),
        note: 'Livraison samedi',
      );
      final quote = await repo.createDocument(id: quoteId, kind: DocKind.quote, body: body);
      expect(quote.number, 'DEV-${now.year}-0001');
      expect(quote.total, 95000);
      expect(
        (await repo.createDocument(id: quoteId, kind: DocKind.quote, body: body)).id,
        quoteId,
      ); // renvoi sans doublon

      expect((await repo.quoteAction(quoteId, 'accept')).status, 'accepted');
      final invoice = await repo.convertQuote(quoteId);
      expect(invoice.number, 'FAC-${now.year}-0001');
      expect(invoice.related!.number, quote.number);
      expect(invoice.status, 'unpaid');

      final payId = const Uuid().v7();
      var paid = await repo.payInvoice(
        invoice.id,
        paymentId: payId,
        amount: 50000,
        method: PayMethod.wave,
        reference: 'WV-1',
      );
      expect((paid.status, paid.due), ('partial', 45000));
      paid = await repo.payInvoice(
        invoice.id,
        paymentId: payId,
        amount: 50000,
        method: PayMethod.wave,
      ); // même paiement renvoyé
      expect(paid.paid, 50000);

      final summary = await repo.invoicingSummary();
      expect(summary.receivable, 45000);
      expect(summary.openInvoices, 1);
      expect((await repo.documents(kind: DocKind.invoice)).single.status, 'partial');

      // La facture fait sortir 4 bazins du stock (via le worker)
      final stock = await _eventually(repo.stock, (s) => s.items.single.onHand == 6);
      expect(stock.items.single.onHand, 6);

      paid = await repo.payInvoice(invoice.id, paymentId: const Uuid().v7(), amount: 45000, method: PayMethod.transfer);
      expect(paid.status, 'paid');
      await expectLater(
        repo.cancelInvoice(invoice.id, 'test'),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'INVOICE_HAS_PAYMENTS')),
      );
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'rapport réel : totaux et série cohérents avec les ventes',
    () async {
      final store = MemorySessionStore();
      final client = ApiClient(baseUrl: _api!, store: store);
      final repo = SamaRepository(client);
      final phone = '+22177${Random().nextInt(9000000) + 1000000}';
      await repo.requestOtp(phone);
      final t = await repo.verifyOtp(phone, await _otpFor(phone));
      await store.save(Session(accessToken: t.access, refreshToken: t.refresh));
      await repo.updateName('Coumba Ndoye');
      client.businessId = await repo.createBusiness(name: 'Coumba Épices test', category: 'boutique', city: 'Dakar');
      final poivre = await repo.createProduct(name: 'Poivre de Selim', price: 1500, cost: 900);
      await repo.addStock(poivre.id, 50);
      for (final (q, m) in [(2.0, PayMethod.cash), (4.0, PayMethod.wave), (1.0, PayMethod.cash)]) {
        await repo.createSale(
          id: const Uuid().v7(),
          items: [(productId: poivre.id, quantity: q)],
          payments: [(method: m, amount: (1500 * q).round())],
        );
      }
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final r = await repo.report(today.subtract(const Duration(days: 6)), today);
      expect((r.salesCount, r.revenue, r.cost, r.grossProfit), (3, 10500, 6300, 4200));
      expect(r.series, hasLength(7));
      expect(r.series.last.revenue, 10500);
      expect(r.byMethod.map((m) => (m.method, m.amount)), [(PayMethod.wave, 6000), (PayMethod.cash, 4500)]);
      expect(r.topProducts.single.quantity, 7);
      expect(r.revenueChange, isNull); // rien la semaine d'avant
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'catalogue réel : fiche complète, code-barres, prix de gros en caisse, catégories',
    () async {
      final store = MemorySessionStore();
      final client = ApiClient(baseUrl: _api!, store: store);
      final repo = SamaRepository(client);
      final phone = '+22177${Random().nextInt(9000000) + 1000000}';
      await repo.requestOtp(phone);
      final t = await repo.verifyOtp(phone, await _otpFor(phone));
      await store.save(Session(accessToken: t.access, refreshToken: t.refresh));
      await repo.updateName('Modou Sow');
      client.businessId = await repo.createBusiness(name: 'Sow Alimentation test', category: 'boutique', city: 'Thiès');

      final cat = await repo.createCategory('Céréales');
      final riz = await repo.saveProduct(
        ProductDraft(
          name: 'Riz brisé 25 kg',
          price: 12500,
          cost: 11000,
          unit: 'sac',
          categoryId: cat.id,
          barcode: '6111000000017',
          wholesalePrice: 12000,
          wholesaleMinQty: 5,
        ),
      );
      expect((riz.unit, riz.hasWholesale), ('sac', true));
      expect((await repo.productByCode('6111000000017'))!.id, riz.id);
      expect(await repo.productByCode('999'), isNull);
      await expectLater(
        repo.saveProduct(const ProductDraft(name: 'Doublon', price: 100, barcode: '6111000000017')),
        throwsA(isA<ApiException>().having((e) => e.message, 'message', contains('Riz brisé 25 kg'))),
      );
      expect((await repo.categories()).single.productCount, 1);

      await repo.addStock(riz.id, 20);
      final small = await repo.createSale(
        id: const Uuid().v7(),
        items: [(productId: riz.id, quantity: 2.0)],
        payments: [(method: PayMethod.cash, amount: 25000)],
      );
      final bulk = await repo.createSale(
        id: const Uuid().v7(),
        items: [(productId: riz.id, quantity: 5.0)],
        payments: [(method: PayMethod.cash, amount: 60000)],
      );
      expect((small.total, bulk.total), (25000, 60000)); // 5 sacs au prix de gros
      expect(riz.unitPriceFor(5) * 5, bulk.total); // même calcul côté app

      final updated = await repo.saveProduct(
        ProductDraft(
          name: 'Riz brisé 25 kg',
          price: 13000,
          cost: 11000,
          unit: 'sac',
          categoryId: cat.id,
          barcode: '6111000000017',
        ),
        id: riz.id,
      );
      expect((updated.price, updated.hasWholesale), (13000, false));
      await repo.deleteCategory(cat.id);
      expect((await repo.product(riz.id)).categoryId, isNull);
      await repo.deleteProduct(riz.id);
      expect(await repo.productByCode('6111000000017'), isNull);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
