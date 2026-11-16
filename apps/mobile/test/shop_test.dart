import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/models.dart';
import 'package:sama360/core/providers.dart';
import 'package:sama360/features/sales/receipt_screen.dart';
import 'package:sama360/features/shop/shop_order_screen.dart';
import 'package:sama360/features/shop/shop_screen.dart';

import 'helpers.dart';
import 'receipt_test.dart' show RecordingActions;

Finder textMatching(String pattern) => find.byWidgetPredicate(
  (w) => w is Text && w.data != null && RegExp(pattern).hasMatch(w.data!.replaceAll(RegExp(r'[  ]'), ' ')),
);

Finder get mainScroll => find.byType(Scrollable).first;

void main() {
  setUpAll(() async {
    await initializeDateFormatting('fr');
    await loadTestFonts();
  });

  group('logique', () {
    test('adresse de la boutique', () {
      expect(shopUrl('https://api.sama360.com/', '/s/awa-beaute'), 'https://api.sama360.com/s/awa-beaute');
      expect(shopUrl('http://10.0.2.2:3000', '/s/x'), 'http://10.0.2.2:3000/s/x');
      expect(shopDisplayName(const ShopSettings(title: '  '), 'Awa Beauté'), 'Awa Beauté');
      expect(shopDisplayName(const ShopSettings(title: 'Awa en ligne'), 'Awa Beauté'), 'Awa en ligne');
    });

    test('étapes proposées et messages au client', () {
      final [o1, o2, o3] = FakeRepo.demoShopOrders;
      expect(o1.nextSteps, [ShopOrderStatus.confirmed]);
      expect(o2.nextSteps, [ShopOrderStatus.ready]);
      expect(o3.nextSteps, isEmpty);
      final ready = ShopOrder.fromJson({
        'id': 'x',
        'number': 'CMD-1',
        'status': 'ready',
        'customerName': 'Aïssatou Ba',
        'customerPhone': '+221778889900',
        'mode': 'pickup',
        'total': '7000',
        'createdAt': '2026-11-16T10:00:00Z',
        'lines': [
          {'id': 'l', 'productId': 'p', 'name': 'Savon', 'quantity': '2', 'unitPrice': 3500, 'total': 7000},
        ],
      });
      expect(ready.nextSteps, [ShopOrderStatus.completed]); // retrait : pas d'étape livraison
      expect(ready.lines.single.quantity, 2);
      String flat(String s) => s.replaceAll(RegExp(r'[  ]'), ' ');
      expect(
        flat(shopCustomerMessage(ready, 'Awa Beauté')),
        'Bonjour Aïssatou, votre commande CMD-1 est prête : vous pouvez passer la récupérer (7 000 F).',
      );
      expect(flat(shopCustomerMessage(o1, 'Awa Beauté')), contains('Nous vous appelons avant de livrer.'));
    });

    test('fiche produit : visibilité en ligne envoyée seulement si choisie', () {
      expect(const ProductDraft(name: 'A', price: 1, published: true).toJson()['published'], true);
      expect(const ProductDraft(name: 'A', price: 1).toJson().containsKey('published'), isFalse);
      expect(Product.fromJson({'id': 'p', 'name': 'A', 'price': 1, 'cost': 0, 'published': true}).published, isTrue);
    });
  });

  group('écrans', () {
    testWidgets('boutique ouverte : lien, partage, chiffres, commandes', (tester) async {
      phoneSize(tester);
      final actions = RecordingActions();
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
        return null;
      });
      final (c, repo) = await pumpSama(
        tester,
        location: '/shop',
        overrides: [receiptActionsProvider.overrideWithValue(actions)],
      );
      expect(find.text('Awa Beauté en ligne'), findsOneWidget);
      expect(textMatching(r'/s/awa-beaute$'), findsOneWidget);
      expect(find.text('4 produits en ligne sur 6'), findsOneWidget);
      expect(find.text('Ndèye Sarr'), findsOneWidget);
      expect(find.text('Aïssatou Ba'), findsOneWidget);
      expect(find.text('Fatou Ndiaye'), findsNothing); // livrée : pas « en cours »

      await tester.tap(find.text('Partager'));
      await tester.pumpAndSettle();
      expect(actions.whatsApp!.queryParameters['text'], startsWith('Découvrez Awa Beauté en ligne et commandez directement ici'));
      expect(actions.whatsApp!.queryParameters['text'], endsWith('/s/awa-beaute'));
      await tester.tap(find.text('Copier'));
      await tester.pumpAndSettle();
      expect(copied, endsWith('/s/awa-beaute'));

      await tester.scrollUntilVisible(find.text('Terminées'), 200, scrollable: mainScroll);
      await tester.tap(find.text('Terminées'));
      await tester.pumpAndSettle();
      expect(repo.shopQueries.last, ShopOrderFilter.done);
      expect(find.text('Fatou Ndiaye'), findsOneWidget);
      await tester.tap(find.text('Fatou Ndiaye'));
      await tester.pumpAndSettle();
      expect(routerOf(c).state.matchedLocation, '/shop/orders/so3');
    });

    testWidgets('boutique fermée : ouverture guidée, tous les produits mis en ligne', (tester) async {
      phoneSize(tester);
      final repo = FakeRepo()..shopEnabled = false;
      final (c, _) = await pumpSama(tester, location: '/shop', repo: repo);
      expect(find.text('Vendez aussi sur Internet'), findsOneWidget);
      await tester.tap(find.text('Ouvrir ma boutique'));
      await tester.pumpAndSettle();
      expect(find.text('Mettre tous mes produits en ligne'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(find.byKey(const Key('shopEnabled'))).value, isTrue);
      expect(tester.widget<TextField>(find.byKey(const Key('shopTitle'))).controller!.text, 'Awa Beauté');

      await tester.enterText(find.byKey(const Key('shopWhatsapp')), '77 12');
      await tester.tap(find.text('Mettre ma boutique en ligne'));
      await tester.pumpAndSettle();
      expect(find.text('9 chiffres, ex. 77 123 45 67'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('shopWhatsapp')), '77 111 22 33');
      await tester.enterText(find.byKey(const Key('shopDescription')), 'Cosmétiques naturels livrés à Dakar');
      await tester.scrollUntilVisible(find.byKey(const Key('shopFee')), 200, scrollable: mainScroll);
      await tester.enterText(find.byKey(const Key('shopFee')), '1500');
      await tester.tap(find.text('Mettre ma boutique en ligne'));
      await tester.pumpAndSettle();
      final s = repo.shopSettingsSaved.single;
      expect((s.enabled, s.whatsapp, s.deliveryFee, s.description), (
        true,
        '+221771112233',
        1500,
        'Cosmétiques naturels livrés à Dakar',
      ));
      expect(repo.publishCalls, [(null, true)]);
      expect(find.text('Votre boutique est en ligne !'), findsOneWidget);
      expect(routerOf(c).state.matchedLocation, '/shop');
    });

    testWidgets('produits en ligne : un par un ou tous', (tester) async {
      phoneSize(tester);
      final (_, repo) = await pumpSama(tester, location: '/shop/products');
      expect(find.text('0 produit sur 6 visible dans la boutique'), findsOneWidget);
      await tester.tap(find.byKey(const Key('pub_p2')));
      await tester.pumpAndSettle();
      expect(repo.publishCalls.last.$1, ['p2']);
      expect(repo.publishCalls.last.$2, isTrue);
      expect(find.text('1 produit sur 6 visible dans la boutique'), findsOneWidget);
      await tester.tap(find.text('Tout publier'));
      await tester.pumpAndSettle();
      expect(repo.publishCalls.last, (null, true));
      expect(find.text('6 produits sur 6 visibles dans la boutique'), findsOneWidget);
    });

    testWidgets('nouvelle commande : détails, message au client, confirmation', (tester) async {
      phoneSize(tester);
      final actions = RecordingActions();
      final (_, repo) = await pumpSama(
        tester,
        location: '/shop/orders/so1',
        overrides: [receiptActionsProvider.overrideWithValue(actions)],
      );
      expect(find.text('Livraison : Ouakam, près de la mosquée'), findsOneWidget);
      expect(textMatching(r'^3 × 5 000 F$'), findsOneWidget);
      expect(textMatching(r'^23 000 FCFA$'), findsOneWidget);
      await tester.tap(find.text('WhatsApp'));
      await tester.pumpAndSettle();
      expect(actions.whatsApp!.path, '/221765554433');
      expect(actions.whatsApp!.queryParameters['text'], contains('CMD-2026-0012 est bien confirmée'));

      await tester.tap(find.text('Confirmer la commande'));
      await tester.pumpAndSettle();
      expect(repo.shopStatusCalls.single.$2, ShopOrderStatus.confirmed);
      expect(find.text('Déjà livrée et encaissée'), findsNothing); // pas avant confirmation
    });

    testWidgets('retrait en boutique : encaissement partiel, le reste au carnet', (tester) async {
      phoneSize(tester);
      final (_, repo) = await pumpSama(tester, location: '/shop/orders/so2');
      expect(find.text('Retrait en boutique'), findsOneWidget);
      expect(find.text('Commande prête'), findsOneWidget);
      await tester.tap(find.text('Déjà retirée et encaissée'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('collectAmount')), '5000');
      await tester.pumpAndSettle();
      expect(textMatching(r'^Le reste \(2 000 FCFA\) va au carnet de crédit de Aïssatou$'), findsOneWidget);
      await tester.tap(find.text('Wave'));
      await tester.tap(find.text('Enregistrer la vente'));
      await tester.pumpAndSettle();
      final (id, status, _, payment) = repo.shopStatusCalls.single;
      expect((id, status, payment), ('so2', ShopOrderStatus.completed, (amount: 5000, method: PayMethod.wave)));
      expect(find.text('Vente enregistrée : stock et caisse à jour'), findsOneWidget);
    });

    testWidgets('annulation avec raison', (tester) async {
      phoneSize(tester);
      final (_, repo) = await pumpSama(tester, location: '/shop/orders/so1');
      await tester.tap(find.text('Annuler la commande'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('cancelReason')), 'Parfum épuisé');
      await tester.tap(find.text('Oui, annuler'));
      await tester.pumpAndSettle();
      expect(repo.shopStatusCalls.single, ('so1', ShopOrderStatus.cancelled, 'Parfum épuisé', null));
    });

    testWidgets('commande livrée : plus d’action, lien vers la vente', (tester) async {
      phoneSize(tester);
      final (c, _) = await pumpSama(tester, location: '/shop/orders/so3');
      expect(find.text('Annuler la commande'), findsNothing);
      await tester.tap(find.text('Voir la vente et le reçu'));
      await tester.pumpAndSettle();
      expect(routerOf(c).state.matchedLocation, '/sales/s1');
    });

    testWidgets('accueil : tuile Boutique active et bannière des nouvelles commandes', (tester) async {
      phoneSize(tester);
      final (c, _) = await pumpSama(
        tester,
        overrides: [
          currentBusinessProvider.overrideWith(
            (ref) async => const CurrentBusiness(
              id: 'b1',
              name: 'Awa Beauté',
              slug: 'awa-beaute',
              role: 'manager',
              permissions: ['sales:*', 'catalog:*', 'inventory:*', 'contacts:*', 'members:read'],
              modules: ['sales', 'inventory', 'shop'],
            ),
          ),
        ],
      );
      expect(find.text('1 nouvelle commande en ligne'), findsOneWidget);
      await tester.tap(find.text('1 nouvelle commande en ligne'));
      await tester.pumpAndSettle();
      expect(routerOf(c).state.matchedLocation, '/shop');
      expect(find.text('Bientôt'), findsNothing);
    });
  });
}
