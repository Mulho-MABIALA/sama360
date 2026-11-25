import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/api/api_client.dart';
import 'package:sama360/core/format.dart';
import 'package:sama360/core/models.dart';
import 'package:sama360/core/widgets.dart';
import 'package:sama360/features/sales/receipt.dart';

import 'helpers.dart';

/// Version gratuite : limites visibles, Pro proposé au bon moment, prix fixe à la semaine, au mois ou à l'année.
void main() {
  setUpAll(() async {
    await loadTestFonts();
    await initializeDateFormatting('fr');
  });

  test('reçu : mention Sama360 en gratuit, au seul nom du commerçant en Pro', () {
    expect(
      receiptText(demoSale, demoBusiness),
      endsWith('_Reçu fait avec Sama360, la caisse gratuite des commerçants_'),
    );
    final paid = CurrentBusiness.fromJson({
      'business': {'id': 'b1', 'name': 'Awa Beauté', 'slug': 'awa-beaute'},
      'me': {
        'role': 'owner',
        'permissions': const ['*'],
      },
      'modules': const [],
      'subscription': {
        'plan': 'pro',
        'status': 'active',
        'currentPeriodEnd': DateTime.now().add(const Duration(days: 30)).toIso8601String(),
      },
    });
    expect(paid.isPro, isTrue);
    expect(receiptText(demoSale, paid), endsWith('Merci de votre confiance !'));
  });

  test('prix : semaine, mois, année et prix du jour', () {
    final s = ProStatus.fromJson({
      'pro': false,
      'state': 'free',
      'prices': {'weekly': 1500, 'monthly': 5000, 'yearly': 50000},
      'freeLimits': {'products': 50, 'historyDays': 30},
      'onlineCycles': ['monthly', 'yearly'],
    });
    expect([s.priceOf('weekly'), s.priceOf('monthly'), s.priceOf('yearly')], [1500, 5000, 50000]);
    expect(s.perDay, 167);
    expect(s.onlineCycles, isNot(contains('weekly')));
    expect(cycleLabel('weekly'), 'Semaine');
  });

  testWidgets('écran Pro : trois durées, prix fixe sans commission, la semaine se paie sur Chariow', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo()
      ..proUntil = DateTime(2026, 1, 1)
      ..proOnline = true;
    await pumpSama(tester, location: '/pro', repo: repo);
    final scroll = find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first;
    expect(find.textContaining('jusqu’à 50 produits'), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const Key('pro_fixed_price')), 300, scrollable: scroll);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('cycle_weekly')), findsOneWidget);
    expect(find.text('${moneyShort(167)} par jour'), findsOneWidget);

    await tester.tap(find.byKey(const Key('cycle_weekly')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const Key('pay_online')), 300, scrollable: scroll);
    await tester.pumpAndSettle();
    expect(find.text('Payer ${moneyShort(1500)}'), findsOneWidget);
    // E-mail obligatoire
    await tester.tap(find.byKey(const Key('pay_online')));
    await tester.pumpAndSettle();
    expect(repo.onlineCheckouts, isEmpty);
    await tester.enterText(find.byKey(const Key('pay_email')), 'awa@gmail.com');
    await tester.tap(find.byKey(const Key('pay_online')));
    await tester.pump(const Duration(milliseconds: 300)); // suivi du paiement : minuterie qui tourne
    expect(repo.onlineCheckouts.single['cycle'], 'weekly');
    await tester.pumpWidget(const SizedBox()); // arrête la minuterie
  });

  testWidgets('limite atteinte pendant une action : feuille Pro, puis l’offre', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, repo: FakeRepo()..proUntil = DateTime(2026, 1, 1));
    final ctx = tester.element(find.byType(Scaffold).first);
    showError(
      ctx,
      const ApiException(
        'PRO_REQUIRED',
        'Vous avez 50 produits : passez à Pro pour en ajouter autant que vous voulez',
        details: {'feature': 'catalog', 'limit': 50},
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pro_offer_message')), findsOneWidget);
    await tester.tap(find.byKey(const Key('pro_offer_open')));
    await tester.pumpAndSettle();
    expect(find.text('« Produits illimités » fait partie de Sama360 Pro.'), findsOneWidget);
  });

  testWidgets('écran bloqué par une limite : message et accès à Pro au lieu de « Réessayer »', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AsyncView<int>(
            value: const AsyncError(
              ApiException(
                'PRO_REQUIRED',
                'Version gratuite : rapports des 30 derniers jours',
                details: {'feature': 'history'},
              ),
              StackTrace.empty,
            ),
            data: (_) => const SizedBox(),
            onRetry: () {},
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('pro_lock_message')), findsOneWidget);
    expect(find.text('Réessayer'), findsNothing);
  });

  testWidgets('stock : jauge des produits gratuits à l’approche de la limite', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo()
      ..proUntil = DateTime(2026, 1, 1)
      ..extraProducts = [for (var i = 0; i < 40; i++) Product(id: 'x$i', name: 'Article $i', price: 1000, cost: 500)];
    await pumpSama(tester, location: '/stock', repo: repo);
    expect(find.byKey(const Key('free_products_banner')), findsOneWidget);
    expect(find.textContaining('produits sur 50 gratuits'), findsOneWidget);
  });
}
