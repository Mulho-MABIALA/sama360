import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/models.dart';
import 'package:sama360/core/widgets.dart';
import 'package:sama360/features/catalog/barcode_scanner.dart';
import 'package:sama360/features/sales/cart.dart';

import 'helpers.dart';

void main() {
  setUpAll(loadTestFonts);

  group('prix de gros', () {
    const savon = Product(id: 'p', name: 'Savon', price: 1500, cost: 800, wholesalePrice: 1200, wholesaleMinQty: 10);
    test('appliqué dès la quantité minimale, comme le serveur', () {
      expect(savon.unitPriceFor(9), 1500);
      expect(savon.unitPriceFor(10), 1200);
      expect(const Product(id: 'x', name: 'x', price: 500, cost: 0).unitPriceFor(100), 500);
    });
    test('ligne de panier : total au prix de gros', () {
      expect(const CartLine(savon, 12).total, 14400);
      expect(const CartLine(savon, 12).wholesale, isTrue);
      expect(const CartLine(savon, 2).total, 3000);
    });
    test('fiche envoyée à l’API', () {
      const d = ProductDraft(
        name: ' Riz 5 kg ',
        price: 5000,
        cost: 4000,
        unit: 'sac',
        barcode: ' 611 ',
        sku: '',
        isService: false,
        wholesalePrice: 4600,
        wholesaleMinQty: 10,
      );
      expect(d.toJson(), {
        'type': 'product',
        'name': 'Riz 5 kg',
        'price': 5000,
        'cost': 4000,
        'categoryId': null,
        'unit': 'sac',
        'barcode': '611',
        'sku': null,
        'trackStock': true,
        'lowStockThreshold': 5,
        'wholesalePrice': 4600,
        'wholesaleMinQty': 10.0,
      });
      expect(const ProductDraft(name: 'Coupe', price: 2000, isService: true).toJson()['trackStock'], isFalse);
    });
  });

  testWidgets('fiche produit : modifier prix, code-barres scanné, prix de gros, marge', (tester) async {
    phoneSize(tester);
    final (_, repo) = await pumpSama(
      tester,
      location: '/products/p1',
      overrides: [barcodeScannerProvider.overrideWithValue((_) async => '6009876543210')],
    );
    expect(find.text('Fiche produit'), findsOneWidget);
    expect(find.textContaining('Bénéfice : 1'), findsOneWidget); // 3 500 − 2 000

    await tester.enterText(find.byKey(const Key('pPrice')), '4000');
    await tester.ensureVisible(find.byTooltip('Scanner le code-barres'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Scanner le code-barres'));
    await tester.pumpAndSettle();
    expect(find.text('6009876543210'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('Prix de gros'), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Prix de gros'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('pWPrice')), '4500'); // trop cher
    await tester.enterText(find.byKey(const Key('pWQty')), '6');
    await tester.tap(find.text('Enregistrer la fiche'));
    await tester.pumpAndSettle();
    expect(find.text('Doit être inférieur au prix normal'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('pWPrice')), '3500');
    await tester.tap(find.text('Enregistrer la fiche'));
    await tester.pumpAndSettle();
    final (id, d) = repo.savedDrafts.single;
    expect(id, 'p1');
    expect((d.price, d.barcode, d.wholesalePrice, d.wholesaleMinQty), (4000, '6009876543210', 3500, 6.0));
  });

  testWidgets('code-barres déjà utilisé : message sous le champ', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/products/new?barcode=0000000000000');
    await tester.enterText(find.byKey(const Key('pName')), 'Savon doublon');
    await tester.enterText(find.byKey(const Key('pPrice')), '1000');
    await tester.tap(find.text('Ajouter le produit'));
    await tester.pumpAndSettle();
    expect(find.text('Ce code-barres est déjà utilisé par « Savon noir »'), findsOneWidget);
  });

  testWidgets('supprimer un produit', (tester) async {
    phoneSize(tester);
    final (_, repo) = await pumpSama(tester, location: '/products/p6');
    await tester.tap(find.byTooltip('Supprimer le produit'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Supprimer')));
    await tester.pumpAndSettle();
    expect(repo.deletedProducts, ['p6']);
  });

  testWidgets('caisse : scan en continu → panier ; code inconnu → créer la fiche à la fin', (tester) async {
    phoneSize(tester);
    final feedbacks = <ScanFeedback>[];
    await pumpSama(
      tester,
      location: '/pos',
      overrides: [
        continuousScannerProvider.overrideWithValue((_, onCode) async {
          for (final code in ['6001234567891', '6001234567891', '999']) {
            feedbacks.add(await onCode(code));
          }
          return feedbacks.where((f) => f.ok).length;
        }),
      ],
    );
    await tester.tap(find.byTooltip('Scanner un code-barres'));
    await tester.pumpAndSettle();
    expect(feedbacks.map((f) => (f.message, f.ok)).toList(), [
      ('Savon noir ajouté', true),
      ('Savon noir ajouté · 2 au panier', true),
      ('Code inconnu : 999', false),
    ]);
    expect(find.text('Produit inconnu'), findsOneWidget);
    await tester.tap(find.text('Créer la fiche'));
    await tester.pumpAndSettle();
    expect(find.text('Nouveau produit'), findsOneWidget);
    expect(find.text('999'), findsOneWidget);
  });

  testWidgets('accueil : scanner un article → prix, stock, vendre', (tester) async {
    phoneSize(tester);
    final (c, _) = await pumpSama(
      tester,
      overrides: [barcodeScannerProvider.overrideWithValue((_) async => '6001234567891')],
    );
    await tester.tap(find.byTooltip('Scanner un article'));
    await tester.pumpAndSettle();
    expect(find.text('Savon noir'), findsOneWidget);
    expect(find.text('Voir la fiche'), findsOneWidget);
    await tester.tap(find.widgetWithText(ConfirmButton, 'Vendre'));
    await tester.pumpAndSettle();
    expect(routerOf(c).state.uri.path, '/pos');
    expect(c.read(cartProvider).lines.keys, ['p2']);
  });

  testWidgets('accueil : code inconnu → créer la fiche', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, overrides: [barcodeScannerProvider.overrideWithValue((_) async => '42')]);
    await tester.tap(find.byTooltip('Scanner un article'));
    await tester.pumpAndSettle();
    expect(find.text('Produit inconnu'), findsOneWidget);
    await tester.tap(find.text('Fermer'));
    await tester.pumpAndSettle();
    expect(find.text('Produit inconnu'), findsNothing);
  });

  testWidgets('stock : scanner un article ouvre son entrée de stock', (tester) async {
    phoneSize(tester);
    await pumpSama(
      tester,
      location: '/stock',
      overrides: [barcodeScannerProvider.overrideWithValue((_) async => '6001234567891')],
    );
    await tester.tap(find.byTooltip('Scanner un article'));
    await tester.pumpAndSettle();
    expect(find.text('Entrée de stock'), findsOneWidget);
  });

  testWidgets('bandeau du scanner continu', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              ScanFeedbackBanner(feedback: ScanFeedback('Savon noir ajouté')),
              ScanFeedbackBanner(feedback: ScanFeedback('Code inconnu : 42', ok: false)),
            ],
          ),
        ),
      ),
    );
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    expect(find.byIcon(Icons.help_rounded), findsOneWidget);
  });

  testWidgets('catégories : liste avec nombre de produits, ajout, renommage, suppression', (tester) async {
    phoneSize(tester);
    final (_, repo) = await pumpSama(tester, location: '/categories');
    expect(find.text('3 produits'), findsNWidgets(2));

    await tester.tap(find.text('Ajouter'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('categoryName')), 'Épicerie');
    await tester.tap(find.text('Valider'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Renommer Soins'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('categoryName')), 'Soins du corps');
    await tester.tap(find.text('Valider'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Supprimer Cheveux & parfums'));
    await tester.pumpAndSettle();
    expect(find.textContaining('restent dans le catalogue'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Supprimer')));
    await tester.pumpAndSettle();
    expect(repo.categoryOps, ['create Épicerie', 'rename c1 Soins du corps', 'delete c2']);
  });
}
