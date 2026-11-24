import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/widgets.dart';
import 'package:sama360/features/team/team_screen.dart' show openUrlProvider;
import 'helpers.dart';

void main() {
  setUpAll(() async {
    await initializeDateFormatting('fr');
  });

  testWidgets('connexion : liens vers les conditions et la confidentialité', (tester) async {
    final opened = <Uri>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LegalNotice(baseUrl: 'https://sama360-api.onrender.com/', open: opened.add),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('legal_terms')));
    await tester.tap(find.byKey(const Key('legal_privacy')));
    expect(opened.map((u) => u.toString()), [
      'https://sama360-api.onrender.com/cgu',
      'https://sama360-api.onrender.com/confidentialite',
    ]);
  });

  testWidgets('Mon compte : conditions, confidentialité, page de suppression', (tester) async {
    phoneSize(tester);
    final opened = <Uri>[];
    await pumpSama(
      tester,
      location: '/account',
      overrides: [
        openUrlProvider.overrideWithValue((u) async {
          opened.add(u);
          return true;
        }),
      ],
    );
    await tester.scrollUntilVisible(find.byKey(const Key('legal_row')), 300, scrollable: find.byType(Scrollable).first);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -200));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('legal_row')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Supprimer mon compte (page web)'));
    await tester.pumpAndSettle();
    expect(opened.single.path, '/suppression-compte');
  });
}
