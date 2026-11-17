import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/features/auth/auth_controller.dart';
import 'package:sama360/features/catalog/product_photo.dart';

import 'package:sama360/features/sales/cart.dart';
import 'package:sama360/features/shell/shell.dart';

import 'helpers.dart';

void main() {
  setUpAll(loadTestFonts);

  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
  );

  testWidgets('la barre du bas n’a plus d’onglet Compte ; l’avatar ouvre le profil', (tester) async {
    phoneSize(tester);
    await pumpSama(tester);
    // Accueil, Stock, Vendre (au centre), Clients, Ventes
    for (final t in ['Accueil', 'Stock', 'Vendre', 'Clients', 'Ventes']) {
      expect(find.text(t), findsWidgets);
    }
    expect(find.text('Compte'), findsNothing);

    await tester.tap(find.text('AD').first); // avatar de l'en-tête
    await tester.pumpAndSettle();
    expect(find.text('Mon profil'), findsOneWidget);
    expect(find.text('+221 77 123 45 67'), findsWidgets);
    expect(find.text('Propriétaire · Awa Beauté'), findsOneWidget);

    await tester.tap(find.byTooltip('Retour'));
    await tester.pumpAndSettle();
    expect(find.text('Caisse du jour'), findsOneWidget);
  });

  testWidgets('photo de profil : ajout depuis la galerie puis retrait', (tester) async {
    phoneSize(tester);
    final (c, repo) = await pumpSama(
      tester,
      location: '/account',
      overrides: [photoPickerProvider.overrideWithValue((_) async => PickedPhoto(png, 'moi.png'))],
    );

    await tester.tap(find.byKey(const Key('profilePhoto')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choisir dans la galerie'));
    await tester.pumpAndSettle();
    expect(repo.avatarUploads, 1);
    expect(c.read(authProvider).value!.me!.avatarFileId, 'avatar-1');
    expect(find.text('Photo de profil mise à jour'), findsOneWidget);

    await tester.tap(find.byKey(const Key('profilePhoto')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retirer la photo'));
    await tester.pumpAndSettle();
    expect(c.read(authProvider).value!.me!.avatarFileId, isNull);
  });

  testWidgets('modifier son nom et son e-mail', (tester) async {
    phoneSize(tester);
    final (_, repo) = await pumpSama(tester, location: '/account');

    await tester.tap(find.text('Modifier'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('profileEmail')), 'pas-un-email');
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();
    expect(find.text('Adresse e-mail invalide'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('profileName')), 'Awa Ndiaye Diallo');
    await tester.enterText(find.byKey(const Key('profileEmail')), 'awa@exemple.sn');
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();
    expect(repo.profile.fullName, 'Awa Ndiaye Diallo');
    expect(repo.profile.email, 'awa@exemple.sn');
    expect(find.text('awa@exemple.sn'), findsOneWidget);
  });

  testWidgets('déconnecter tous les appareils', (tester) async {
    phoneSize(tester);
    final (c, repo) = await pumpSama(tester, location: '/account');
    await tester.ensureVisible(find.text('Déconnecter tous les appareils'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Déconnecter tous les appareils'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tout déconnecter'));
    await tester.pumpAndSettle();
    expect(repo.loggedOutEverywhere, isTrue);
    expect(c.read(authProvider).value!.signedIn, isFalse);
  });

  testWidgets('bouton Vendre au centre : ouvre la caisse et compte les articles du panier', (tester) async {
    phoneSize(tester);
    final (c, _) = await pumpSama(tester);
    expect(find.byKey(const Key('cart_badge')), findsNothing);
    await tester.tap(find.byType(SellButton));
    await tester.pumpAndSettle();
    expect(routerOf(c).state.uri.path, '/pos');
    c.read(cartProvider.notifier).add(demoProducts[1]);
    c.read(cartProvider.notifier).add(demoProducts[1]);
    await tester.pump();
    expect(find.descendant(of: find.byKey(const Key('cart_badge')), matching: find.text('2')), findsOneWidget);
  });
}
