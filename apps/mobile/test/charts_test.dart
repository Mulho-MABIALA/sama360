import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sama360/core/charts.dart';
import 'package:sama360/core/skeleton.dart';
import 'package:sama360/core/widgets.dart';

import 'helpers.dart';

void main() {
  setUpAll(loadTestFonts);

  test('tendance sur 7 jours', () {
    expect(weekTrend([100, 100, 100, 100, 100, 100, 100], 600), closeTo(0.1667, 0.001));
    expect(weekTrend([0, 0, 0, 0, 0, 0, 0], 0), isNull);
    expect(trendLabel(0.12), '+12 %');
    expect(trendLabel(-0.084), '−8 %');
    expect(trendLabel(0.001), '=');
  });

  testWidgets('accueil : courbe des 7 jours et tendance', (tester) async {
    phoneSize(tester);
    await pumpSama(tester);
    expect(find.byType(SalesSparkline), findsOneWidget);
    // 481 000 F cette semaine contre 427 000 F : +13 %
    expect(find.descendant(of: find.byKey(const Key('week_trend')), matching: find.text('+13 %')), findsOneWidget);
  });

  testWidgets('la courbe se dessine même avec des jours sans vente', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            child: SalesSparkline(values: [0, 0, 0, 0, 0, 0, 0], color: Colors.green),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('chargement : squelette au lieu du rond qui tourne', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AsyncView<int>(value: const AsyncLoading(), data: (v) => Text('$v')),
        ),
      ),
    );
    expect(find.byType(SkeletonList), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
