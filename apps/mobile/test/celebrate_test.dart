import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/celebrate.dart';

void main() {
  test('ventes à fêter', () {
    expect(saleMilestone('VEN-2026-0001'), 'Votre première vente sur Sama360 !');
    expect(saleMilestone('VEN-2026-0100'), startsWith('100'));
    expect(saleMilestone('VEN-2026-0042'), isNull);
    expect(saleMilestone('sans-numero'), isNull);
  });

  testWidgets('coche et confettis sans erreur (animations coupées en test)', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Center(child: SuccessCheck()),
              Positioned.fill(child: ConfettiBurst()),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SuccessCheck), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
