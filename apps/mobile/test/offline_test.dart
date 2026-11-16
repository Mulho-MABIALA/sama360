import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/api/api_client.dart';
import 'package:sama360/core/api/session_store.dart';
import 'package:sama360/core/models.dart';
import 'package:sama360/core/offline/kv_store.dart';
import 'package:sama360/core/offline/pending_sales.dart';
import 'package:sama360/core/providers.dart';
import 'package:sama360/core/repositories.dart';
import 'package:sama360/features/auth/auth_controller.dart';

import 'helpers.dart';

/// Serveur simulé au niveau HTTP : répond depuis [routes], ou coupe le réseau.
class FakeServer implements HttpClientAdapter {
  bool down = false;
  final routes = <String, Object>{};
  final calls = <String>[];

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? body, Future<void>? cancel) async {
    calls.add('${o.method} ${o.uri.path}${o.uri.hasQuery ? '?${o.uri.query}' : ''}');
    if (down) throw DioException.connectionError(requestOptions: o, reason: 'pas de réseau');
    final data = routes[o.uri.path];
    if (data == null) {
      return ResponseBody.fromString(
        jsonEncode({
          'error': {'code': 'NOT_FOUND', 'message': 'Introuvable'},
        }),
        404,
        headers: {
          'content-type': ['application/json'],
        },
      );
    }
    return ResponseBody.fromString(
      jsonEncode(data),
      200,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _product(String id, String name, {String? cat}) => {
  'id': id,
  'name': name,
  'price': 1000,
  'cost': 500,
  'categoryId': cat,
  'imageFileIds': <String>[],
};

void main() {
  group('cache hors ligne du dépôt', () {
    late FakeServer server;
    late SamaRepository repo;
    late MemoryStore store;

    setUp(() {
      server = FakeServer();
      store = MemoryStore();
      final api = ApiClient(baseUrl: 'http://api.test', store: MemorySessionStore())..businessId = 'b1';
      api.dio.httpClientAdapter = server;
      repo = SamaRepository(api, cache: store);
      server.routes['/v1/catalog/products'] = {
        'data': [_product('p1', 'Savon noir', cat: 'c1'), _product('p2', 'Beurre de karité', cat: 'c2')],
      };
      server.routes['/v1/contacts'] = {
        'data': [
          {'id': 'k1', 'name': 'Fatou Ndiaye', 'phone': '+221771112233'},
          {'id': 'k2', 'name': 'Aminata Ba', 'phone': '+221765551234'},
        ],
      };
    });

    test('renvoie la dernière réponse connue quand le réseau manque', () async {
      expect(await repo.products(), hasLength(2));
      expect(repo.api.online.value, isTrue);

      server.down = true;
      final offline = await repo.products();
      expect(offline.map((p) => p.name), ['Savon noir', 'Beurre de karité']);
      expect(repo.api.online.value, isFalse);
    });

    test('recherche et filtre dans le catalogue gardé, clients par nom ou numéro', () async {
      await repo.products();
      await repo.customers();
      server.down = true;
      expect((await repo.products(search: 'karit')).single.id, 'p2');
      expect((await repo.products(categoryId: 'c1')).single.id, 'p1');
      expect((await repo.customers(search: 'fatou')).single.id, 'k1');
      expect((await repo.customers(search: '76 555')).single.id, 'k2');
    });

    test('sans cache, ou pour une vraie erreur du serveur, l’erreur remonte', () async {
      server.down = true;
      await expectLater(repo.debtors(), throwsA(isA<ApiException>().having((e) => e.isNetwork, 'réseau', isTrue)));
      server.down = false;
      await expectLater(repo.ledger('inconnu'), throwsA(isA<ApiException>().having((e) => e.status, 'statut', 404)));
    });

    test('le cache est propre à chaque entreprise et s’efface à la déconnexion', () async {
      await repo.products();
      repo.api.businessId = 'b2';
      server.down = true;
      await expectLater(repo.products(), throwsA(isA<ApiException>()));
      repo.api.businessId = 'b1';
      expect(await repo.products(), hasLength(2));
      await repo.clearCache();
      await expectLater(repo.products(), throwsA(isA<ApiException>()));
    });

    test('une vente vise l’entreprise où elle a été faite', () async {
      server.routes['/v1/sales'] = {'id': 's1', 'number': 'VEN-2026-0001', 'total': 1000, 'paid': 1000, 'due': 0};
      String? sentFor;
      repo.api.dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) {
            sentFor = o.headers['X-Business-Id'] as String?;
            h.next(o);
          },
        ),
      );
      await repo.postSale({'id': 's1'}, businessId: 'b-autre');
      expect(sentFor, 'b-autre');
    });
  });

  group('ventes en attente', () {
    late FakeRepo repo;
    late MemoryStore store;
    late ProviderContainer c;

    ProviderContainer make() {
      final container = ProviderContainer(
        overrides: [
          sessionStoreProvider.overrideWithValue(MemorySessionStore()),
          keyValueStoreProvider.overrideWithValue(store),
          repoProvider.overrideWithValue(repo),
          authProvider.overrideWith(FakeAuth.new),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    Future<CheckoutOutcome> sell(String id, {int qty = 1, DateTime? at}) => c
        .read(pendingSalesProvider.notifier)
        .checkout(
          id: id,
          businessId: 'b1',
          lines: [(product: demoProducts[0], quantity: qty.toDouble())],
          payments: [(method: PayMethod.cash, amount: 3500 * qty)],
          total: 3500 * qty,
          now: at,
        );

    setUp(() {
      repo = FakeRepo();
      store = MemoryStore();
      c = make();
    });

    test('sans réseau : la vente est gardée, avec l’heure du téléphone, même après redémarrage', () async {
      repo.offline = true;
      final at = DateTime(2026, 11, 16, 9, 30);
      final out = await sell('a1', qty: 2, at: at);
      expect(out, isA<SaleQueued>());
      expect(c.read(pendingSalesProvider).single.body['soldAt'], at.toUtc().toIso8601String());

      // L'app est relancée : la vente est toujours là
      final c2 = make();
      expect(c2.read(pendingSalesProvider).single.id, 'a1');
      expect(c2.read(pendingSalesProvider).single.total, 7000);
    });

    test('le stock affiché tient compte des ventes en attente', () {
      final stock = StockOverview(
        items: const [
          StockItem(productId: 'p1', name: 'Beurre', price: 3500, cost: 2000, threshold: 5, onHand: 6, low: false),
        ],
        lowStock: 0,
        stockValue: 0,
      );
      final pending = PendingSale(
        id: 'x',
        businessId: 'b1',
        soldAt: DateTime(2026),
        body: const {},
        total: 0,
        lines: const [(productId: 'p1', name: 'Beurre', quantity: 2)],
      );
      final net = stockNetOfPending(stock, [pending]);
      expect(net.items.single.onHand, 4);
      expect(net.items.single.low, isTrue);
      expect(net.lowStock, 1);
    });

    test('au retour du réseau : envoi dans l’ordre, sans doublon', () async {
      repo.offline = true;
      await sell('a1');
      await sell('a2');
      expect(c.read(pendingSalesProvider), hasLength(2));

      repo.offline = false;
      final report = await c.read(pendingSalesProvider.notifier).sync();
      expect(report.sent, 2);
      expect(repo.sales.map((s) => s['id']), ['a1', 'a2']);
      expect(c.read(pendingSalesProvider), isEmpty);
      expect(store.getString(PendingSalesController.storageKey), '[]');

      // Le serveur reçoit encore a1 (réponse perdue) : toujours une seule vente
      await repo.postSale(repo.sales.first);
      expect(repo.sales, hasLength(2));
    });

    test('réseau encore coupé : rien n’est perdu, la file attend', () async {
      repo.offline = true;
      await sell('a1');
      final report = await c.read(pendingSalesProvider.notifier).sync();
      expect(
        report,
        isA<SyncReport>().having((r) => r.offline, 'hors ligne', isTrue).having((r) => r.sent, 'envoyées', 0),
      );
      expect(c.read(pendingSalesProvider), hasLength(1));
    });

    test('vente refusée par le serveur : mise de côté avec le motif, les autres partent', () async {
      repo.offline = true;
      await sell('bad');
      await sell('ok');
      repo
        ..offline = false
        ..rejectIds.add('bad');
      final report = await c.read(pendingSalesProvider.notifier).sync();
      expect(report.sent, 1);
      expect(report.failed, 1);
      final left = c.read(pendingSalesProvider).single;
      expect(left.id, 'bad');
      expect(left.failed, isTrue);
      expect(left.error, contains('introuvable'));

      // Corrigé côté serveur : nouvel essai
      repo.rejectIds.clear();
      await c.read(pendingSalesProvider.notifier).retry('bad');
      expect(c.read(pendingSalesProvider), isEmpty);
    });

    test('une erreur métier à l’encaissement remonte (le panier reste à corriger)', () async {
      repo.rejectIds.add('z');
      await expectLater(sell('z'), throwsA(isA<ApiException>()));
      expect(c.read(pendingSalesProvider), isEmpty);
    });

    test('abandon d’une vente en attente', () async {
      repo.offline = true;
      await sell('a1');
      await c.read(pendingSalesProvider.notifier).discard('a1');
      expect(c.read(pendingSalesProvider), isEmpty);
    });
  });

  testWidgets('caisse hors ligne : vente gardée, bandeau, puis envoi au retour du réseau', (tester) async {
    phoneSize(tester);
    final (_, repo) = await pumpSama(tester, location: '/pos');
    repo.offline = true;

    await tester.tap(find.text('Beurre de karité 250 g'));
    await tester.pump();
    await tester.tap(find.textContaining('Encaisser 3'));
    await tester.pumpAndSettle();
    expect(find.text('Vente gardée sur le téléphone'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Nouvelle vente'));
    await tester.pumpAndSettle();

    expect(find.text('1 vente en attente d’envoi'), findsOneWidget);

    // Historique : la vente apparaît « En attente d'envoi »
    await tester.tap(find.byTooltip("Ventes d'aujourd'hui"));
    await tester.pumpAndSettle();
    expect(find.text('En attente d’envoi'), findsOneWidget);
    Navigator.of(tester.element(find.text('En attente d’envoi'))).pop();
    await tester.pumpAndSettle();

    repo.offline = false;
    await tester.tap(find.text('Envoyer'));
    await tester.pumpAndSettle();
    expect(repo.sales, hasLength(1));
    expect(find.text('1 vente en attente d’envoi'), findsNothing);
    expect(find.text('1 vente envoyée'), findsOneWidget);
  });
}
