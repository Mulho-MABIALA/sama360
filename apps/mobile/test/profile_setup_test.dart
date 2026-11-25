import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/models.dart';
import 'package:sama360/features/auth/auth_controller.dart';

import 'helpers.dart';

/// Première connexion : prénom et nom séparés, réunis pour le compte.
void main() {
  setUpAll(loadTestFonts);

  testWidgets('prénom et nom obligatoires, enregistrés ensemble', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo()
      ..profile = const Me(id: 'u1', phone: '+221771234567', fullName: null, createdAt: null, businesses: []);
    await pumpSama(tester, repo: repo, auth: _NoNameAuth.new);
    expect(find.text('Quel est votre nom ?'), findsOneWidget);

    await tester.tap(find.byKey(const Key('profile_continue')));
    await tester.pumpAndSettle();
    expect(find.text('Entrez votre prénom'), findsOneWidget);
    expect(find.text('Entrez votre nom'), findsOneWidget);
    expect(repo.savedName, isNull);

    await tester.enterText(find.byKey(const Key('firstName')), '  Awa ');
    await tester.enterText(find.byKey(const Key('lastName')), 'Ndiaye');
    await tester.tap(find.byKey(const Key('profile_continue')));
    await tester.pumpAndSettle();
    expect(repo.savedName, 'Awa Ndiaye');
  });
}

const _noName = Me(id: 'u1', phone: '+221771234567', fullName: null, createdAt: null, businesses: []);

class _NoNameAuth extends AuthController {
  @override
  Future<AuthState> build() async => const AuthState(me: _noName);
}
