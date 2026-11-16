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
import 'package:sama360/core/models.dart';
import 'package:sama360/core/offline/pending_sales.dart';
import 'package:sama360/core/providers.dart';
import 'package:sama360/features/auth/auth_controller.dart';
import 'package:sama360/main.dart';

import 'helpers.dart';

class _SignedOut extends AuthController {
  @override
  Future<AuthState> build() async => const AuthState();
}

Future<void> _shot(WidgetTester tester, String name) async {
  debugDisableShadows = false; // ombres floues réelles, comme sur le téléphone
  try {
    for (final r in tester.allRenderObjects) {
      r.markNeedsPaint();
    }
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('screenshots/$name.png'));
  } finally {
    debugDisableShadows = true;
  }
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

  testWidgets('profil', (tester) async {
    phoneSize(tester);
    await pumpSama(tester);
    await tester.tap(find.text('AD').first);
    await _shot(tester, '8_profil');
  });

  testWidgets('profil (bas)', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/account');
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -700));
    await _shot(tester, '8b_profil_bas');
  });

  Future<void> offlineSales(WidgetTester tester) async {
    final (c, repo) = await pumpSama(tester, location: '/pos');
    repo.offline = true;
    for (final (id, p, q) in [('o1', demoProducts[0], 2.0), ('o2', demoProducts[2], 1.0)]) {
      await c.read(pendingSalesProvider.notifier).checkout(
        id: id,
        businessId: 'b1',
        lines: [(product: p, quantity: q)],
        payments: [(method: PayMethod.cash, amount: (p.price * q).round())],
        total: (p.price * q).round(),
      );
    }
    c.read(apiClientProvider).online.value = false; // le client a constaté la coupure
    await tester.pumpAndSettle();
  }

  testWidgets('hors ligne : caisse', (tester) async {
    phoneSize(tester);
    await offlineSales(tester);
    await _shot(tester, '10_hors_ligne_caisse');
  });

  testWidgets('hors ligne : accueil', (tester) async {
    phoneSize(tester);
    await offlineSales(tester);
    await tester.tap(find.text('Accueil'));
    await tester.pumpAndSettle();
    await _shot(tester, '10b_hors_ligne_accueil');
  });

  testWidgets('hors ligne : historique', (tester) async {
    phoneSize(tester);
    await offlineSales(tester);
    await tester.tap(find.byTooltip("Ventes d'aujourd'hui"));
    await _shot(tester, '10c_hors_ligne_historique');
  });

  testWidgets('équipe', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/team');
    await _shot(tester, '11_equipe');
  });

  testWidgets('équipe : invitation', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/team');
    await tester.tap(find.text('Inviter'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('invitePhone')), '70 123 45 67');
    await tester.enterText(find.byKey(const Key('inviteName')), 'Ibou Ndiaye');
    FocusManager.instance.primaryFocus?.unfocus();
    await _shot(tester, '11b_equipe_invitation');
  });

  testWidgets('accueil : vendeurs du jour', (tester) async {
    phoneSize(tester);
    await pumpSama(tester);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -900));
    await _shot(tester, '11c_vendeurs_du_jour');
  });
}
