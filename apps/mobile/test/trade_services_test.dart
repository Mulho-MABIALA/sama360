import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/trades.dart';

import 'helpers.dart';

/// Chaque métier ne voit que ses outils : pas de réservation chez le vendeur d'habits, oui au restaurant.
void main() {
  setUpAll(loadTestFonts);

  test('services par défaut selon le métier', () {
    expect(defaultServices('mode'), isNot(contains(BizService.booking)));
    expect(defaultServices('boutique'), isNot(contains(BizService.booking)));
    expect(defaultServices('cosmetique'), isNot(contains(BizService.booking)));
    expect(tradeLabels['cosmetique'], 'Parfumerie & cosmétique');
    expect(defaultServices('restaurant'), contains(BizService.booking));
    expect(defaultServices('restaurant'), isNot(contains(BizService.invoices)));
    expect(defaultServices('salon'), containsAll([BizService.booking, BizService.loyalty]));
    expect(defaultServices('salon'), isNot(contains(BizService.delivery)));
    expect(defaultServices('quincaillerie'), containsAll([BizService.invoices, BizService.purchases]));
    expect(defaultServices(null), BizService.values.toSet());
    expect(defaultServices('mode', focus: 'both'), contains(BizService.booking));
  });

  test('champs produit selon le métier', () {
    expect(tradeShows('telephonie', TradeField.serial), isTrue);
    expect(tradeShows('telephonie', TradeField.extras), isFalse);
    expect(tradeShows('restaurant', TradeField.extras), isTrue);
    expect(tradeShows('mode', TradeField.expiry), isFalse);
    expect(tradeShows('cosmetique', TradeField.expiry), isTrue);
    expect(tradeShows('cosmetique', TradeField.serial), isFalse);
    expect(tradeShows(null, TradeField.serial), isTrue);
  });

  Future<void> openMore(WidgetTester tester) async {
    await tester.ensureVisible(find.byIcon(Icons.apps_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.apps_rounded));
    await tester.pumpAndSettle();
  }

  testWidgets('boutique d’habits : pas de Réservation, ni sur l’accueil ni dans « Plus »', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, repo: FakeRepo()..businessCategory = 'mode');
    await openMore(tester);
    expect(find.text('Réservation'), findsNothing);
    expect(find.text('Boutique'), findsOneWidget);
    expect(find.byKey(const Key('manage_services')), findsOneWidget);
  });

  testWidgets('restaurant : Réservation présente, Factures absentes', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, repo: FakeRepo()..businessCategory = 'restaurant');
    await openMore(tester);
    expect(find.text('Réservation'), findsOneWidget);
    expect(find.text('Factures'), findsNothing);
  });

  testWidgets('Mes services : ajouter Réservation, changer de métier remet ses services', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo()..businessCategory = 'mode';
    await pumpSama(tester, location: '/business/services', repo: repo);
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('svc_booking'))).value, isFalse);

    await tester.tap(find.byKey(const Key('svc_booking')));
    await tester.pumpAndSettle();
    expect(repo.businessServices, contains('booking'));
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('svc_booking'))).value, isTrue);

    await tester.tap(find.byKey(const Key('trade_salon')));
    await tester.pumpAndSettle();
    expect(repo.businessCategory, 'salon');
    expect(repo.businessServices, isNull);
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('svc_delivery'))).value, isFalse);
  });
}
