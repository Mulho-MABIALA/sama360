import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/display.dart';
import 'package:sama360/core/theme.dart';

import 'helpers.dart';

void main() {
  setUpAll(loadTestFonts);

  test('couleurs hexadécimales', () {
    expect(parseHexColor('#0a7e4f'), const Color(0xFF0A7E4F));
    expect(parseHexColor('nope'), isNull);
    expect(toHexColor(const Color(0xFF1565C0)), '#1565C0');
  });

  testWidgets('par défaut : fond clair', (tester) async {
    phoneSize(tester);
    final (c, _) = await pumpSama(tester);
    expect(c.read(displaySettingsProvider).mode, ThemeMode.light);
    expect(AppColors.isDark, isFalse);
  });

  testWidgets('Affichage : mode sombre, grands caractères, retour au clair', (tester) async {
    phoneSize(tester);
    final (c, _) = await pumpSama(tester, location: '/settings/display');
    await tester.tap(find.text('Sombre'));
    await tester.pumpAndSettle();
    expect(AppColors.isDark, isTrue);
    expect(Theme.of(tester.element(find.text('Affichage'))).brightness, Brightness.dark);

    final before = tester.getSize(find.byKey(const Key('display_preview'))).height;
    await tester.tap(find.text('Grands caractères'));
    await tester.pumpAndSettle();
    expect(c.read(displaySettingsProvider).largeText, isTrue);
    expect(tester.getSize(find.byKey(const Key('display_preview'))).height, greaterThan(before));

    await tester.tap(find.text('Clair'));
    await tester.pumpAndSettle();
    expect(AppColors.isDark, isFalse);
  });

  testWidgets('couleur de la boutique : enregistrée et appliquée à l’app', (tester) async {
    phoneSize(tester);
    final (_, repo) = await pumpSama(tester, location: '/settings/display');
    await tester.scrollUntilVisible(find.text('Océan'), 200);
    await tester.tap(find.text('Océan'));
    await tester.pumpAndSettle();
    expect(repo.brandColorUpdates, ['#1565C0']);
    expect(AppColors.palette.brand, const Color(0xFF1565C0));
    expect(find.text('Couleur de la boutique enregistrée'), findsOneWidget);

    await tester.tap(find.text('Émeraude'));
    await tester.pumpAndSettle();
    expect(repo.brandColorUpdates.last, isNull); // retour au vert Sama360
  });

  testWidgets('œil : masque les montants partout, et les réaffiche', (tester) async {
    phoneSize(tester);
    final (c, _) = await pumpSama(tester);
    expect(find.textContaining('86'), findsWidgets);
    await tester.tap(find.byTooltip('Masquer les montants'));
    await tester.pumpAndSettle();
    expect(c.read(displaySettingsProvider).hideAmounts, isTrue);
    expect(find.textContaining('•••••'), findsWidgets);
    expect(find.textContaining('86'), findsNothing);

    // Ailleurs aussi : la liste des clients
    routerOf(c).go('/customers');
    await tester.pumpAndSettle();
    expect(find.textContaining('•••••'), findsWidgets);
    await tester.tap(find.byTooltip('Afficher les montants').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('•••••'), findsNothing);
  });
}
