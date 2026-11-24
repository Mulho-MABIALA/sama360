import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/models.dart';
import 'package:sama360/core/providers.dart';
import 'package:sama360/features/catalog/barcode_scanner.dart';
import 'package:sama360/features/purchasing/purchase_editor.dart';
import 'package:sama360/features/purchasing/purchase_pdf.dart';
import 'package:sama360/features/sales/receipt.dart';
import 'package:sama360/features/sales/receipt_screen.dart';

import 'helpers.dart';
import 'receipt_test.dart' show RecordingActions;

Finder textMatching(String pattern) => find.byWidgetPredicate(
  (w) => w is Text && w.data != null && RegExp(pattern).hasMatch(w.data!.replaceAll(RegExp(r'[  ]'), ' ')),
);

Finder get mainScroll => find.byType(Scrollable).first;

const cashierBusiness = CurrentBusiness(
  id: 'b1',
  name: 'Awa Beauté',
  slug: 'awa-beaute',
  role: 'cashier',
  permissions: ['business:read', 'contacts:read', 'contacts:write', 'inventory:read', 'sales:create'],
  modules: ['sales', 'inventory'],
);

void main() {
  setUpAll(() async {
    await initializeDateFormatting('fr');
    await loadTestFonts();
  });

  group('logique', () {
    test('quantité proposée pour un produit en stock bas', () {
      StockItem item(double onHand, int threshold) =>
          StockItem(productId: 'p', name: 'P', price: 0, cost: 0, threshold: threshold, onHand: onHand, low: true);
      expect(suggestedReorder(item(2, 5)), 8);
      expect(suggestedReorder(item(0, 5)), 10);
      expect(suggestedReorder(item(9.5, 5)), 1);
      expect(suggestedReorder(item(-3, 5)), 13);
    });

    test('reste payable, retard de livraison, modifiable', () async {
      final repo = FakeRepo();
      final ordered = await repo.purchase('po1');
      expect(ordered.payable, 88000); // avance possible jusqu'au montant commandé
      expect(ordered.summary.late(DateTime(2026, 11, 16)), isTrue);
      expect(ordered.summary.late(DateTime(2026, 11, 13)), isFalse);
      expect(ordered.editable, isTrue);
      final partial = await repo.purchase('po2');
      expect(partial.payable, 80000);
      expect(partial.editable, isFalse);
      expect(partial.lines.first.remaining, 10);
      expect((await repo.purchase('po4')).payable, 0); // brouillon
    });

    test('lecture d’un bon renvoyé par l’API', () {
      final d = PurchaseDetail.fromJson(
        jsonDecode('''{
          "id": "o1", "number": "BC-2026-0001", "status": "partial", "supplierId": "s1",
          "orderDate": "2026-11-10", "expectedDate": "2026-12-01", "total": "44500", "receivedTotal": 14000,
          "paid": 0, "due": 14000, "lineCount": 2,
          "supplier": {"id": "s1", "name": "Grossiste", "phone": "+221773004050"},
          "note": null,
          "lines": [{"id": "l1", "productId": "p1", "name": "Huile", "unit": "bidon", "quantity": "30",
                     "receivedQty": 10, "unitCost": 1400, "total": 42000}],
          "receipts": [{"id": "r1", "total": 14000, "note": null, "receivedAt": "2026-11-12T09:00:00Z", "receivedBy": "Awa"}],
          "payments": [{"id": "p1", "method": "orange_money", "amount": 5000, "reference": null, "paidAt": "2026-11-12T10:00:00Z"}]
        }''')
            as Map<String, dynamic>,
      );
      expect(d.status, PurchaseStatus.partial);
      expect(d.summary.supplierName, 'Grossiste');
      expect(d.summary.expectedDate, DateTime(2026, 12, 1));
      expect((d.lines.single.quantity, d.lines.single.remaining, d.lines.single.unit), (30.0, 20.0, 'bidon'));
      expect(d.payments.single.method, PayMethod.orangeMoney);
      expect(d.receipts.single.receivedBy, 'Awa');
    });

    test('bon de commande en texte et en PDF', () async {
      final repo = FakeRepo();
      final d = await repo.purchase('po1');
      final text = purchaseText(d, demoBusiness).replaceAll(RegExp(r'[  ]'), ' ');
      expect(text, contains('Voici notre commande BC-2026-0007 (Awa Beauté) :'));
      expect(text, contains('• 24 × Beurre de karité 250 g'));
      expect(text, contains('Livraison souhaitée le 13 novembre 2026.'));
      expect(text, contains('Livrer à la boutique de Sandaga'));
      final pdf = await buildPurchasePdf(d, demoBusiness, fonts: await ReceiptFonts.load());
      expect(latin1.decode(pdf).startsWith('%PDF-'), isTrue);
      expect(purchaseFileName(d), 'Bon-de-commande-BC-2026-0007.pdf');
    });
  });

  group('écrans', () {
    testWidgets('achats : totaux, retard, filtres, onglet fournisseurs', (tester) async {
      phoneSize(tester);
      final (c, repo) = await pumpSama(tester, location: '/purchases');
      expect(textMatching(r'^42 500 F$'), findsOneWidget);
      expect(find.text('BC-2026-0007'), findsOneWidget);
      expect(find.text('En retard'), findsOneWidget);
      expect(find.text('BC-2026-0003'), findsNothing); // reçu : pas dans « En cours »

      await tester.tap(find.text('À payer'));
      await tester.pumpAndSettle();
      expect(repo.purchaseQueries.last.$1, PurchaseFilter.unpaid);
      expect(find.text('BC-2026-0003'), findsOneWidget);
      expect(textMatching(r'^à payer 22 500 F$'), findsOneWidget);

      await tester.tap(find.text('Fournisseurs'));
      await tester.pumpAndSettle();
      expect(find.text('Grossiste Sandaga'), findsOneWidget);
      expect(find.text('Imprimerie du Port'), findsOneWidget);
      expect(find.text('Nouveau fournisseur'), findsOneWidget);
      await tester.tap(find.text('Grossiste Sandaga'));
      await tester.pumpAndSettle();
      expect(routerOf(c).state.matchedLocation, '/suppliers/s1');
    });

    testWidgets('nouvelle commande : fournisseur, produit, quantité et prix, livraison', (tester) async {
      phoneSize(tester);
      final (c, repo) = await pumpSama(tester, location: '/purchases/new');
      await tester.tap(find.text('Passer la commande'));
      await tester.pumpAndSettle();
      expect(find.text('Choisissez le fournisseur'), findsOneWidget);

      await tester.tap(find.text('Choisir le fournisseur'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Grossiste Sandaga'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Produit'));
      await tester.pumpAndSettle();
      expect(textMatching(r'^Coût d’achat 800 F$'), findsOneWidget);
      await tester.tap(find.text('Savon noir'));
      await tester.pumpAndSettle();
      await tester.tap(textMatching(r'^1 × 800 F = 800 F$'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('plQty')), '60');
      await tester.enterText(find.byKey(const Key('plCost')), '750');
      await tester.tap(find.text('Valider'));
      await tester.pumpAndSettle();
      expect(textMatching(r'^45 000 F$'), findsOneWidget);

      await tester.tap(find.text('Sous 7 jours'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Passer la commande'));
      await tester.pumpAndSettle();
      final body = repo.purchaseBodies.single;
      expect(body['supplierId'], 's1');
      expect(body['lines'], [
        {'productId': 'p2', 'quantity': 60.0, 'unitCost': 750},
      ]);
      expect(body['draft'], false);
      expect(body.containsKey('receive'), isFalse);
      final now = DateTime.now();
      final expected = DateTime(now.year, now.month, now.day).add(const Duration(days: 7));
      expect(body['expectedDate'], expected.toIso8601String().substring(0, 10));
      expect(routerOf(c).state.matchedLocation, '/purchases/po1');
    });

    testWidgets('achat direct : marchandise reçue et payée tout de suite', (tester) async {
      phoneSize(tester);
      final (_, repo) = await pumpSama(tester, location: '/purchases/new?supplierId=s1');
      expect(find.text('Grossiste Sandaga'), findsOneWidget);
      await tester.tap(find.text('Produit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Beurre de karité 250 g'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('alreadyReceived')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tout'));
      await tester.pumpAndSettle();
      await tester.drag(mainScroll, const Offset(0, -300));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Wave'));
      await tester.pumpAndSettle();
      expect(find.text('Enregistrer sans envoyer'), findsNothing);
      await tester.tap(find.text('Enregistrer l’achat'));
      await tester.pumpAndSettle();
      final body = repo.purchaseBodies.single;
      expect(body['receive'], true);
      expect(body['payment'], {'amount': 2000, 'method': 'wave'});
      expect(body['expectedDate'], isNull);
      expect(find.text('Achat enregistré : le stock est à jour'), findsOneWidget);
    });

    testWidgets('depuis le stock bas : produits pré-remplis, scan, brouillon', (tester) async {
      phoneSize(tester);
      final (_, repo) = await pumpSama(
        tester,
        location: '/purchases/new?low=1&supplierId=s1',
        overrides: [barcodeScannerProvider.overrideWithValue((_) async => '6001234567891')],
      );
      expect(textMatching(r'^8 × 3 000 F = 24 000 F$'), findsOneWidget); // Parfum : 2 en stock, seuil 5
      expect(textMatching(r'^7 × 2 600 F = 18 200 F$'), findsOneWidget); // Huile : 3 en stock
      await tester.tap(find.text('Scanner'));
      await tester.pumpAndSettle();
      expect(find.text('Savon noir'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Enregistrer sans envoyer'), 200, scrollable: mainScroll);
      await tester.tap(find.text('Enregistrer sans envoyer'));
      await tester.pumpAndSettle();
      final body = repo.purchaseBodies.single;
      expect(body['draft'], true);
      expect((body['lines'] as List).map((l) => (l as Map)['productId']), ['p6', 'p3', 'p2']);
    });

    testWidgets('bon commandé : réception partielle avec prix corrigé et paiement au livreur', (tester) async {
      phoneSize(tester);
      final (_, repo) = await pumpSama(tester, location: '/purchases/po1');
      expect(find.text('Livrer à la boutique de Sandaga'), findsOneWidget);
      expect(textMatching(r'^24 × 2 000 F · reçu 0/24$'), findsOneWidget);
      await tester.tap(find.text('Marchandise arrivée'));
      await tester.pumpAndSettle();
      expect(textMatching(r'Valider la réception · 88 000 F$'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('rq_l12')), '30');
      await tester.enterText(find.byKey(const Key('rc_l12')), '850');
      await tester.enterText(find.byKey(const Key('receivePaid')), '20000');
      await tester.pumpAndSettle();
      expect(textMatching(r'Valider la réception · 73 500 F$'), findsOneWidget);
      await tester.tap(textMatching(r'^Valider la réception'));
      await tester.pumpAndSettle();
      final (id, lines, _, payment) = repo.receptions.single;
      expect(id, 'po1');
      expect(lines, [(lineId: 'l11', quantity: 24.0, unitCost: 2000), (lineId: 'l12', quantity: 30.0, unitCost: 850)]);
      expect(payment, (amount: 20000, method: PayMethod.cash));
      expect(find.text('Marchandise reçue : le stock est à jour'), findsOneWidget);
    });

    testWidgets('réception : quantité supérieure au reste refusée', (tester) async {
      phoneSize(tester);
      final (_, repo) = await pumpSama(tester, location: '/purchases/po2');
      expect(find.text('Marchandise reçue · Premier carton'), findsOneWidget);
      await tester.tap(find.text('Marchandise arrivée'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('rq_l21')), '11');
      await tester.tap(textMatching(r'^Valider la réception'));
      await tester.pumpAndSettle();
      expect(find.text('« Crème éclaircissante bio » : 10 au maximum restent à recevoir'), findsOneWidget);
      expect(repo.receptions, isEmpty);
    });

    testWidgets('paiement d’un bon reçu en partie', (tester) async {
      phoneSize(tester);
      final (_, repo) = await pumpSama(tester, location: '/purchases/po2');
      await tester.tap(find.text('Payer'));
      await tester.pumpAndSettle();
      expect(textMatching(r'^Reste à payer sur BC-2026-0005 : 20 000 F$'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('payAmount')), '25000');
      await tester.tap(find.text('Enregistrer le paiement'));
      await tester.pumpAndSettle();
      expect(repo.purchasePayments, isEmpty);
      await tester.enterText(find.byKey(const Key('payAmount')), '15000');
      await tester.tap(find.text('Orange Money'));
      await tester.tap(find.text('Enregistrer le paiement'));
      await tester.pumpAndSettle();
      expect(repo.purchasePayments, [('po2', 15000, PayMethod.orangeMoney)]);
    });

    testWidgets('brouillon : passer la commande, envoyer au fournisseur', (tester) async {
      phoneSize(tester);
      final actions = RecordingActions();
      final (c, repo) = await pumpSama(
        tester,
        location: '/purchases/po1',
        overrides: [receiptActionsProvider.overrideWithValue(actions)],
      );
      await tester.tap(find.byTooltip('Plus d’actions'));
      await tester.pumpAndSettle();
      expect(find.text('Modifier'), findsOneWidget);
      await tester.tap(find.text('Envoyer au fournisseur'));
      await tester.pumpAndSettle();
      expect(actions.whatsApp!.path, '/221773004050');
      expect(actions.whatsApp!.queryParameters['text'], contains('BC-2026-0007'));

      routerOf(c).go('/purchases/po4');
      await tester.pumpAndSettle();
      expect(find.text('Marchandise arrivée'), findsNothing);
      await tester.tap(find.text('Passer la commande'));
      await tester.pumpAndSettle();
      expect(repo.confirmed, ['po4']);
    });

    testWidgets('fournisseur : dette, paiement global, commander', (tester) async {
      phoneSize(tester);
      final (c, repo) = await pumpSama(tester, location: '/suppliers/s1');
      expect(textMatching(r'^22 500 F$'), findsOneWidget);
      expect(find.text('Livre le mardi et le vendredi'), findsOneWidget);
      await tester.tap(find.text('Payer'));
      await tester.pumpAndSettle();
      expect(textMatching(r'réparti sur les bons les plus anciens$'), findsOneWidget);
      await tester.tap(find.text('Enregistrer le paiement'));
      await tester.pumpAndSettle();
      expect(repo.supplierPayments, [('s1', 22500, PayMethod.cash)]);

      await tester.tap(find.text('Commander'));
      await tester.pumpAndSettle();
      expect(routerOf(c).state.uri.toString(), '/purchases/new?supplierId=s1');
    });

    testWidgets('caissier : pas d’accès aux achats (prix d’achat, dettes fournisseurs)', (tester) async {
      phoneSize(tester);
      await pumpSama(
        tester,
        location: '/purchases/po2',
        overrides: [currentBusinessProvider.overrideWith((ref) async => cashierBusiness)],
      );
      expect(find.text('Accès réservé'), findsOneWidget);
      expect(find.text('BC-2026-0005'), findsNothing);
    });

    testWidgets('caissier : accueil sans Achats ni Rapports, stock sans prix d’achat', (tester) async {
      phoneSize(tester);
      await pumpSama(tester, overrides: [currentBusinessProvider.overrideWith((ref) async => cashierBusiness)]);
      expect(find.text('Ventes'), findsWidgets);
      expect(find.text('Achats'), findsNothing);
      expect(find.text('Rapports'), findsNothing);
      await tester.tap(find.text('Plus'));
      await tester.pumpAndSettle();
      expect(find.text('Achats'), findsNothing);
      expect(find.text('Équipe'), findsNothing);
      expect(find.text('Documents'), findsNothing);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Stock').last);
      await tester.pumpAndSettle();
      expect(find.text('Votre stock vaut'), findsNothing);
      expect(find.textContaining('marge'), findsNothing);
    });

    testWidgets('nouveau fournisseur : pas de plafond de crédit', (tester) async {
      phoneSize(tester);
      final (c, repo) = await pumpSama(tester, location: '/suppliers/new');
      expect(find.text('Crédit maximum'), findsNothing);
      await tester.enterText(find.byKey(const Key('cName')), 'Cosmétiques Thiès');
      await tester.enterText(find.byKey(const Key('cPhone')), '77 555 44 33');
      await tester.tap(find.text('Ajouter le fournisseur'));
      await tester.pumpAndSettle();
      expect(repo.savedTypes, ['supplier']);
      expect(repo.savedCustomers.single.$2.containsKey('creditLimit'), isFalse);
      expect(routerOf(c).state.uri.toString(), '/suppliers/new-customer'); // fiche du fournisseur créé
    });

    testWidgets('stock bas : bouton « Commander »', (tester) async {
      phoneSize(tester);
      final (c, _) = await pumpSama(tester, location: '/stock?low=1');
      await tester.tap(find.text('Commander les produits en stock bas'));
      await tester.pumpAndSettle();
      expect(routerOf(c).state.uri.toString(), '/purchases/new?low=1');
    });
  });
}
