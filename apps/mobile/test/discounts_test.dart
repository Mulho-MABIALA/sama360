import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/discount.dart';
import 'package:sama360/core/models.dart';
import 'package:sama360/features/sales/cart.dart';

import 'helpers.dart';
import 'team_test.dart' show CashierRepo;

void main() {
  setUpAll(loadTestFonts);

  test('remise en % ou en F, jamais plus que le montant', () {
    expect(const Discount.percent(10).of(100000), 10000);
    expect(const Discount.amount(5000).of(100000), 5000);
    expect(const Discount.amount(5000).of(3000), 3000);
    expect(const Discount.percent(15).of(3333), 500);
    expect(Discount.none.of(1000), 0);
  });

  test('panier : remise sur un article puis sur toute la vente', () {
    final p = demoProducts[0]; // 3 500 F
    final s = CartState(
      lines: {p.id: CartLine(p, 2, discount: const Discount.percent(10))}, // 7 000 − 700
      saleDiscount: const Discount.amount(300),
    );
    expect((s.grossTotal, s.subtotal, s.saleDiscountAmount, s.total, s.discountTotal), (7000, 6300, 300, 6000, 1000));
  });

  testWidgets('caisse : remise de 10 % sur un article et 300 F sur la vente, envoyées avec la vente', (tester) async {
    phoneSize(tester);
    final (c, repo) = await pumpSama(tester, location: '/pos');
    final cart = c.read(cartProvider.notifier);
    cart.add(demoProducts[0]);
    cart.add(demoProducts[0]);
    await tester.pumpAndSettle();

    // Remise sur la vente
    await tester.tap(find.byKey(const Key('sale_discount')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('En francs'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('discount_value')), '300');
    await tester.pump();
    await tester.tap(find.byKey(const Key('discount_apply')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sale_discount_chip')), findsOneWidget);
    expect(c.read(cartProvider).total, 6700);

    // Remise sur l'article (dans la liste du panier)
    await tester.tap(find.byKey(const Key('cart_lines_open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cart_disc_p1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('discount_quick_10')));
    await tester.pump();
    expect(find.byKey(const Key('discount_preview')), findsOneWidget);
    await tester.tap(find.byKey(const Key('discount_apply')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('cart_disc_label_p1')), findsOneWidget);
    expect(c.read(cartProvider).total, 6000);
    Navigator.of(tester.element(find.byKey(const Key('cart_lines'))), rootNavigator: true).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('Encaisser'));
    await tester.pumpAndSettle();
    final body = repo.sales.last;
    expect(body['discount'], 300);
    expect((body['items'] as List).single['discount'], 700);
    expect((body['payments'] as List).single['amount'], 6000);
  });

  testWidgets('caisse : le vendeur ne peut pas faire de remise', (tester) async {
    phoneSize(tester);
    final (c, _) = await pumpSama(tester, location: '/pos', repo: CashierRepo());
    c.read(cartProvider.notifier).add(demoProducts[0]);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sale_discount')), findsNothing);
  });

  testWidgets('stock : les produits sans prix d’achat sont signalés et filtrés', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/stock', repo: _NoCostRepo());
    expect(find.byKey(const Key('no_cost_banner')), findsOneWidget);
    expect(find.textContaining('1 produit sans prix d’achat'), findsOneWidget);
    await tester.tap(find.byKey(const Key('no_cost_banner')));
    await tester.pumpAndSettle();
    expect(find.text('Parfum Thiouraye'), findsOneWidget);
    expect(find.text('Huile de coco 500 ml'), findsNothing);
  });

  testWidgets('devis : remise sur une ligne et 10 % sur le total', (tester) async {
    phoneSize(tester);
    final (_, repo) = await pumpSama(tester, location: '/invoices/new?kind=quote');
    await tester.tap(find.text('Choisir le client'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hôtel Teranga'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ligne libre'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('lineName')), 'Coffret parfum');
    await tester.enterText(find.byKey(const Key('lineQty')), '4');
    await tester.enterText(find.byKey(const Key('linePrice')), '25000');
    await tester.pump();
    await tester.tap(find.byKey(const Key('lineDiscount')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('En francs'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('discount_value')), '5000');
    await tester.pump();
    await tester.tap(find.byKey(const Key('discount_apply')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Valider la ligne'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Remise 5'), findsOneWidget);

    // 10 % de 95 000 F
    await tester.tap(find.byKey(const Key('docDiscount')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('discount_quick_10')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('discount_apply')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('docDiscountsTotal')), findsOneWidget);
    expect(find.textContaining(RegExp(r'^85.500 F$')), findsOneWidget);

    await tester.tap(find.text('Créer le devis'));
    await tester.pumpAndSettle();
    final body = repo.docBodies.values.single;
    expect(body['discount'], 9500);
    expect((body['lines'] as List).single, containsPair('discount', 5000));
  });
}

class _NoCostRepo extends FakeRepo {
  @override
  Future<StockOverview> stock({bool lowOnly = false}) async {
    final s = await super.stock(lowOnly: lowOnly);
    final first = s.items.first;
    return StockOverview(
      items: [
        StockItem(
          productId: first.productId,
          name: first.name,
          price: first.price,
          cost: 0,
          threshold: first.threshold,
          onHand: first.onHand,
          low: first.low,
        ),
        ...s.items.skip(1),
      ],
      lowStock: s.lowStock,
      stockValue: s.stockValue,
    );
  }
}
