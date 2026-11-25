import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/router.dart';

import 'helpers.dart';

/// Une dépense ajoutée depuis l'accueil apparaît dans les rapports (ils sont rechargés).
void main() {
  setUpAll(loadTestFonts);

  testWidgets('dépense : les rapports sont rechargés', (tester) async {
    phoneSize(tester);
    final (c, repo) = await pumpSama(tester, location: '/reports');
    final before = repo.reportRequests.length;
    expect(before, greaterThan(0));

    c.read(routerProvider).go('/');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dépense').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Montant'), '2000');
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();
    expect(repo.expenses.single.$2, 2000);

    c.read(routerProvider).go('/reports');
    await tester.pumpAndSettle();
    expect(repo.reportRequests.length, greaterThan(before));
  });
}
