import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/models.dart';
import 'package:sama360/core/widgets.dart';
import 'package:sama360/features/cash/cash_close_screen.dart';
import 'package:sama360/features/cash/cash_pdf.dart';
import 'package:sama360/features/sales/receipt.dart';
import 'package:sama360/features/sales/receipt_screen.dart';

import 'helpers.dart';
import 'receipt_test.dart' show RecordingActions;

String _flat(String s) => s.replaceAll(RegExp(r'[\u202f\u00a0]'), ' ');

/// Bulle d'aide, espaces fines ignorées.
Finder tip(String text) => find.byWidgetPredicate((w) => w is Tooltip && _flat(w.message ?? '') == text);

Finder textMatching(String pattern) => find.byWidgetPredicate(
  (w) => w is Text && w.data != null && RegExp(pattern).hasMatch(w.data!.replaceAll(RegExp(r'[  ]'), ' ')),
);

void main() {
  setUpAll(() async {
    await initializeDateFormatting('fr');
    await loadTestFonts();
  });

  group('logique', () {
    test('comptage billet par billet', () {
      expect(countTotal({10000: 4, 2000: 1, 500: 3, 25: 2}), 43550);
      expect(countTotal({}), 0);
    });

    test('détail d’un moyen de paiement', () {
      final cash = FakeRepo.demoCashSession.report.methods.first;
      expect(cash.breakdown, [
        ('Fond de caisse', 10000),
        ('Ventes', 52000),
        ('Remboursements de crédit', 5000),
        ('Dépenses', -3500),
        ('Sorties d’argent', -20000),
      ]);
      expect(FakeRepo.demoCashSession.report.expectedCash, 43500);
    });

    test('lecture d’une caisse renvoyée par l’API', () {
      final s = CashSession.fromJson(
        jsonDecode('''{
          "id": "c", "number": "Z-2026-0001", "status": "closed", "userId": "u", "userName": "Modou",
          "openingFloat": "10000", "openedAt": "2026-11-16T08:00:00Z", "closedAt": "2026-11-16T19:00:00Z",
          "report": {"salesCount": 2, "salesTotal": "15000", "creditTotal": 4000, "expectedTotal": 17500,
            "methods": [{"method": "cash", "opening": 10000, "sales": 7000, "expected": 12500, "movementsOut": 3000, "movementsIn": 500, "expenses": 2000},
                        {"method": "orange_money", "repayments": 1500, "expected": 1500}]},
          "difference": -500,
          "lines": [{"method": "cash", "expected": 12500, "counted": 12000, "difference": -500}],
          "movements": [{"id": "m", "direction": "out", "amount": 3000, "reason": "Banque", "createdAt": "2026-11-16T12:00:00Z"}]
        }''')
            as Map<String, dynamic>,
      );
      expect((s.open, s.openingFloat, s.report.salesTotal, s.difference), (false, 10000, 15000, -500));
      expect(s.report.methods.last.method, PayMethod.orangeMoney);
      expect(s.lines!.single.counted, 12000);
      expect(s.movements.single.isIn, isFalse);
    });

    test('rapport Z imprimable (80 mm)', () async {
      final pdf = await buildCashZPdf(FakeRepo.demoClosedSession, demoBusiness, fonts: await ReceiptFonts.load());
      expect(latin1.decode(pdf).startsWith('%PDF-'), isTrue);
      expect(cashFileName(FakeRepo.demoClosedSession), 'Rapport-Z-2026-0006.pdf');
    });
  });

  group('écrans', () {
    testWidgets('ouverture avec fond de caisse', (tester) async {
      phoneSize(tester);
      final repo = FakeRepo()..cashOpen = false;
      await pumpSama(tester, location: '/cash', repo: repo);
      expect(find.text('Ouvrir la caisse'), findsOneWidget);
      await tester.tap(textMatching(r'^10 000 F$'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ouvrir ma caisse'));
      await tester.pumpAndSettle();
      expect(repo.cashOpenings.single.$1, 10000);
      expect(find.text('Caisse ouverte : bonnes ventes !'), findsOneWidget);
      expect(textMatching(r'^43 500 F$'), findsWidgets); // vue de la caisse ouverte
    });

    testWidgets('caisse ouverte : attendu par moyen, détail, sortie d’argent', (tester) async {
      phoneSize(tester);
      final (_, repo) = await pumpSama(tester, location: '/cash');
      expect(find.text('Ouverte à 08:12 · Z-2026-0007'), findsOneWidget);
      expect(textMatching(r'^43 500 F$'), findsWidgets);
      expect(textMatching(r'^21 000 F$'), findsOneWidget);
      await tester.tap(find.text('Espèces'));
      await tester.pumpAndSettle();
      expect(find.text('Fond de caisse'), findsOneWidget);
      expect(textMatching(r'^− 20 000 F$'), findsWidgets);

      await tester.tap(find.text('Sortie'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('movementAmount')), '50000');
      await tester.tap(find.text('Remis au gérant'));
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();
      expect(textMatching(r'^Il n’y a que 43 500 F en espèces dans la caisse$'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('movementAmount')), '10000');
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();
      expect(repo.cashMovements, [(false, 10000, 'Remis au gérant')]);
    });

    testWidgets('clôture : compteur de billets, écart en direct, confirmation, rapport Z', (tester) async {
      phoneSize(tester);
      final (c, repo) = await pumpSama(tester, location: '/cash/close');
      await tester.tap(find.text('Fermer la caisse'));
      await tester.pumpAndSettle();
      expect(find.text('Comptez les espèces de la caisse'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6)); // le message disparaît
      await tester.pumpAndSettle();

      await tester.tap(find.text('Compter billet par billet'));
      await tester.pumpAndSettle();
      for (var i = 0; i < 4; i++) {
        await tester.tap(tip('Un billet de 10 000 F de plus'));
        await tester.pump();
      }
      await tester.tap(tip('Un billet de 2 000 F de plus'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byKey(const Key('count_cash'))).controller!.text, '42000');
      expect(textMatching(r'^Manque 1 500 F$'), findsWidgets);

      await tester.enterText(find.byKey(const Key('count_cash')), '43500');
      await tester.pumpAndSettle();
      expect(find.text('Juste'), findsWidgets);
      await tester.enterText(find.byKey(const Key('count_cash')), '43000');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fermer la caisse'));
      await tester.pumpAndSettle();
      expect(textMatching(r'^Il manque 500 F'), findsOneWidget);
      await tester.tap(find.widgetWithText(ConfirmButton, 'Fermer'));
      await tester.pumpAndSettle();
      final (session, counted, _) = repo.cashClosings.single;
      expect(session, isNull);
      expect(counted, {PayMethod.cash: 43000, PayMethod.wave: 21000, PayMethod.orangeMoney: 6000});
      expect(routerOf(c).state.matchedLocation, '/cash/sessions/cs0');
      expect(find.text('Résumé de caisse'), findsOneWidget);
    });

    testWidgets('rapport Z : comptage, écart, note, impression', (tester) async {
      phoneSize(tester);
      final actions = RecordingActions();
      await pumpSama(
        tester,
        location: '/cash/sessions/cs0',
        overrides: [receiptActionsProvider.overrideWithValue(actions)],
      );
      expect(find.text('Moussa Sow'), findsOneWidget);
      expect(textMatching(r'^Manque 500 F$'), findsOneWidget);
      expect(textMatching(r'^Attendu 34 000 F · compté 33 500 F$'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Note : Billet de 500 F déchiré'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byTooltip('Imprimer le rapport'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
      await tester.pumpAndSettle();
      expect(actions.printed, isNotNull);
    });

    testWidgets('historique des caisses', (tester) async {
      phoneSize(tester);
      final (c, _) = await pumpSama(tester, location: '/cash/history');
      expect(find.text('Ouverte'), findsOneWidget);
      expect(textMatching(r'^Manque 500 F$'), findsOneWidget);
      await tester.tap(textMatching(r'^Moussa Sow'));
      await tester.pumpAndSettle();
      expect(routerOf(c).state.matchedLocation, '/cash/sessions/cs0');
    });

    testWidgets('caisse : bannière sur la caisse quand elle n’est pas ouverte', (tester) async {
      phoneSize(tester);
      final repo = FakeRepo()..cashOpen = false;
      final (c, _) = await pumpSama(tester, location: '/pos', repo: repo);
      expect(find.text('Caisse non ouverte : ouvrez-la pour suivre vos espèces'), findsOneWidget);
      await tester.tap(find.text('Ouvrir'));
      await tester.pumpAndSettle();
      expect(routerOf(c).state.matchedLocation, '/cash');
    });

    testWidgets('caisse obligatoire et fermée : on ne peut pas encaisser, on va ouvrir la caisse', (tester) async {
      phoneSize(tester);
      final repo = FakeRepo()
        ..cashOpen = false
        ..requireOpenCash = true;
      final (c, _) = await pumpSama(tester, location: '/pos', repo: repo);
      expect(find.text('Caisse fermée : ouvrez-la pour pouvoir vendre'), findsOneWidget);
      await tester.tap(find.text('Beurre de karité 250 g'));
      await tester.pump();
      expect(find.textContaining('Encaisser'), findsNothing);
      await tester.tap(find.byKey(const Key('open_cash_to_sell')));
      await tester.pumpAndSettle();
      expect(routerOf(c).state.uri.path, '/cash');
      expect(repo.sales, isEmpty);
    });

    testWidgets('caisse obligatoire et ouverte : vente normale', (tester) async {
      phoneSize(tester);
      final repo = FakeRepo()..requireOpenCash = true;
      await pumpSama(tester, location: '/pos', repo: repo);
      await tester.tap(find.text('Beurre de karité 250 g'));
      await tester.pump();
      expect(find.byKey(const Key('open_cash_to_sell')), findsNothing);
      expect(find.textContaining('Encaisser'), findsOneWidget);
    });

    testWidgets('profil : le patron active la caisse obligatoire', (tester) async {
      phoneSize(tester);
      final (_, repo) = await pumpSama(tester, location: '/business/settings');
      await tester.scrollUntilVisible(
        find.byKey(const Key('require_cash_row')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('Désactivée'), findsOneWidget);
      await tester.tap(find.byKey(const Key('require_cash_row')));
      await tester.pumpAndSettle();
      expect(repo.requireOpenCash, isTrue);
      expect(find.text('Activée'), findsOneWidget);
    });

    testWidgets('caisse ouverte : pas de bannière sur la caisse', (tester) async {
      phoneSize(tester);
      await pumpSama(tester, location: '/pos');
      expect(find.text('Caisse non ouverte : ouvrez-la pour suivre vos espèces'), findsNothing);
    });
  });
}
