import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/models.dart';
import 'package:sama360/features/loyalty/loyalty_screen.dart';
import 'package:sama360/features/sales/cart.dart';
import 'package:sama360/features/sales/receipt.dart';
import 'package:sama360/features/sales/receipt_screen.dart';

import 'helpers.dart';
import 'receipt_test.dart' show RecordingActions;

String flat(String s) => s.replaceAll(RegExp(r'[  ]'), ' ');

void main() {
  setUpAll(() async {
    await loadTestFonts();
    await initializeDateFormatting('fr');
  });

  const s = LoyaltySettings(enabled: true, earnPer: 1000, rewardPoints: 100, rewardValue: 2000);

  group('logique', () {
    test('règle, points et récompenses', () {
      expect(flat(loyaltyRuleText(s)), '1 point pour 1 000 F · 100 points = 2 000 F de réduction (2 % reversé)');
      expect(s.pointsFor(31600), 31);
      expect(s.rewardsFor(250), 2);
      expect(const LoyaltySettings().pointsFor(31600), 0); // programme éteint
    });

    test('anniversaires', () {
      const b = UpcomingBirthday(customerId: 'x', name: 'Khady Ndiaye', day: 17, month: 11, inDays: 0, points: 17);
      expect(birthdayWhen(b), 'Aujourd’hui · 17 novembre');
      expect(
        birthdayMessage(b, 'Awa Beauté'),
        'Joyeux anniversaire Khady ! Toute l’équipe de Awa Beauté vous souhaite une belle journée. '
        'Vous avez 17 points fidélité à utiliser chez nous. À bientôt !',
      );
    });

    test('remise fidélité dans le panier', () {
      const p = Product(id: 'p', name: 'Bazin', price: 5000, cost: 3000);
      final cart = const CartState().copyWith(lines: {'p': const CartLine(p, 2)}, rewards: 1, rewardValue: 2000);
      expect(cart.subtotal, 10000);
      expect(cart.loyaltyDiscount, 2000);
      expect(cart.total, 8000);
      // La remise ne dépasse jamais le montant des articles
      expect(cart.copyWith(rewards: 9).total, 0);
    });

    test('ligne du reçu', () {
      expect(loyaltyLine(const SaleLoyalty(earned: 12, redeemed: 0, balance: 12)), '+12 points · solde 12 points');
      expect(
        loyaltyLine(const SaleLoyalty(earned: 2, redeemed: 100, balance: 37)),
        '+2 points · 100 utilisés · solde 37 points',
      );
      expect(loyaltyLine(const SaleLoyalty(earned: 0, redeemed: 0, balance: 5)), isNull);
      expect(loyaltyLine(null), isNull);
    });
  });

  group('écrans', () {
    testWidgets('tableau de bord : programme, anniversaires (vœux WhatsApp), meilleurs clients', (tester) async {
      phoneSize(tester);
      final actions = RecordingActions();
      await pumpSama(tester, location: '/loyalty', overrides: [receiptActionsProvider.overrideWithValue(actions)]);
      expect(find.text('Programme actif'), findsOneWidget);
      expect(find.text('2220'), findsOneWidget);
      expect(find.text('Aujourd’hui · 17 novembre'), findsOneWidget);
      await tester.tap(find.byTooltip('Souhaiter l’anniversaire de Khady Ndiaye'));
      await tester.pumpAndSettle();
      expect(actions.whatsApp!.path, '/221776401122');
      expect(actions.whatsApp!.queryParameters['text'], startsWith('Joyeux anniversaire Khady'));
      await tester.scrollUntilVisible(find.text('Hôtel Teranga'), 200);
      expect(find.text('Hôtel Teranga'), findsOneWidget);
    });

    testWidgets('programme éteint : lancer, régler avec aperçu, enregistrer', (tester) async {
      phoneSize(tester);
      final repo = FakeRepo()..loyalty = const LoyaltySettings();
      await pumpSama(tester, location: '/loyalty', repo: repo);
      await tester.tap(find.text('Lancer le programme'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('rewardValue')), '1000');
      await tester.pumpAndSettle();
      expect(flat(tester.widget<Text>(find.byKey(const Key('loyalty_preview'))).data!), contains('(1 % reversé)'));
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();
      expect(repo.savedLoyalty.single.toJson(), {
        'enabled': true,
        'earnPer': 1000,
        'rewardPoints': 100,
        'rewardValue': 1000,
      });
    });

    testWidgets('fiche client : carte de fidélité et cadeau de points', (tester) async {
      phoneSize(tester);
      final (_, repo) = await pumpSama(tester, location: '/customers/k1');
      await tester.scrollUntilVisible(find.byKey(const Key('loyalty_card')), 200);
      expect(find.text('135 points'), findsOneWidget);
      expect(find.textContaining('1 récompense disponible'), findsOneWidget);
      await tester.tap(find.byTooltip('Offrir des points'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('gift_points')), '15');
      await tester.tap(find.text('Offrir'));
      await tester.pumpAndSettle();
      expect(repo.loyaltyGifts, [('k1', 15, 'Cadeau')]);
    });

    testWidgets('caisse : utiliser une récompense baisse le total et part avec la vente', (tester) async {
      phoneSize(tester);
      final (c, repo) = await pumpSama(tester, location: '/pos');
      final cart = c.read(cartProvider.notifier);
      cart.add(demoProducts[0]); // 3 500 F
      cart.add(demoProducts[0]);
      cart.setCustomer(const Contact(id: 'k1', name: 'Fatou Ndiaye', phone: '+221774120855'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('loyalty_chip')), findsOneWidget);
      expect(find.textContaining('+7 points avec cet achat'), findsOneWidget);
      await tester.tap(find.textContaining('Utiliser'));
      await tester.pumpAndSettle();
      expect(c.read(cartProvider).total, 5000);
      expect(
        flat(tester.widget<Text>(find.textContaining('Réduction fidélité')).data!),
        'Réduction fidélité : −2 000 F',
      );

      await tester.tap(find.textContaining('Encaisser'));
      await tester.pumpAndSettle();
      expect(repo.sales.last['redeemRewards'], 1);
      expect(repo.sales.last['customerId'], 'k1');
    });
  });
}
