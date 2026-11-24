import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/models.dart';
import 'package:sama360/core/repositories.dart';
import 'package:sama360/features/sales/cart.dart';
import 'package:sama360/features/sales/receipt.dart';

import 'helpers.dart';

const _thieb = Product(
  id: 'thieb',
  name: 'Thiéboudienne',
  price: 2500,
  cost: 1200,
  trackStock: false,
  extras: [ProductExtra('Œuf', 200), ProductExtra('Piment', 0)],
);
const _tel = Product(
  id: 'tel',
  name: 'Tecno Spark 20',
  price: 85000,
  cost: 70000,
  trackSerial: true,
  warrantyMonths: 12,
);

Future<void> _open(WidgetTester tester, String name) async {
  await tester.enterText(find.byType(TextField).first, name.substring(0, 4));
  await tester.pumpAndSettle();
  await tester.tap(find.text(name));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await loadTestFonts();
    await initializeDateFormatting('fr');
  });

  testWidgets('restaurant : suppléments choisis à la caisse, ajoutés au prix, envoyés à l’API', (tester) async {
    phoneSize(tester);
    final (c, _) = await pumpSama(tester, location: '/pos', repo: FakeRepo()..extraProducts = [_thieb]);
    await _open(tester, 'Thiéboudienne');
    await tester.tap(find.byKey(const Key('extra_Œuf')));
    await tester.tap(find.byKey(const Key('extras_more')));
    await tester.pump();
    expect(find.textContaining(RegExp(r'^Ajouter · 5.400 F$')), findsOneWidget);
    await tester.tap(find.byKey(const Key('extras_ok')));
    await tester.pumpAndSettle();
    // Le même plat sans supplément fait une autre ligne
    await _open(tester, 'Thiéboudienne');
    await tester.tap(find.byKey(const Key('extras_ok')));
    await tester.pumpAndSettle();
    final lines = c.read(cartProvider).lines.values.toList();
    expect(lines.map((l) => (l.name, l.quantity, l.total)), [
      ('Thiéboudienne + Œuf', 2.0, 5400),
      ('Thiéboudienne', 1.0, 2500),
    ]);
    expect(c.read(cartProvider).quantityOf('thieb'), 3);
  });

  test('corps de la vente : suppléments et IMEI par ligne', () {
    final body = SamaRepository.saleBody(
      id: 's',
      items: [(productId: 'thieb', quantity: 2), (productId: 'tel', quantity: 1)],
      payments: const [],
      details: {
        0: {
          'extras': ['Œuf'],
        },
        1: {
          'serials': ['356789012345678'],
        },
      },
    );
    expect(body['items'], [
      {
        'productId': 'thieb',
        'quantity': 2.0,
        'extras': ['Œuf'],
      },
      {
        'productId': 'tel',
        'quantity': 1.0,
        'serials': ['356789012345678'],
      },
    ]);
  });

  testWidgets('téléphonie : un IMEI par appareil, la quantité suit', (tester) async {
    phoneSize(tester);
    final (c, _) = await pumpSama(tester, location: '/pos', repo: FakeRepo()..extraProducts = [_tel]);
    await _open(tester, 'Tecno Spark 20');
    expect(find.textContaining('garantie 12 mois'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('serial_input')), '356789012345678');
    await tester.tap(find.byKey(const Key('serial_add')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('serial_input')), '356789012345678');
    await tester.tap(find.byKey(const Key('serial_add')));
    await tester.pump();
    expect(find.text('Déjà ajouté'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('serial_input')), '356 789 012 345 679');
    await tester.tap(find.byKey(const Key('serial_add')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('serials_ok')));
    await tester.pumpAndSettle();
    final line = c.read(cartProvider).lines.values.single;
    expect(line.quantity, 2);
    expect(line.serials, ['356789012345678', '356789012345679']);
    expect(line.total, 170000);
  });

  testWidgets('fiche produit : suppléments, IMEI et garantie envoyés', (tester) async {
    phoneSize(tester);
    final (_, repo) = await pumpSama(tester, location: '/products/new');
    await tester.enterText(find.byKey(const Key('pName')), 'Yassa poulet');
    await tester.enterText(find.byKey(const Key('pPrice')), '2000');
    await tester.tap(find.byKey(const Key('pMore')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const Key('pExtraAdd')), 200, scrollable: find.byType(Scrollable).first);
    await tester.enterText(find.byKey(const Key('pExtraPrice')), '500');
    await tester.enterText(find.byKey(const Key('pExtraName')), 'Frites');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(find.textContaining('Frites · +500'), findsOneWidget);
    tester.widget<SwitchListTile>(find.byKey(const Key('pSerial'))).onChanged!(true);
    await tester.pump();
    await tester.enterText(find.byKey(const Key('pWarranty')), '6');
    await tester.tap(find.text('Ajouter le produit'));
    await tester.pumpAndSettle();
    final d = repo.savedDrafts.single.$2;
    expect(d.extras!.map((e) => (e.name, e.price)), [('Frites', 500)]);
    expect((d.trackSerial, d.warrantyMonths), (true, 6));
    expect(d.toJson()['extras'], [
      {'name': 'Frites', 'price': 500},
    ]);
  });

  testWidgets('stock : bientôt périmés filtrés, badge de date', (tester) async {
    phoneSize(tester);
    final soon = DateTime.now().add(const Duration(days: 5));
    final later = DateTime.now().add(const Duration(days: 90));
    StockItem item(String id, String name, DateTime d) => StockItem(
      productId: id,
      name: name,
      price: 300,
      cost: 200,
      threshold: 2,
      onHand: 10,
      low: false,
      expiresOn: DateTime(d.year, d.month, d.day),
    );
    final repo = FakeRepo()..extraStock = [item('y', 'Yaourt nature', soon), item('l', 'Lait en poudre', later)];
    await pumpSama(tester, location: '/stock', repo: repo);
    expect(find.text('Bientôt périmés (1)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('filter_expiring')));
    await tester.pumpAndSettle();
    expect(find.text('Yaourt nature'), findsOneWidget);
    expect(find.text('Lait en poudre'), findsNothing);
    expect(find.textContaining('Périme le'), findsOneWidget);
  });

  test('reçu : IMEI et fin de garantie', () {
    final l = ReceiptLine(
      name: 'Tecno Spark 20',
      quantity: 1,
      unitPrice: 85000,
      total: 85000,
      serials: const ['356789012345678'],
      warrantyUntil: DateTime(2027, 11, 20),
    );
    expect(serialLines(l), ['IMEI / N° de série : 356789012345678', 'Garantie jusqu’au 20/11/2027']);
  });
}
