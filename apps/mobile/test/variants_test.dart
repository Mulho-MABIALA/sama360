import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/models.dart';
import 'package:sama360/features/sales/cart.dart';

import 'helpers.dart';

const _tshirt = Product(
  id: 'ts',
  name: 'T-shirt col V',
  price: 5000,
  cost: 2500,
  variantAxes: [
    VariantAxis('Couleur', ['Noir', 'Blanc']),
    VariantAxis('Taille', ['M', 'L']),
  ],
);

Product _v(String id, String color, String size, {int price = 5000}) => Product(
  id: id,
  name: 'T-shirt col V · $color · $size',
  price: price,
  cost: 2500,
  parentId: 'ts',
  options: {'Couleur': color, 'Taille': size},
);

StockItem _s(Product p, double q) =>
    StockItem(productId: p.id, name: p.name, price: p.price, cost: p.cost, threshold: 2, onHand: q, low: q <= 2);

FakeRepo _repo() {
  final vs = [
    _v('ts-nm', 'Noir', 'M'),
    _v('ts-nl', 'Noir', 'L', price: 5500),
    _v('ts-bm', 'Blanc', 'M'),
    _v('ts-bl', 'Blanc', 'L'),
  ];
  return FakeRepo()
    ..extraProducts = [_tshirt, ...vs]
    ..extraStock = [_s(vs[0], 4), _s(vs[1], 1), _s(vs[2], 0), _s(vs[3], 6)];
}

void main() {
  setUpAll(() async {
    await loadTestFonts();
    await initializeDateFormatting('fr');
  });

  testWidgets('caisse : un modèle, une seule carte ; on choisit la couleur et la taille', (tester) async {
    phoneSize(tester);
    final (c, _) = await pumpSama(tester, location: '/pos', repo: _repo());
    expect(find.text('Rechercher parmi 7 produits'), findsOneWidget); // les variantes ne comptent pas
    // Une carte pour le modèle, pas une par variante ; stock additionné, prix « dès »
    await tester.scrollUntilVisible(find.text('T-shirt col V'), 200, scrollable: find.byType(Scrollable).last);
    expect(find.text('T-shirt col V'), findsOneWidget);
    expect(find.text('T-shirt col V · Noir · M'), findsNothing);
    expect(find.textContaining(RegExp(r'dès 5.000 F'), findRichText: true), findsOneWidget);
    expect(find.text('En stock : 11'), findsOneWidget);

    // La carte passe au-dessus du panier en bas de l'écran
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -200));
    await tester.pumpAndSettle();
    await tester.tap(find.text('T-shirt col V'));
    await tester.pumpAndSettle();
    expect(find.text('Choisissez couleur et taille'), findsOneWidget);
    await tester.tap(find.byKey(const Key('opt_Couleur_Noir')));
    await tester.tap(find.byKey(const Key('opt_Taille_L')));
    await tester.pumpAndSettle();
    expect(find.text('En stock : 1'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^Ajouter · 5.500 F$')), findsOneWidget);
    await tester.tap(find.byKey(const Key('variant_add')));
    await tester.pumpAndSettle();

    final cart = c.read(cartProvider);
    expect(cart.lines.values.single.product.id, 'ts-nl');
    expect(cart.lines.values.single.product.name, 'T-shirt col V · Noir · L');
    expect(cart.total, 5500);
  });

  testWidgets('caisse : la recherche trouve un modèle par sa variante', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/pos', repo: _repo());
    await tester.enterText(find.byType(TextField).first, 'blanc');
    await tester.pumpAndSettle();
    expect(find.text('T-shirt col V'), findsOneWidget);
  });

  testWidgets('variantes : listes toutes prêtes, combinaisons, prix et stock de départ', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo();
    await pumpSama(tester, location: '/products/${demoProducts[0].id}/variants', repo: repo);
    await tester.pumpAndSettle();
    expect(find.text('Tailles, couleurs…'), findsOneWidget);
    // Taille : S à XXL, puis une couleur ajoutée à la main
    await tester.tap(find.byKey(const Key('preset_Taille_Tailles S à XXL')));
    await tester.pumpAndSettle();
    expect(find.text('Enregistrer 5 variantes'), findsOneWidget);
    await tester.tap(find.byKey(const Key('axis_new')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('axis_name_1')), 'Couleur');
    await tester.enterText(find.byKey(const Key('axis_values_1')), 'Noir, Rouge');
    await tester.tap(find.byKey(const Key('axis_add_1')), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('Enregistrer 10 variantes'), findsOneWidget);

    // Une combinaison retirée, un prix changé, du stock pour une autre
    await tester.scrollUntilVisible(
      find.byKey(const Key('variant_on_XXL · Rouge')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('variant_on_XXL · Rouge')));
    await tester.pumpAndSettle();
    expect(find.text('Enregistrer 9 variantes'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('variant_price_XL · Noir')),
      -300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(find.byKey(const Key('variant_price_XL · Noir')), '4000');
    await tester.enterText(find.byKey(const Key('variant_qty_XL · Noir')), '6');
    await tester.tap(find.byKey(const Key('variants_save')));
    await tester.pumpAndSettle();

    final (id, axes, vs) = repo.variantCalls.single;
    expect(id, demoProducts[0].id);
    expect(axes.map((a) => a.name), ['Taille', 'Couleur']);
    expect(axes.first.values, ['S', 'M', 'L', 'XL', 'XXL']);
    expect(vs, hasLength(9));
    final xlNoir = vs.firstWhere((v) => v.options['Taille'] == 'XL' && v.options['Couleur'] == 'Noir');
    expect(xlNoir.price, 4000);
    expect(vs.where((v) => v.options['Taille'] == 'XXL' && v.options['Couleur'] == 'Rouge'), isEmpty);
    // Stock de départ posé sur la nouvelle variante
    final created = vs.indexOf(xlNoir);
    expect(repo.stockAdds.single.$1, '${demoProducts[0].id}-v$created');
    expect(repo.stockAdds.single.$2, 6);
  });

  testWidgets('fiche produit : « Tailles, couleurs… » ouvre les variantes', (tester) async {
    phoneSize(tester);
    final (c, _) = await pumpSama(tester, location: '/products/ts', repo: _repo());
    await tester.pumpAndSettle();
    expect(find.text('Variantes · 4'), findsOneWidget);
    expect(find.text('Couleur : Noir, Blanc · Taille : M, L'), findsOneWidget);
    await tester.tap(find.byKey(const Key('pVariants')));
    await tester.pumpAndSettle();
    expect(routerOf(c).state.uri.path, '/products/ts/variants');
  });

  testWidgets('fiche d’une variante : nom verrouillé, lien vers les variantes du modèle', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/products/ts-nm', repo: _repo());
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const Key('pName'))).enabled, isFalse);
    expect(find.textContaining('Variante « Noir · M »'), findsOneWidget);
    expect(find.byKey(const Key('pVariants')), findsNothing);
  });
}
