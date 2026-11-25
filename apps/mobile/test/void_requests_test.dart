import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers.dart';
import 'team_test.dart' show CashierRepo;

void main() {
  setUpAll(loadTestFonts);

  testWidgets('vendeur : il demande l’annulation, la vente reste en attente du gérant', (tester) async {
    phoneSize(tester);
    final repo = CashierRepo();
    await pumpSama(tester, location: '/sales/s2', repo: repo);
    expect(find.byTooltip('Annuler la vente'), findsNothing);
    await tester.tap(find.byKey(const Key('ask_void')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('askReason')), 'Le client a changé d’avis');
    await tester.tap(find.text('Envoyer la demande'));
    await tester.pumpAndSettle();
    expect(repo.voidRequests['s2'], ('pending', 'Le client a changé d’avis', null));
    expect(find.byKey(const Key('void_request_pending')), findsOneWidget);
    expect(find.text('Annulation demandée : en attente du gérant'), findsOneWidget);
    expect(find.byKey(const Key('ask_void')), findsNothing);
    expect(find.byKey(const Key('void_accept')), findsNothing);
  });

  testWidgets('gérant : la demande en tête des ventes, puis refusée avec un motif', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo()..voidRequests['s2'] = ('pending', 'Erreur de saisie', null);
    await pumpSama(tester, location: '/sales', repo: repo);
    expect(find.byKey(const Key('pending_voids')), findsOneWidget);
    expect(find.text('1 demande d’annulation'), findsOneWidget);
    expect(find.text('Annulation demandée'), findsOneWidget);

    await tester.tap(find.descendant(of: find.byKey(const Key('pending_voids')), matching: find.byType(ListTile)));
    await tester.pumpAndSettle();
    expect(find.text('Moussa demande l’annulation'), findsOneWidget);
    expect(find.text('Motif : Erreur de saisie'), findsOneWidget);

    await tester.tap(find.byKey(const Key('void_reject')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('askReason')), 'Article déjà ouvert');
    await tester.tap(find.text('Refuser').last);
    await tester.pumpAndSettle();
    expect(repo.voidRequests['s2']!.$1, 'rejected');
    expect(find.byKey(const Key('void_request_rejected')), findsOneWidget);
    expect(find.text('Motif : Article déjà ouvert'), findsOneWidget);
  });

  testWidgets('gérant : accepter = annuler la vente, le motif du vendeur est repris', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo()..voidRequests['s2'] = ('pending', 'Erreur de saisie', null);
    await pumpSama(tester, location: '/sales/s2', repo: repo);
    await tester.tap(find.byKey(const Key('void_accept')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Erreur de saisie'), findsOneWidget);
    await tester.tap(find.text('Oui, annuler'));
    await tester.pumpAndSettle();
    expect(repo.voidedSales, {'s2': 'Erreur de saisie'});
  });
}
