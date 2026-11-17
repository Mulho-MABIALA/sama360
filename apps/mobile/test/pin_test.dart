import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sama360/core/biometrics.dart';
import 'package:sama360/core/format.dart';
import 'package:sama360/core/pin_lock.dart';

import 'helpers.dart';

Future<void> typePin(WidgetTester tester, String pin) async {
  for (final d in pin.split('')) {
    await tester.tap(find.byKey(Key('pin_key_$d')));
    await tester.pump();
  }
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadTestFonts);
  sensitiveAndBiometricTests();

  group('code secret (logique)', () {
    test('codes trop faciles refusés', () {
      expect(weakPinReason('0000'), isNotNull);
      expect(weakPinReason('1234'), isNotNull);
      expect(weakPinReason('9876'), isNotNull);
      expect(weakPinReason('2580'), isNull);
      expect(weakPinReason('1325'), isNull);
    });

    test('empreinte salée : jamais le code en clair, vérification exacte', () {
      final a = hashPin('2580');
      final b = hashPin('2580');
      expect(a, isNot(contains('2580')));
      expect(a, isNot(b)); // sel différent à chaque fois
      expect(checkPin('2580', a), isTrue);
      expect(checkPin('2581', a), isFalse);
      expect(checkPin('2580', 'n’importe quoi'), isFalse);
    });

    test('code enregistré : lecture et écriture', () {
      const p = StoredPin(userId: 'u1', hash: 'v1\$a\$b', failures: 2);
      final back = StoredPin.decode(p.encode())!;
      expect((back.userId, back.hash, back.failures), ('u1', 'v1\$a\$b', 2));
      expect(StoredPin.decode('{cassé'), isNull);
    });
  });

  group('écran du code secret', () {
    testWidgets('première connexion : créer le code (refus des codes faciles, confirmation)', (tester) async {
      phoneSize(tester);
      final store = MemoryPinStore();
      await pumpSama(tester, pinStore: store);
      expect(find.text('Créez votre code secret'), findsOneWidget);

      await typePin(tester, '1234');
      expect(find.text('Évitez les suites comme 1234.'), findsOneWidget);

      await typePin(tester, '2580');
      expect(find.text('Confirmez votre code'), findsOneWidget);
      await typePin(tester, '2581');
      expect(find.text('Les deux codes ne correspondent pas. Recommencez.'), findsOneWidget);
      expect(find.text('Créez votre code secret'), findsOneWidget);

      await typePin(tester, '2580');
      await typePin(tester, '2580');
      expect(find.byKey(const Key('pin_title')), findsNothing);
      expect(store.pin!.userId, 'u1');
      expect(checkPin('2580', store.pin!.hash), isTrue);
    });

    testWidgets('ouverture : bon code après des erreurs ; on revient où on était', (tester) async {
      phoneSize(tester);
      final store = MemoryPinStore(StoredPin(userId: 'u1', hash: hashPin('2580')));
      final (c, _) = await pumpSama(tester, location: '/customers', pinStore: store);
      expect(find.text('Bonjour Awa'), findsOneWidget);
      expect(find.text('Code secret oublié ?'), findsOneWidget);

      await typePin(tester, '1111');
      expect(find.text('Code incorrect.'), findsOneWidget);
      await typePin(tester, '1111');
      expect(find.text('Code incorrect. Plus que 3 essais.'), findsOneWidget);

      await typePin(tester, '2580');
      expect(find.byKey(const Key('pin_title')), findsNothing);
      expect(routerOf(c).state.uri.path, '/customers');
      expect(store.pin!.failures, 0);

      // Retour après une absence : verrouillé à nouveau, même écran ensuite
      c.read(pinLockProvider.notifier).lock();
      await tester.pumpAndSettle();
      expect(find.text('Bonjour Awa'), findsOneWidget);
      await tester.tap(find.byKey(const Key('pin_key_Effacer')));
      await typePin(tester, '2580');
      expect(routerOf(c).state.uri.path, '/customers');
    });

    testWidgets('5 erreurs : déconnexion et code effacé', (tester) async {
      phoneSize(tester);
      final store = MemoryPinStore(StoredPin(userId: 'u1', hash: hashPin('2580'), failures: 3));
      final (c, _) = await pumpSama(tester, pinStore: store);
      await typePin(tester, '1111');
      expect(find.text('Code incorrect. Plus que 1 essai.'), findsOneWidget);
      await typePin(tester, '1111');
      await tester.pumpAndSettle();
      expect(routerOf(c).state.uri.path, '/login');
      expect(store.pin, isNull);
    });

    testWidgets('code oublié : confirmation puis retour à la connexion par SMS', (tester) async {
      phoneSize(tester);
      final store = MemoryPinStore(StoredPin(userId: 'u1', hash: hashPin('2580')));
      final (c, _) = await pumpSama(tester, pinStore: store);
      await tester.tap(find.text('Code secret oublié ?'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Reconnectez-vous avec le code reçu par SMS'), findsOneWidget);
      await tester.tap(find.text('Annuler'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pin_key_5')), findsOneWidget);

      await tester.tap(find.text('Code secret oublié ?'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('forgot_confirm')));
      await tester.pumpAndSettle();
      expect(routerOf(c).state.uri.path, '/login');
      expect(store.pin, isNull);
    });

    testWidgets('changer de code depuis le profil', (tester) async {
      phoneSize(tester);
      final store = MemoryPinStore(StoredPin(userId: 'u1', hash: hashPin('2580')));
      final (c, _) = await pumpSama(tester, location: '/account', pinStore: store);
      await typePin(tester, '2580');

      await tester.ensureVisible(find.text('Changer mon code secret'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Changer mon code secret'));
      await tester.pumpAndSettle();
      expect(find.text('Code secret actuel'), findsOneWidget);
      await typePin(tester, '9999');
      expect(find.text('Code incorrect.'), findsOneWidget);
      await typePin(tester, '2580');
      expect(find.text('Nouveau code secret'), findsOneWidget);
      await typePin(tester, '4071');
      await typePin(tester, '4071');
      expect(routerOf(c).state.uri.path, '/account');
      expect(checkPin('4071', store.pin!.hash), isTrue);
    });

    testWidgets('fenêtre basse et large (navigateur) : pas de débordement', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(760, 600);
      addTearDown(tester.view.reset);
      await pumpSama(tester, pinStore: MemoryPinStore());
      expect(find.text('Créez votre code secret'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('pin_key_0')), findsOneWidget);
      expect(find.text('Se déconnecter'), findsOneWidget);
    });
  });
}

void sensitiveAndBiometricTests() {
  StoredPin pin({bool bio = false}) => StoredPin(userId: 'u1', hash: hashPin('2580'), biometric: bio);

  group('actions sensibles', () {
    testWidgets('annuler une vente : motif, puis code secret (erreur puis bon code)', (tester) async {
      phoneSize(tester);
      final (_, repo) = await pumpSama(tester, location: '/sales/s2', pinStore: MemoryPinStore(pin()));
      await typePin(tester, '2580'); // ouverture de l'app

      await tester.tap(find.byTooltip('Annuler la vente'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('voidReason')), 'Erreur de saisie');
      await tester.tap(find.text('Oui, annuler'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('confirm_pin_title')), findsOneWidget);
      expect(find.textContaining('Annuler la vente VEN-2026-0042'), findsOneWidget);

      await typePin(tester, '1111');
      expect(find.byKey(const Key('confirm_pin_error')), findsOneWidget);
      expect(repo.voidedSales, isEmpty);
      await typePin(tester, '2580');
      expect(repo.voidedSales, {'s2': 'Erreur de saisie'});
      expect(find.text('VENTE ANNULÉE'), findsOneWidget);
    });

    testWidgets('« Annuler » dans la feuille du code : rien n’est fait', (tester) async {
      phoneSize(tester);
      final (_, repo) = await pumpSama(tester, location: '/sales/s2', pinStore: MemoryPinStore(pin()));
      await typePin(tester, '2580');
      await tester.tap(find.byTooltip('Annuler la vente'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('voidReason')), 'Client a rendu');
      await tester.tap(find.text('Oui, annuler'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Annuler').last);
      await tester.pumpAndSettle();
      expect(repo.voidedSales, isEmpty);
      expect(find.byKey(const Key('confirm_pin_title')), findsNothing);
    });

    testWidgets('empreinte activée : confirmée sans taper le code', (tester) async {
      phoneSize(tester);
      final bio = FakeBiometrics(kindValue: BiometricKind.fingerprint);
      final (_, repo) = await pumpSama(
        tester,
        location: '/sales/s2',
        pinStore: MemoryPinStore(pin(bio: true)),
        biometrics: bio,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pin_title')), findsNothing); // ouverte à l'empreinte
      await tester.tap(find.byTooltip('Annuler la vente'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('voidReason')), 'Doublon');
      await tester.tap(find.text('Oui, annuler'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('confirm_pin_title')), findsNothing);
      expect(repo.voidedSales, {'s2': 'Doublon'});
      expect(bio.prompts, ['Ouvrir Sama360', 'Annuler la vente VEN-2026-0042 (${money(demoSale.total)})']);
    });
  });

  group('empreinte / Face ID', () {
    testWidgets('non reconnue : on retombe sur le code, bouton empreinte pour réessayer', (tester) async {
      phoneSize(tester);
      final bio = FakeBiometrics(kindValue: BiometricKind.fingerprint, result: false);
      await pumpSama(tester, pinStore: MemoryPinStore(pin(bio: true)), biometrics: bio);
      await tester.pumpAndSettle();
      expect(find.text('Bonjour Awa'), findsOneWidget);
      expect(find.byKey(const Key('pin_key_Empreinte digitale')), findsOneWidget);

      await tester.tap(find.byKey(const Key('pin_key_Empreinte digitale')));
      await tester.pumpAndSettle();
      expect(find.text('Non reconnu. Tapez votre code secret.'), findsOneWidget);

      bio.result = true;
      await tester.tap(find.byKey(const Key('pin_key_Empreinte digitale')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pin_title')), findsNothing);
    });

    testWidgets('activer depuis le profil (après vérification de l’empreinte)', (tester) async {
      phoneSize(tester);
      final store = MemoryPinStore(pin());
      final bio = FakeBiometrics(kindValue: BiometricKind.face);
      await pumpSama(tester, location: '/account', pinStore: store, biometrics: bio);
      expect(bio.prompts, isEmpty); // pas activé : pas de demande à l'ouverture
      expect(find.byKey(const Key('pin_key_Face ID')), findsNothing);
      await typePin(tester, '2580');

      await tester.ensureVisible(find.byKey(const Key('biometric_row')));
      await tester.pumpAndSettle();
      expect(find.text('Face ID'), findsOneWidget);
      await tester.tap(find.byKey(const Key('biometric_row')));
      await tester.pumpAndSettle();
      expect(store.pin!.biometric, isTrue);
      expect(bio.prompts.single, 'Activer Face ID pour Sama360');
      expect(find.text('Activé'), findsOneWidget);
    });

    testWidgets('téléphone sans capteur : rien n’est proposé', (tester) async {
      phoneSize(tester);
      await pumpSama(tester, location: '/account', pinStore: MemoryPinStore(pin()));
      await typePin(tester, '2580');
      expect(find.byKey(const Key('biometric_row')), findsNothing);
    });
  });
}
