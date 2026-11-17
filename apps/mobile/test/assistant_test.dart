import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/api/api_client.dart';
import 'package:sama360/features/assistant/assistant_screen.dart';

import 'helpers.dart';

void main() {
  setUpAll(loadTestFonts);

  test('texte : gras et puces', () {
    final spans = assistantSpans('Total **86 500 F**\n- Karité');
    expect(spans.map((s) => s.text).join(), 'Total 86 500 F\n• Karité');
    expect(spans[1].style?.fontWeight, FontWeight.w800);
  });

  testWidgets('accueil : suggestions ; une question, une réponse, l’historique envoyé', (tester) async {
    phoneSize(tester);
    final (_, repo) = await pumpSama(tester, location: '/assistant');
    expect(find.text('Posez une question sur votre boutique'), findsOneWidget);
    expect(find.text('60 questions restantes aujourd’hui'), findsOneWidget);

    await tester.tap(find.text("Combien j'ai vendu aujourd'hui ?"));
    await tester.pumpAndSettle();
    expect(find.textContaining('12 ventes', findRichText: true), findsOneWidget);
    expect(find.textContaining('• Meilleur produit', findRichText: true), findsOneWidget);
    expect(find.text('59 questions restantes aujourd’hui'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('assistant_input')), 'Et hier ?');
    await tester.tap(find.byTooltip('Envoyer'));
    await tester.pumpAndSettle();
    final sent = repo.assistantQuestions.last;
    expect(sent.map((m) => (m.fromUser, m.text.split('\n').first)), [
      (true, "Combien j'ai vendu aujourd'hui ?"),
      (false, "Aujourd'hui vous avez fait **12 ventes** pour **86 500 F**."),
      (true, 'Et hier ?'),
    ]);

    await tester.tap(find.byTooltip('Nouvelle conversation'));
    await tester.pumpAndSettle();
    expect(find.text('Posez une question sur votre boutique'), findsOneWidget);
  });

  testWidgets('erreur : message clair, question gardée pour réessayer', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo()
      ..assistantError = const ApiException('ASSISTANT_LIMIT', 'Limite de 60 questions par jour atteinte.');
    await pumpSama(tester, location: '/assistant', repo: repo);
    await tester.tap(find.text('Qui me doit le plus ?'));
    await tester.pumpAndSettle();
    expect(find.text('Limite de 60 questions par jour atteinte.'), findsOneWidget);
    expect(find.text('Non envoyé · Réessayer'), findsOneWidget);

    repo.assistantError = null;
    await tester.tap(find.text('Non envoyé · Réessayer'));
    await tester.pumpAndSettle();
    expect(find.text('Non envoyé · Réessayer'), findsNothing);
    expect(find.textContaining('12 ventes', findRichText: true), findsOneWidget);
  });

  testWidgets('pas encore activé sur le serveur', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo()..assistantEnabled = false;
    await pumpSama(tester, location: '/assistant', repo: repo);
    expect(find.byKey(const Key('assistant_disabled')), findsOneWidget);
    expect(find.byKey(const Key('assistant_input')), findsNothing);
  });
}
