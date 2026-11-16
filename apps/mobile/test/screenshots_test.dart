@Tags(['screenshots'])
library;

/// Captures des écrans (390 × 844) pour relecture visuelle.
/// Générer : SAMA_SCREENSHOTS=1 flutter test test/screenshots_test.dart --update-goldens
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/api/session_store.dart';
import 'package:sama360/core/providers.dart';
import 'package:sama360/features/auth/auth_controller.dart';
import 'package:sama360/main.dart';

import 'helpers.dart';

class _SignedOut extends AuthController {
  @override
  Future<AuthState> build() async => const AuthState();
}

Future<void> _shot(WidgetTester tester, String name) async {
  await tester.pumpAndSettle();
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('screenshots/$name.png'));
}

void main() {
  if (Platform.environment['SAMA_SCREENSHOTS'] != '1') return; // rendu dépendant de la machine
  setUpAll(loadTestFonts);

  testWidgets('connexion', (tester) async {
    phoneSize(tester);
    await initializeDateFormatting('fr');
    final c = ProviderContainer(
      overrides: [
        sessionStoreProvider.overrideWithValue(MemorySessionStore()),
        authProvider.overrideWith(_SignedOut.new),
      ],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const SamaApp(googleFonts: false)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '77 123 45 67');
    await _shot(tester, '1_connexion');
  });

  testWidgets('accueil', (tester) async {
    phoneSize(tester);
    await pumpSama(tester);
    await _shot(tester, '2_accueil');
  });

  testWidgets('accueil (bas, carrousel)', (tester) async {
    phoneSize(tester);
    await pumpSama(tester);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -420));
    await _shot(tester, '2b_accueil_carrousel');
  });

  testWidgets('caisse', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/pos');
    await tester.tap(find.text('Beurre de karité 250 g'));
    await tester.tap(find.text('Beurre de karité 250 g'));
    await tester.tap(find.text('Huile de coco 500 ml'));
    await tester.tap(find.text('Wave'));
    await _shot(tester, '3_caisse');
  });

  testWidgets('stock', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/stock');
    await _shot(tester, '4_stock');
  });

  testWidgets('credits', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/customers');
    await _shot(tester, '5_credits');
  });

  testWidgets('fiche client', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/customers/k1');
    await _shot(tester, '6_fiche_client');
  });

  testWidgets('nouveau produit', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/stock');
    await tester.tap(find.text('Nouveau produit'));
    await _shot(tester, '7_nouveau_produit');
  });

  testWidgets('reçu', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/sales/s2');
    await _shot(tester, '9_recu');
  });

  testWidgets('ventes du jour', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/sales');
    await _shot(tester, '9b_ventes_du_jour');
  });
}
