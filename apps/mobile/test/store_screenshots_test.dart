@Tags(['screenshots'])
library;

/// Captures pour la fiche Play Store (1080 × 1920, téléphone).
/// Générer : SAMA_SCREENSHOTS=1 flutter test test/store_screenshots_test.dart --update-goldens
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/models.dart';
import 'package:sama360/core/providers.dart';
import 'package:sama360/features/home/monument.dart';

import 'helpers.dart';

void _storeSize(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 1920);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
}

Future<void> _shot(WidgetTester tester, String name) async {
  debugDisableShadows = false;
  try {
    for (final e in find.byType(Image).evaluate().toList()) {
      await tester.runAsync(() => precacheImage((e.widget as Image).image, e));
    }
    for (final r in tester.allRenderObjects) {
      r.markNeedsPaint();
    }
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('screenshots/store/$name.png'));
  } finally {
    debugDisableShadows = true;
  }
}

const _tshirt = Product(
  id: 'ts',
  name: 'T-shirt col V',
  price: 5000,
  cost: 2500,
  variantAxes: [
    VariantAxis('Couleur', ['Noir', 'Blanc', 'Rouge']),
    VariantAxis('Taille', ['M', 'L', 'XL']),
  ],
);

Product _v(String c, String t) => Product(
  id: 'ts-$c-$t',
  name: 'T-shirt col V · $c · $t',
  price: t == 'XL' ? 5500 : 5000,
  cost: 2500,
  parentId: 'ts',
  options: {'Couleur': c, 'Taille': t},
);

void main() {
  if (Platform.environment['SAMA_SCREENSHOTS'] != '1') return;
  setUpAll(() async {
    await loadTestFonts();
    await initializeDateFormatting('fr');
    // Titres de la vitrine en police à empattements (comme sur le téléphone)
    final serif = FontLoader('serif');
    for (final f in ['DejaVuSerif.ttf', 'DejaVuSerif-Italic.ttf']) {
      final bytes = File('/usr/share/fonts/truetype/dejavu/$f').readAsBytesSync();
      serif.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await serif.load();
  });

  testWidgets('accueil', (tester) async {
    _storeSize(tester);
    final day = DateTime(2026, 11, 16);
    await pumpSama(tester, overrides: [monumentDateProvider.overrideWithValue(day)]);
    final ctx = tester.element(find.byType(MonumentBackdrop));
    await tester.runAsync(() => precacheImage(AssetImage(monumentOfDay(day).asset), ctx));
    await _shot(tester, '1_accueil');
  });

  testWidgets('caisse', (tester) async {
    _storeSize(tester);
    await pumpSama(tester, location: '/pos');
    await tester.tap(find.text('Beurre de karité 250 g'));
    await tester.tap(find.text('Beurre de karité 250 g'));
    await tester.tap(find.text('Huile de coco 500 ml'));
    await _shot(tester, '2_caisse');
  });

  testWidgets('variantes', (tester) async {
    _storeSize(tester);
    final vs = [
      for (final c in ['Noir', 'Blanc', 'Rouge'])
        for (final t in ['M', 'L', 'XL']) _v(c, t),
    ];
    final repo = FakeRepo()
      ..extraProducts = [_tshirt, ...vs]
      ..extraStock = [
        for (final v in vs)
          StockItem(
            productId: v.id,
            name: v.name,
            price: v.price,
            cost: v.cost,
            threshold: 1,
            onHand: v.id.contains('Rouge-L') ? 0 : 4,
            low: false,
          ),
      ];
    await pumpSama(tester, location: '/pos', repo: repo);
    await tester.enterText(find.byType(TextField).first, 'shirt');
    await tester.pumpAndSettle();
    await tester.tap(find.text('T-shirt col V'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('opt_Couleur_Rouge')));
    await tester.tap(find.byKey(const Key('opt_Taille_M')));
    await _shot(tester, '3_variantes');
  });

  testWidgets('credits', (tester) async {
    _storeSize(tester);
    await pumpSama(tester, location: '/customers/k1');
    await _shot(tester, '4_credit_client');
  });

  testWidgets('stock', (tester) async {
    _storeSize(tester);
    await pumpSama(tester, location: '/stock');
    await _shot(tester, '5_stock');
  });

  testWidgets('rapports', (tester) async {
    _storeSize(tester);
    await pumpSama(tester, location: '/reports');
    await _shot(tester, '6_rapports');
  });

  testWidgets('boutique', (tester) async {
    _storeSize(tester);
    await pumpSama(
      tester,
      location: '/shop',
      repo: FakeRepo()..shopTagline = 'Des soins naturels pour chaque peau',
      overrides: [apiBaseUrlProvider.overrideWithValue('https://sama360-api.onrender.com')],
    );
    await _shot(tester, '7_boutique');
  });

  testWidgets('reçu', (tester) async {
    _storeSize(tester);
    await pumpSama(tester, location: '/sales/s2');
    await _shot(tester, '8_recu');
  });
}
