import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/models.dart';
import 'package:sama360/features/team/team_screen.dart';

import 'helpers.dart';

/// Entreprise vue par un vendeur (droits limités).
const cashierBusiness = CurrentBusiness(
  id: 'b1',
  name: 'Awa Beauté',
  slug: 'awa-beaute',
  city: 'Dakar',
  role: 'cashier',
  permissions: ['business:read', 'contacts:read', 'catalog:read', 'sales:read', 'sales:create', 'inventory:read'],
  modules: ['sales', 'inventory'],
);

class CashierRepo extends FakeRepo {
  @override
  Future<CurrentBusiness> currentBusiness() async => cashierBusiness;
}

void main() {
  setUpAll(loadTestFonts);

  test('message d’invitation WhatsApp', () {
    final t = inviteMessage(business: 'Awa Beauté', phone: '+221781112233', name: 'Moussa Fall');
    expect(t, startsWith('Bonjour Moussa, je t’ai ajouté(e) à l’équipe de Awa Beauté'));
    expect(t, contains('+221 78 111 22 33'));
  });

  testWidgets('l’équipe : membres, rôles et invitations en attente', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/team');
    expect(find.text('Awa Diallo (moi)'), findsOneWidget);
    expect(find.text('Moussa Fall'), findsOneWidget);
    expect(find.text('Invité · en attente de connexion'), findsOneWidget);
    expect(find.text('Gérant'), findsOneWidget);
    expect(find.text('Inviter'), findsOneWidget);
  });

  testWidgets('inviter un vendeur puis le prévenir par WhatsApp', (tester) async {
    phoneSize(tester);
    Uri? opened;
    final (_, repo) = await pumpSama(
      tester,
      location: '/team',
      overrides: [
        openUrlProvider.overrideWithValue((uri) async {
          opened = uri;
          return true;
        }),
      ],
    );

    await tester.tap(find.text('Inviter'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('invitePhone')), '12');
    await tester.tap(find.text('Envoyer l’invitation'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Numéro invalide'), findsOneWidget);

    // Déjà dans l'équipe
    await tester.enterText(find.byKey(const Key('invitePhone')), '78 111 22 33');
    await tester.tap(find.text('Envoyer l’invitation'));
    await tester.pumpAndSettle();
    expect(find.text('Cette personne fait déjà partie de l’équipe.'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('invitePhone')), '70 123 45 67');
    await tester.enterText(find.byKey(const Key('inviteName')), 'Ibou Ndiaye');
    await tester.tap(find.text('Envoyer l’invitation'));
    await tester.pumpAndSettle();
    expect(repo.invites.single, (phone: '+221701234567', fullName: 'Ibou Ndiaye', role: TeamRole.cashier));
    expect(find.text('Invitation enregistrée'), findsOneWidget);

    await tester.tap(find.text('Prévenir par WhatsApp'));
    await tester.pumpAndSettle();
    expect(opened!.path, '/221701234567');
    expect(Uri.decodeComponent(opened!.query), contains('Bonjour Ibou'));
    expect(find.text('Ibou Ndiaye'), findsOneWidget);
  });

  testWidgets('changer le rôle, suspendre puis retirer un membre', (tester) async {
    phoneSize(tester);
    final (_, repo) = await pumpSama(tester, location: '/team');

    await tester.tap(find.text('Moussa Fall'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Gérant').last);
    await tester.pump();
    await tester.tap(find.text('Enregistrer le rôle'));
    await tester.pumpAndSettle();
    expect(repo.team.firstWhere((m) => m.id == 'm2').role, 'manager');

    await tester.tap(find.text('Moussa Fall'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Suspendre l’accès'));
    await tester.pumpAndSettle();
    expect(find.text('Accès suspendu'), findsWidgets);

    await tester.tap(find.text('Moussa Fall'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retirer de l’équipe'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Retirer'));
    await tester.pumpAndSettle();
    expect(repo.team.any((m) => m.id == 'm2'), isFalse);
    expect(find.text('Moussa Fall'), findsNothing);
  });

  testWidgets('le propriétaire ne se gère pas lui-même', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/team');
    await tester.tap(find.text('Awa Diallo (moi)'));
    await tester.pumpAndSettle();
    expect(find.text('Enregistrer le rôle'), findsNothing);
  });

  testWidgets('accueil du gérant : classement des vendeurs du jour', (tester) async {
    phoneSize(tester);
    await pumpSama(tester);
    await tester.scrollUntilVisible(find.text('Vendeurs du jour'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Moussa Fall'), findsOneWidget);
    expect(find.text('+221 77 000 00 99'), findsOneWidget);
    expect(find.text('4 ventes'), findsOneWidget);
  });

  testWidgets('accueil du vendeur : ses ventes, pas de bénéfices ni d’équipe', (tester) async {
    phoneSize(tester);
    final repo = CashierRepo();
    await pumpSama(tester, repo: repo);
    expect(find.text('Mes ventes'), findsOneWidget);
    expect(find.text('3 ventes aujourd’hui'), findsOneWidget);
    expect(find.text('Bénéfice'), findsNothing);
    expect(find.text('Équipe'), findsNothing);
    expect(find.text('Vendeurs du jour'), findsNothing);
  });
}
