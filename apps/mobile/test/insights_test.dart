import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sama360/core/models.dart';
import 'package:sama360/features/reports/insights_screen.dart';
import 'package:sama360/features/sales/receipt_screen.dart';

import 'helpers.dart';
import 'receipt_test.dart' show RecordingActions;

void main() {
  setUpAll(loadTestFonts);

  group('phrases', () {
    test('heure de pointe et meilleur jour', () {
      final i = Insights.fromJson({
        'period': {'days': 30},
        'dormant': {'count': 0, 'stockValue': 0, 'items': []},
        'byHour': [],
        'byWeekday': [],
        'peak': {'from': 18, 'to': 20, 'share': 45},
        'bestWeekday': 6,
        'margins': {'lowMarginThreshold': 15, 'unknownCostCount': 0, 'products': [], 'lowMargin': []},
      });
      expect(
        peakSentence(i),
        'Vos clients viennent surtout de 18\u00a0h à 20\u00a0h (45\u00a0% des ventes). Le samedi est votre meilleur jour.',
      );
      expect(percent(8.3), '8,3 %');
      expect(percent(40), '40 %');
    });

    test('dernière vente', () {
      const never = DormantProduct(productId: 'a', name: 'A', onHand: 1, stockValue: 1);
      const old = DormantProduct(productId: 'b', name: 'B', onHand: 1, stockValue: 1, daysSinceSale: 45);
      expect(dormantWhen(never), 'Jamais vendu');
      expect(dormantWhen(old), 'Dernière vente il y a 45 j');
    });
  });

  testWidgets('Analyses : pointe, marges, produits qui dorment, période', (tester) async {
    phoneSize(tester);
    final (_, repo) = await pumpSama(tester, location: '/insights');
    expect(find.text('Heures de pointe'), findsOneWidget);
    expect(find.textContaining('de 18\u00a0h à 20\u00a0h'), findsOneWidget);
    expect(find.byKey(const Key('hour_bars')), findsOneWidget);

    await tester.scrollUntilVisible(find.text('Marge par produit'), 200);
    expect(find.text('Marge faible (moins de 15 %)'), findsOneWidget);
    expect(find.text('8,3 %'), findsWidgets);
    expect(find.text('47,4 %'), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const Key('unknown_cost_hint')), 200);

    await tester.scrollUntilVisible(find.text('Parfum Oud 50 ml'), 200);
    expect(find.text('Produits qui ne se vendent plus'), findsOneWidget);
    expect(find.textContaining('3 produits sans vente depuis 30 jours'), findsOneWidget);
    expect(find.text('Jamais vendu · 10 en stock'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('90 jours'), -300);
    await tester.tap(find.text('90 jours'));
    await tester.pumpAndSettle();
    expect(repo.insightRequests, [30, 90]);
  });

  testWidgets('rapport de la semaine : aperçu, envoi WhatsApp, semaine précédente', (tester) async {
    phoneSize(tester);
    final actions = RecordingActions();
    final (c, repo) = await pumpSama(
      tester,
      location: '/insights',
      overrides: [receiptActionsProvider.overrideWithValue(actions)],
    );
    await tester.tap(find.byKey(const Key('weekly_card')));
    await tester.pumpAndSettle();
    expect(routerOf(c).state.uri.path, '/insights/week');
    expect(find.byKey(const Key('weekly_preview')), findsOneWidget);
    // Le gras WhatsApp (*…*) est rendu sans les astérisques
    expect(find.textContaining('Awa Beauté — semaine du 9 nov. au 15 nov.', findRichText: true), findsOneWidget);
    expect(find.textContaining('*Awa', findRichText: true), findsNothing);

    await tester.tap(find.byKey(const Key('send_weekly')));
    await tester.pumpAndSettle();
    expect(actions.whatsApp.toString(), contains('wa.me'));
    expect(Uri.decodeFull(actions.whatsApp.toString()), contains("Chiffre d'affaires : *318 500 F*"));

    await tester.tap(find.byTooltip('Semaine précédente'));
    await tester.pumpAndSettle();
    expect(repo.weeklyRequests.last, DateTime(2026, 11, 2));
    expect(find.textContaining('2 nov'), findsWidgets);
  });

  testWidgets('les rapports mènent aux analyses', (tester) async {
    phoneSize(tester);
    final (c, _) = await pumpSama(tester, location: '/reports');
    await tester.tap(find.byKey(const Key('open_insights')));
    await tester.pumpAndSettle();
    expect(routerOf(c).state.uri.path, '/insights');
  });
}
