import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/admin_models.dart';

import 'admin_test.dart' show adminRepo;
import 'helpers.dart';

/// Suggestions : le commerçant écrit depuis son profil, l'équipe les lit dans le back office.
void main() {
  setUpAll(loadTestFonts);

  testWidgets('profil → Suggestions : un problème envoyé avec l’entreprise', (tester) async {
    phoneSize(tester);
    final (_, repo) = await pumpSama(tester, location: '/account');
    await tester.scrollUntilVisible(
      find.byKey(const Key('feedback_row')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('feedback_row')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('fb_send')));
    await tester.pumpAndSettle();
    expect(repo.sentFeedback, isEmpty); // message vide

    await tester.tap(find.byKey(const Key('fb_kind_problem')));
    await tester.enterText(find.byKey(const Key('fb_message')), 'Le reçu WhatsApp ne part pas');
    await tester.pump();
    await tester.tap(find.byKey(const Key('fb_send')));
    await tester.pumpAndSettle();
    expect(repo.sentFeedback.single.$1, FeedbackKind.problem);
    expect(repo.sentFeedback.single.$2, 'Le reçu WhatsApp ne part pas');
    expect(repo.sentFeedback.single.$3, isNotNull);
    expect(find.byKey(const Key('feedback_thanks')), findsOneWidget);
  });

  testWidgets('back office : nouvelles suggestions, marquer traitée', (tester) async {
    phoneSize(tester);
    final repo = adminRepo()
      ..feedbackInbox.add(
        AdminFeedback(
          id: 'f1',
          kind: FeedbackKind.idea,
          message: 'Ajoutez le wolof svp',
          status: FeedbackStatus.fresh,
          createdAt: DateTime(2026, 11, 25, 10, 30),
          userPhone: '+221770000001',
          userName: 'Awa Ndiaye',
          businessId: 'b1',
          businessName: 'Awa Beauté',
          category: 'cosmetique',
        ),
      );
    await pumpAdmin(tester, repo: repo, location: '/admin/feedback');
    expect(find.text('Ajoutez le wolof svp'), findsOneWidget);
    expect(find.textContaining('Parfumerie & cosmétique'), findsOneWidget);
    expect(find.text('Nouvelles (1)'), findsOneWidget);

    await tester.tap(find.byKey(const Key('fb_done_f1')));
    await tester.pumpAndSettle();
    expect(repo.feedbackInbox.single.status, FeedbackStatus.done);
    expect(find.text('Ajoutez le wolof svp'), findsNothing);
    await tester.tap(find.byKey(const Key('fb_tab_done')));
    await tester.pumpAndSettle();
    expect(find.text('Ajoutez le wolof svp'), findsOneWidget);
  });
}
