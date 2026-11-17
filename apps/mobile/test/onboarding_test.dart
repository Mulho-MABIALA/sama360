import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/biometrics.dart';
import 'package:sama360/core/models.dart';
import 'package:sama360/features/business/business_screen.dart';

import 'helpers.dart';

void main() {
  setUpAll(loadTestFonts);

  test('activité proposée selon le type d’entreprise', () {
    expect(focusFor('salon'), 'services');
    expect(focusFor('prestataire'), 'services');
    expect(focusFor('boutique'), 'products');
    expect(focusFor('autre'), 'both');
  });

  testWidgets('boutique déjà créée : on demande l’activité sur l’accueil, puis le guide apparaît', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo()..onboardingValue = const Onboarding(dismissed: false, steps: []);
    await pumpSama(tester, repo: repo);
    expect(find.byKey(const Key('focus_question')), findsOneWidget);
    await tester.tap(find.byKey(const Key('pick_services')));
    await tester.pumpAndSettle();
    expect(repo.focusChoices, ['services']);
    expect(find.byKey(const Key('onboarding_card')), findsOneWidget);
    expect(find.text('1 sur 3 · quelques minutes pour bien démarrer'), findsOneWidget);
    expect(find.text('Faire votre première vente'), findsOneWidget);
  });

  testWidgets('guide : étapes faites barrées, une étape ouvre son écran, masquer', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo()
      ..onboardingValue = const Onboarding(
        focus: 'products',
        dismissed: false,
        steps: [
          OnboardingStep('add_products', true),
          OnboardingStep('first_sale', false),
          OnboardingStep('logo_phone', false),
          OnboardingStep('shop_online', false),
          OnboardingStep('invite_member', false),
        ],
      );
    final (c, _) = await pumpSama(
      tester,
      repo: repo,
      biometrics: FakeBiometrics(kindValue: BiometricKind.fingerprint),
    );
    // L'empreinte s'ajoute comme 6e étape sur un téléphone qui en a une
    expect(find.text('1 sur 6 · quelques minutes pour bien démarrer'), findsOneWidget);
    expect(find.text('Activer l’empreinte digitale'), findsOneWidget);

    await tester.drag(find.byType(ListView).first, const Offset(0, -250));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('step_shop_online')));
    await tester.pumpAndSettle();
    expect(routerOf(c).state.uri.path, '/shop');
    routerOf(c).pop();
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('onboarding_dismiss')));
    await tester.tap(find.byKey(const Key('onboarding_dismiss')));
    await tester.pumpAndSettle();
    expect(repo.onboardingDismissed, 1);
    expect(find.byKey(const Key('onboarding_card')), findsNothing);
  });

  testWidgets('activité « services » : Réservation remplace Stock sur l’accueil', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo()..businessFocus = 'services';
    await pumpSama(tester, repo: repo);
    await tester.ensureVisible(find.text('Réservation'));
    expect(find.text('Réservation'), findsOneWidget);
    // « Stock » ne reste que dans la barre d'onglets du bas
    expect(find.text('Stock'), findsOneWidget);
  });

  testWidgets('création d’entreprise : l’activité suit le type, modifiable, envoyée au serveur', (tester) async {
    phoneSize(tester);
    final (_, repo) = await pumpSama(tester, location: '/business');
    await tester.tap(find.text('Créer une entreprise'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('businessName')), 'Salon Ndeye');
    await tester.tap(find.text('Salon / beauté'));
    await tester.pump();
    expect(find.text('Vous vendez surtout…'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('focus_both')));
    await tester.tap(find.byKey(const Key('focus_both')));
    await tester.ensureVisible(find.text("Créer l'entreprise"));
    await tester.tap(find.text("Créer l'entreprise"));
    await tester.pumpAndSettle();
    expect(repo.createdBusinesses.single, {
      'name': 'Salon Ndeye',
      'category': 'salon',
      'city': 'Dakar',
      'focus': 'both',
    });
  });
}
