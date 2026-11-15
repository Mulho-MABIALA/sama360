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
import 'package:flutter_test/flutter_test.dart';
import 'package:sama360/core/api/api_client.dart';
import 'package:sama360/core/api/session_store.dart';
import 'package:sama360/core/models.dart';
import 'package:sama360/core/repositories.dart';
import 'package:uuid/uuid.dart';

final _api = Platform.environment['SAMA_API_URL'];
final _otpLog = Platform.environment['SAMA_OTP_LOG'];

Future<String> _otpFor(String phone) async {
  for (var i = 0; i < 40; i++) {
    final lines = File(_otpLog!).readAsLinesSync().where((l) => l.contains('Code de connexion pour $phone'));
    if (lines.isNotEmpty) return RegExp(r'(\d{6})\s*$').firstMatch(lines.last.replaceAll(RegExp(r'\x1b\[[0-9;]*m'), ''))!.group(1)!;
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

  test('parcours complet du commerçant', () async {
    final store = MemorySessionStore();
    final client = ApiClient(baseUrl: _api!, store: store);
    final repo = SamaRepository(client);
    final phone = '+22177${Random().nextInt(9000000) + 1000000}';

    // Connexion OTP
    final normalized = await repo.requestOtp(phone.substring(4)); // « 77xxxxxxx », sans indicatif
    expect(normalized, phone);
    await expectLater(
      repo.verifyOtp(phone, '000000'),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'OTP_INVALID').having((e) => e.detailInt('remainingAttempts'), 'reste', 4)),
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
    final karite = await repo.createProduct(name: 'Beurre de karité 250 g', price: 3500, cost: 2000, categoryId: cats.first.id);
    final huile = await repo.createProduct(name: 'Huile de coco 500 ml', price: 4000, cost: 2600, lowStockThreshold: 5);
    await repo.addStock(karite.id, 20);
    await repo.addStock(huile.id, 8);
    expect((await repo.products()).map((p) => p.name), containsAll(['Beurre de karité 250 g', 'Huile de coco 500 ml']));

    // Photo du produit : envoi, puis lecture publique comme l'app l'affiche
    final png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==');
    final withPhoto = await repo.uploadProductImage(karite.id, png, filename: 'karite.png');
    expect(withPhoto.imageFileId, isNotNull);
    final img = await Dio().get<List<int>>(repo.fileUrl(withPhoto.imageFileId!), options: Options(responseType: ResponseType.bytes));
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
    final stock = await _eventually(repo.stock, (s) => s.items.firstWhere((i) => i.productId == huile.id).onHand == 3);
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
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('session expirée : un seul rafraîchissement pour des requêtes simultanées', () async {
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
  }, skip: skip, timeout: const Timeout(Duration(minutes: 1)));
}
