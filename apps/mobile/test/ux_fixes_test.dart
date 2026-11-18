// Corrections UX demandées après les essais sur iPhone (18/11/2026).
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/celebrate.dart';
import 'package:sama360/core/theme.dart';
import 'package:sama360/core/widgets.dart';

import 'helpers.dart';

void main() {
  setUpAll(loadTestFonts);

  testWidgets('le rond de validation garde sa taille même dans un conteneur étiré', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox(
          width: 360,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [SuccessCheck()]),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(SuccessCheck)).height, 72);
    final paint = find.descendant(of: find.byType(SuccessCheck), matching: find.byType(CustomPaint)).first;
    expect(tester.getSize(paint).height, lessThanOrEqualTo(72));
  });

  testWidgets('Annuler est neutre, une action qui supprime ou déconnecte est rouge', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Row(
          children: [
            CancelButton(onPressed: () {}),
            ConfirmButton(label: 'Déconnexion', danger: true, onPressed: () {}),
            ConfirmButton(label: 'Clôturer', onPressed: () {}),
          ],
        ),
      ),
    );
    Color? bg(Finder f) => tester.widget<ButtonStyleButton>(f).style?.backgroundColor?.resolve({});
    Color? fg(Finder f) => tester.widget<ButtonStyleButton>(f).style?.foregroundColor?.resolve({});
    expect(fg(find.byType(TextButton)), AppColors.ink);
    expect(bg(find.widgetWithText(FilledButton, 'Déconnexion')), AppColors.danger);
    expect(bg(find.widgetWithText(FilledButton, 'Clôturer')), AppColors.green);
  });

  testWidgets('reçu sans logo : le propriétaire est invité à ajouter son logo', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/sales/s2');
    await tester.scrollUntilVisible(find.byKey(const Key('receipt_add_logo')), 200);
    expect(find.text('Ajoutez votre logo'), findsOneWidget);
    expect(find.textContaining('en haut de vos reçus'), findsOneWidget);
  });
}
