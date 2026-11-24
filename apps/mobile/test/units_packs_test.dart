import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/models.dart';
import 'package:sama360/features/sales/cart.dart';

import 'helpers.dart';

const _cable = Product(id: 'cable', name: 'Câble 2,5 mm²', price: 600, cost: 400, unit: 'mètre');
const _vis = Product(
  id: 'vis',
  name: 'Vis 6 mm',
  price: 25,
  cost: 10,
  packName: 'Boîte',
  packSize: 100,
  wholesalePrice: 20,
  wholesaleMinQty: 100,
);

Finder textMatching(String pattern) => find.byWidgetPredicate(
  (w) => w is Text && w.data != null && RegExp(pattern).hasMatch(w.data!.replaceAll(RegExp(r'[\u00a0\u202f]'), ' ')),
);

FakeRepo _repo() => FakeRepo()..extraProducts = [_cable, _vis];

Future<void> _openCard(WidgetTester tester, String name) async {
  await tester.enterText(find.byType(TextField).first, name.split(' ').first);
  await tester.pumpAndSettle();
  await tester.tap(find.text(name));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await loadTestFonts();
    await initializeDateFormatting('fr');
  });

  testWidgets('caisse : au mètre, on tape 2,5', (tester) async {
    phoneSize(tester);
    final (c, _) = await pumpSama(tester, location: '/pos', repo: _repo());
    await _openCard(tester, 'Câble 2,5 mm²');
    expect(find.byKey(const Key('qty_input')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('qty_input')), '2,5');
    await tester.pump();
    expect(find.textContaining(RegExp(r'^Valider · 1.500 F$')), findsOneWidget);
    await tester.tap(find.byKey(const Key('qty_ok')));
    await tester.pumpAndSettle();
    final cart = c.read(cartProvider);
    expect(cart.quantityOf('cable'), 2.5);
    expect(cart.total, 1500);
  });

  testWidgets('caisse : 1 boîte de 100 au prix du conditionnement', (tester) async {
    phoneSize(tester);
    final (c, _) = await pumpSama(tester, location: '/pos', repo: _repo());
    await _openCard(tester, 'Vis 6 mm');
    expect(find.text('Par boîte (100)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('qty_pack_1')));
    await tester.pump();
    expect(find.text('= 1 boîte de 100'), findsOneWidget);
    await tester.tap(find.byKey(const Key('qty_ok')));
    await tester.pumpAndSettle();
    final cart = c.read(cartProvider);
    expect(cart.quantityOf('vis'), 100);
    expect(cart.total, 2000); // prix de gros : 20 F la vis dès 100
  });

  testWidgets('panier : toucher une ligne pour taper la quantité, ou la retirer', (tester) async {
    phoneSize(tester);
    final (c, _) = await pumpSama(tester, location: '/pos', repo: _repo());
    c.read(cartProvider.notifier).add(demoProducts[0]);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cart_lines_open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('cart_qty_${demoProducts[0].id}')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('qty_input')), '12');
    await tester.pump();
    await tester.tap(find.byKey(const Key('qty_ok')));
    await tester.pumpAndSettle();
    expect(c.read(cartProvider).quantityOf(demoProducts[0].id), 12);
    await tester.tap(find.byKey(Key('cart_qty_${demoProducts[0].id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('qty_remove')));
    await tester.pumpAndSettle();
    expect(c.read(cartProvider).isEmpty, isTrue);
  });

  testWidgets('fiche produit : vendu au carton, le prix du carton devient le prix de gros', (tester) async {
    phoneSize(tester);
    final (_, repo) = await pumpSama(tester, location: '/products/new');
    await tester.enterText(find.byKey(const Key('pName')), 'Eau minérale 1,5 L');
    await tester.enterText(find.byKey(const Key('pPrice')), '400');
    await tester.tap(find.byKey(const Key('pMore')));
    await tester.pumpAndSettle();
    final list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.byKey(const Key('pPack')), 200, scrollable: list);
    await tester.drag(
      find.ancestor(of: find.byKey(const Key('pPack')), matching: find.byType(Scrollable)).first,
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    tester.widget<SwitchListTile>(find.byKey(const Key('pPack'))).onChanged!(true);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('pPackSize')), '6');
    await tester.enterText(find.byKey(const Key('pPackPrice')), '2100');
    await tester.pump();
    expect(find.textContaining(RegExp(r'^Soit 350 F la pièce$')), findsOneWidget);
    await tester.tap(find.text('Ajouter le produit'));
    await tester.pumpAndSettle();
    final d = repo.savedDrafts.single.$2;
    expect((d.packName, d.packSize, d.wholesalePrice, d.wholesaleMinQty), ('Carton', 6.0, 350, 6.0));
  });

  testWidgets('achat : saisi au carton, enregistré à l’unité', (tester) async {
    phoneSize(tester);
    final (_, repo) = await pumpSama(tester, location: '/purchases/new?supplierId=s1', repo: _repo());
    await tester.tap(find.text('Produit'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'vis');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Vis 6 mm'));
    await tester.pumpAndSettle();
    await tester.tap(textMatching(r'^1 × 10 F = 10 F$'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plByPack')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('plQty')), '3');
    await tester.enterText(find.byKey(const Key('plCost')), '900');
    await tester.pump();
    expect(find.textContaining('300 pièces en stock'), findsOneWidget);
    await tester.tap(find.text('Valider'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Passer la commande'));
    await tester.pumpAndSettle();
    expect(repo.purchaseBodies.single['lines'], [
      {'productId': 'vis', 'quantity': 300.0, 'unitCost': 9},
    ]);
  });

  testWidgets('création : quincaillerie, habits, alimentation proposés', (tester) async {
    phoneSize(tester);
    final (_, repo) = await pumpSama(tester, location: '/business');
    await tester.tap(find.text('Créer une entreprise'));
    await tester.pumpAndSettle();
    expect(find.text('Habits & chaussures'), findsOneWidget);
    expect(find.text('Alimentation'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('businessName')), 'Quincaillerie Fall');
    await tester.tap(find.text('Quincaillerie'));
    await tester.pump();
    await tapCentered(tester, find.text("Créer l'entreprise"));
    await tester.pumpAndSettle();
    expect(repo.createdBusinesses.single, containsPair('category', 'quincaillerie'));
    expect(repo.createdBusinesses.single, containsPair('focus', 'products'));
  });
}
