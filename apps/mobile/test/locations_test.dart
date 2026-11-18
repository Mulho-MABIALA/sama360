// Plusieurs points de vente : choix sur l'accueil, gestion, transfert, vendeurs rattachés.
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/models.dart';

import 'helpers.dart';

const _two = [
  ShopLocation(id: 'loc1', name: 'Boutique principale', isDefault: true, todayRevenue: 58000),
  ShopLocation(id: 'loc2', name: 'Boutique Médina', address: 'Rue 11 x 6', todayRevenue: 28500, members: 1),
];

void main() {
  setUpAll(loadTestFonts);

  testWidgets('un seul point de vente : rien de plus sur l’accueil', (tester) async {
    phoneSize(tester);
    await pumpSama(tester);
    expect(find.byKey(const Key('location_chip')), findsNothing);
    expect(find.byKey(const Key('locations_of_day')), findsNothing);
  });

  testWidgets('accueil : tous les points de vente, puis un seul', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo()..shopLocations = _two;
    await pumpSama(tester, repo: repo);
    expect(find.text('Tous les points de vente'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('locations_of_day')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Points de vente du jour'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const Key('location_chip')),
      -300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('location_chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pick_location_loc2')));
    await tester.pumpAndSettle();
    expect(repo.api.locationId, 'loc2');
    expect(
      find.descendant(of: find.byKey(const Key('location_chip')), matching: find.text('Boutique Médina')),
      findsOneWidget,
    );
    // Un seul point de vente regardé : plus de comparaison
    expect(find.byKey(const Key('locations_of_day')), findsNothing);
  });

  testWidgets('vendeur rattaché : son point de vente, sans choix possible', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo()
      ..shopLocations = _two
      ..lockedLocation = 'loc2';
    await pumpSama(tester, repo: repo);
    final chip = find.byKey(const Key('location_chip'));
    expect(find.descendant(of: chip, matching: find.text('Boutique Médina')), findsOneWidget);
    expect(find.descendant(of: chip, matching: find.byIcon(Icons.lock_rounded)), findsOneWidget);
    await tester.tap(find.byKey(const Key('location_chip')));
    await tester.pumpAndSettle();
    expect(find.text('Tous les points de vente'), findsNothing);
  });

  testWidgets('ajouter un point de vente (Pro), puis le fermer', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo()..shopLocations = _two;
    await pumpSama(tester, location: '/locations', repo: repo);
    expect(find.text('Boutique Médina'), findsOneWidget);
    expect(find.text('Principal'), findsOneWidget);

    await tester.tap(find.byKey(const Key('add_location')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('location_name')), 'Boutique Sandaga');
    await tester.enterText(find.byKey(const Key('location_address')), 'Marché Sandaga');
    await tester.tap(find.byKey(const Key('location_save')));
    await tester.pumpAndSettle();
    expect(repo.savedLocations.single, containsPair('name', 'Boutique Sandaga'));
    expect(find.text('Boutique Sandaga'), findsOneWidget);

    await tester.tap(find.byKey(const Key('location_loc2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('location_archive')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Fermer'));
    await tester.pumpAndSettle();
    expect(repo.archivedLocations, ['loc2']);
  });

  testWidgets('sans Pro : un deuxième point de vente mène à l’offre', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo()..proUntil = DateTime(2026, 1, 1);
    await pumpSama(tester, location: '/locations', repo: repo);
    await tester.tap(find.byKey(const Key('add_location')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pro_headline')), findsOneWidget);
    expect(repo.savedLocations, isEmpty);
  });

  testWidgets('transfert de marchandise d’un point de vente à l’autre', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo()..shopLocations = _two;
    await pumpSama(tester, location: '/stock/transfer', repo: repo);
    await tester.tap(find.byKey(const Key('transfer_add')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Beurre de karité 250 g'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('transfer_plus_0')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('transfer_send')));
    await tester.pumpAndSettle();
    expect(repo.transferBodies.single, {
      'fromId': 'loc1',
      'toId': 'loc2',
      'lines': [('p1', 2.0)],
    });
  });

  testWidgets('équipe : rattacher un vendeur à un point de vente', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo()..shopLocations = _two;
    await pumpSama(tester, location: '/team', repo: repo);
    final seller = repo.team.firstWhere((m) => !m.isOwner);
    await tester.tap(find.text(seller.displayName));
    await tester.pumpAndSettle();
    await tapCentered(tester, find.byKey(const Key('member_location')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Boutique Médina').last);
    await tester.pumpAndSettle();
    expect(repo.memberUpdates.single, {'id': seller.id, 'locationId': 'loc2'});
  });

  testWidgets('caisse : on voit où va la vente', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo()..shopLocations = _two;
    await pumpSama(tester, location: '/pos', repo: repo);
    expect(find.byKey(const Key('selling_at')), findsOneWidget);
    expect(find.textContaining('Boutique principale', findRichText: true), findsWidgets);
  });
}
