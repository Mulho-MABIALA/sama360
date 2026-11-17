import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/models.dart';
import 'package:sama360/features/sales/receipt_screen.dart';
import 'package:sama360/features/shop/status_screen.dart';

import 'helpers.dart';
import 'receipt_test.dart' show RecordingActions;

class RecordingStatus extends StatusActions {
  Uint8List? png;
  String? caption;
  @override
  Future<void> shareImage(Uint8List png, String caption) async {
    this.png = png;
    this.caption = caption;
  }
}

const _savon = Product(id: 'p2', name: 'Savon noir', price: 1500, cost: 800);
const _karite = Product(id: 'p1', name: 'Beurre de karité 250 g', price: 3500, cost: 2000);

void main() {
  setUpAll(loadTestFonts);

  group('logique', () {
    test('prix promo arrondi à 25 F', () {
      expect(promoPrice(1500, 0), 1500);
      expect(promoPrice(1500, 20), 1200);
      expect(promoPrice(3500, 15), 2975);
      expect(promoPrice(1990, 10), 1800);
    });

    test('lien : boutique avec produits en vedette, sinon WhatsApp', () {
      expect(
        orderLink(apiBase: 'https://api.sama360.app/', shopPath: '/s/awa', products: [_savon, _karite]),
        'https://api.sama360.app/s/awa?p=p2,p1',
      );
      final wa = orderLink(apiBase: 'x', phone: '+221 77 123 45 67', products: [_savon])!;
      expect(wa, startsWith('https://wa.me/221771234567?text='));
      expect(Uri.decodeFull(wa), contains('je veux commander : Savon noir'));
      expect(orderLink(apiBase: 'x', products: [_savon]), isNull);
    });

    test('légende', () {
      final t = statusCaption(
        business: 'Awa Beauté',
        headline: 'Promo du jour',
        products: [_savon],
        percent: 20,
        link: 'https://l',
      );
      expect(t, contains('🔥 Promo du jour chez Awa Beauté'));
      expect(t, contains('• Savon noir : 1 200 F au lieu de 1 500 F'));
      expect(t, contains('👉 Commandez ici : https://l'));
      expect(
        statusCaption(business: 'B', headline: 'Nouveauté', products: [_savon]),
        contains('• Savon noir : 1 500 F'),
      );
    });
  });

  testWidgets('boutique → statut : choix, réduction, image partagée avec légende', (tester) async {
    phoneSize(tester);
    final status = RecordingStatus();
    final actions = RecordingActions();
    final (c, _) = await pumpSama(
      tester,
      location: '/shop',
      overrides: [statusActionsProvider.overrideWithValue(status), receiptActionsProvider.overrideWithValue(actions)],
    );
    await tester.tap(find.byKey(const Key('open_status')));
    await tester.pumpAndSettle();
    expect(find.text('Choisir les produits (1 à 4)'), findsOneWidget);

    await tester.tap(find.byKey(const Key('status_pick')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pick_p2')));
    await tester.tap(find.byKey(const Key('pick_p1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pick_done')));
    await tester.pumpAndSettle();
    expect(find.byType(StatusCard), findsOneWidget);

    await tester.tap(find.text('-20 %'));
    await tester.pumpAndSettle();
    expect(find.text('1 200 F'), findsOneWidget); // dans l'image

    await tester.scrollUntilVisible(
      find.byKey(const Key('status_text')),
      300,
      scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first,
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('status_share')));
      for (var i = 0; i < 20 && status.png == null; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    await tester.pumpAndSettle();
    expect(status.png, isNotNull);
    expect(status.png!.sublist(1, 4), 'PNG'.codeUnits);
    expect(status.caption, contains('Savon noir : 1 200 F au lieu de 1 500 F'));
    expect(status.caption, contains('/s/awa-beaute?p=p2,p1'));

    await tester.tap(find.byKey(const Key('status_text')));
    await tester.pumpAndSettle();
    expect(Uri.decodeFull(actions.whatsApp.toString()), contains('Promo du jour chez Awa Beauté'));
    expect(c, isNotNull);
  });

  testWidgets('depuis la fiche produit : produit déjà choisi', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/status?ids=p2');
    expect(find.byType(StatusCard), findsOneWidget);
    expect(find.text('Savon noir'), findsWidgets);
    expect(find.text('1 500 F'), findsWidgets);
  });
}
