import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/display.dart';
import 'helpers.dart';

void main() {
  setUpAll(() async {
    await initializeDateFormatting('fr');
  });

  testWidgets('mode simple : 4 grandes actions, plus d’outils, retour à l’accueil complet', (tester) async {
    phoneSize(tester);
    final (c, _) = await pumpSama(tester);
    expect(find.text('Vos services'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const Key('simple_mode_on')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -200)); // sous la barre du bas
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('simple_mode_on')));
    await tester.pumpAndSettle();
    expect(c.read(displaySettingsProvider).simple, isTrue);
    expect(find.text('Vos services'), findsNothing);
    expect(find.text('À la une'), findsNothing);
    await tester.scrollUntilVisible(find.byKey(const Key('simple_day')), -300, scrollable: find.byType(Scrollable).first);
    for (final k in ['simple_sell', 'simple_product', 'simple_owed', 'simple_day']) {
      expect(find.byKey(Key(k)), findsOneWidget);
    }

    // Tous les outils restent accessibles
    await tester.scrollUntilVisible(find.byKey(const Key('simple_more')), 300, scrollable: find.byType(Scrollable).first);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -200));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('simple_more')));
    await tester.pumpAndSettle();
    expect(find.text('Tous les services'), findsOneWidget);
    await tester.tapAt(const Offset(20, 40)); // fermer
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.byKey(const Key('simple_owed')), -300, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(const Key('simple_owed')));
    await tester.pumpAndSettle();
    expect(find.text('On vous doit'), findsWidgets); // écran Clients

    c.read(displaySettingsProvider.notifier).setSimple(false);
    await tester.pumpAndSettle();
  });

  testWidgets('mode simple depuis Mon compte', (tester) async {
    phoneSize(tester);
    final (c, _) = await pumpSama(tester, location: '/account');
    await tester.scrollUntilVisible(
      find.byKey(const Key('simple_mode_row')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -200));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('simple_mode_row')));
    await tester.pumpAndSettle();
    expect(c.read(displaySettingsProvider).simple, isTrue);
    expect(find.text('Activé'), findsOneWidget);
  });
}
