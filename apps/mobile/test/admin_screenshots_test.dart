@Tags(['screenshots'])
library;

/// Captures du back office (téléphone et grand écran) pour relecture visuelle.
/// Générer : SAMA_SCREENSHOTS=1 flutter test test/admin_screenshots_test.dart --update-goldens
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/countries.dart';

import 'admin_test.dart' show adminRepo, desktopSize, req;
import 'helpers.dart';

Future<void> _shot(WidgetTester tester, String name) async {
  debugDisableShadows = false;
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
  if (Platform.environment['SAMA_SCREENSHOTS'] != '1') return;
  setUpAll(() async {
    await loadTestFonts();
    await initializeDateFormatting('fr');
  });

  for (final wide in [false, true]) {
    final size = wide ? 'bureau' : 'tel';
    testWidgets('back office $size', (tester) async {
      wide ? desktopSize(tester) : phoneSize(tester);
      final repo = adminRepo()..adminQueue.addAll([req('a', 'Koné Market', Country.ci)]);
      await pumpAdmin(tester, repo: repo);
      await _shot(tester, 'admin_${size}_1_tableau');
      await tester.tap(find.byKey(Key(wide ? 'admin_side_merchants' : 'admin_tab_merchants')));
      await tester.pumpAndSettle();
      await _shot(tester, 'admin_${size}_2_commercants');
      await tester.tap(find.byKey(const Key('admin_biz_b1')));
      await tester.pumpAndSettle();
      await _shot(tester, 'admin_${size}_3_fiche');
      await tester.tap(find.byTooltip('Retour'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key(wide ? 'admin_side_payments' : 'admin_tab_payments')));
      await tester.pumpAndSettle();
      await _shot(tester, 'admin_${size}_4_paiements');
    });
  }
}
