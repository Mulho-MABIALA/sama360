import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
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
  });
}
