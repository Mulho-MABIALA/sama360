import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/features/auth/auth_controller.dart';
import 'package:sama360/features/profile/closure_screens.dart';

import 'helpers.dart';

void main() {
  setUpAll(loadTestFonts);

  test('nom de la boutique retapé : casse, accents et espaces ignorés', () {
    expect(sameBusinessName('  awa   beaute ', 'Awa Beauté'), isTrue);
    expect(sameBusinessName('Awa', 'Awa Beauté'), isFalse);
    expect(sameBusinessName('', ''), isFalse);
  });

  testWidgets('propriétaire : supprimer la boutique (nom retapé), puis la restaurer', (tester) async {
    phoneSize(tester);
    final (c, repo) = await pumpSama(tester, location: '/account');
    await tester.ensureVisible(find.byKey(const Key('delete_business_row')));
    await tester.pumpAndSettle();
    expect(find.text('Supprimer Awa Beauté'), findsOneWidget);
    await tester.tap(find.byKey(const Key('delete_business_row')));
    await tester.pumpAndSettle();
    expect(find.text('Vous allez supprimer « Awa Beauté »'), findsOneWidget);

    // Bouton bloqué tant que le nom n'est pas retapé
    final button = find.byKey(const Key('delete_business'));
    expect(tester.widget<ButtonStyleButton>(button).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('confirm_business_name')), 'Awa');
    await tester.pump();
    expect(tester.widget<ButtonStyleButton>(button).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('confirm_business_name')), 'awa beaute');
    await tester.pump();
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(repo.deletedNames, ['awa beaute']);

    // Plus d'entreprise : écran de création, avec la boutique à restaurer
    expect(routerOf(c).state.uri.path, '/business');
    await tester.dragUntilVisible(find.byKey(const Key('restore_b1')), find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(find.text('Effacée dans 30 jours'), findsOneWidget);
    await tester.tap(find.byKey(const Key('restore_b1')));
    await tester.pumpAndSettle();
    expect(repo.restored, ['b1']);
    expect(c.read(authProvider).value?.businessId, 'b1');
    expect(routerOf(c).state.uri.path, '/');
  });

  testWidgets('compte : taper SUPPRIMER, puis retour à la connexion', (tester) async {
    phoneSize(tester);
    final (c, repo) = await pumpSama(tester, location: '/account/delete');
    expect(find.text('Votre boutique « Awa Beauté » est supprimée avec lui.'), findsOneWidget);
    final button = find.byKey(const Key('delete_account'));
    expect(tester.widget<ButtonStyleButton>(button).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('confirm_account_word')), 'supprimer');
    await tester.pump();
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(repo.accountDeletions, ['supprimer']);
    expect(c.read(authProvider).value?.signedIn, isFalse);
    expect(routerOf(c).state.uri.path, '/login');
  });
}
