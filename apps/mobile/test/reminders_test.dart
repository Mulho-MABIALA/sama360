import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/models.dart';
import 'package:sama360/features/reminders/reminders_screen.dart';
import 'package:sama360/features/sales/receipt_screen.dart';

import 'helpers.dart';
import 'receipt_test.dart' show RecordingActions;

Finder textMatching(String pattern) => find.byWidgetPredicate(
  (w) => w is Text && w.data != null && RegExp(pattern).hasMatch(w.data!.replaceAll(RegExp(r'[  ]'), ' ')),
);

String flat(String s) => s.replaceAll(RegExp(r'[  ]'), ' ');

void main() {
  setUpAll(() async {
    await loadTestFonts();
    await initializeDateFormatting('fr');
  });

  final invoice = ReminderItem(
    kind: 'invoice',
    id: 'inv7',
    customerId: 'k9',
    name: 'Restaurant Le Lagon',
    amount: 120000,
    since: DateTime(2026, 11, 14),
    daysLate: 3,
    invoiceNumber: 'FAC-2026-0007',
    due: true,
  );
  const credit = ReminderItem(
    kind: 'credit',
    id: 'k1',
    customerId: 'k1',
    name: 'Ndèye Sarr',
    amount: 11000,
    daysLate: 40,
    due: true,
  );

  group('logique', () {
    test('état du retard', () {
      expect(lateText(credit), 'Crédit · doit depuis 40 j');
      expect(lateText(invoice), 'FAC-2026-0007 · en retard de 3 j');
      expect(lateText(_with(invoice, 0)), 'FAC-2026-0007 · à payer aujourd’hui');
      expect(lateText(_with(invoice, -2)), 'FAC-2026-0007 · échéance dans 2 j');
    });

    test('il y a combien de temps', () {
      final now = DateTime(2026, 11, 17, 9);
      expect(agoText(DateTime(2026, 11, 17, 1), now), 'aujourd’hui');
      expect(agoText(DateTime(2026, 11, 16, 23), now), 'hier');
      expect(agoText(DateTime(2026, 11, 12), now), 'il y a 5 j');
    });

    test('messages', () {
      final g = flat(reminderMessage(invoice, 'Awa Beauté'));
      expect(g, startsWith('Bonjour Restaurant Le Lagon, c’est Awa Beauté.'));
      expect(g, contains('la facture FAC-2026-0007 était à régler le 14 novembre (reste 120 000 F)'));
      final f = flat(reminderMessage(invoice, 'Awa Beauté', style: ReminderStyle.firm));
      expect(f, contains('est en retard de 3 jours'));
      expect(flat(reminderMessage(credit, 'Awa Beauté')), contains('il vous reste 11 000 F à régler'));
      expect(flat(reminderMessage(credit, 'Awa Beauté', style: ReminderStyle.firm)), contains('(40 jours)'));
    });
  });

  group('écran', () {
    testWidgets('à relancer, tous, historique', (tester) async {
      phoneSize(tester);
      await pumpSama(tester, location: '/reminders');
      expect(find.text('Relances'), findsOneWidget);
      expect(textMatching(r'^133 500 F$'), findsOneWidget);
      expect(find.text('À relancer (3)'), findsOneWidget);
      expect(find.text('Ndèye Sarr'), findsOneWidget);
      expect(find.text('FAC-2026-0007 · en retard de 3 j'), findsOneWidget);
      expect(find.text('Binta Sow'), findsNothing); // relancée il y a 2 jours
      expect(find.text('Pas de numéro : en ajouter un'), findsOneWidget); // Pape Diouf

      await tester.tap(find.text('Tous (4)'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Binta Sow'), 200);
      expect(find.text('Relancé il y a 2 j'), findsOneWidget);

      await tester.tap(find.text('Historique'));
      await tester.pumpAndSettle();
      expect(find.text('WhatsApp · par Awa · il y a 2 j'), findsOneWidget);
    });

    testWidgets('relance WhatsApp : ton, message et rappel noté', (tester) async {
      phoneSize(tester);
      final actions = RecordingActions();
      final (_, repo) = await pumpSama(
        tester,
        location: '/reminders',
        overrides: [receiptActionsProvider.overrideWithValue(actions)],
      );
      await tester.tap(find.text('WhatsApp').first);
      await tester.pumpAndSettle();
      expect(find.text('Relance WhatsApp'), findsOneWidget);
      await tester.tap(find.text('Ferme'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byKey(const Key('reminder_text'))).controller!.text,
        contains('vous rappelle que votre solde'),
      );
      await tester.tap(find.text('Envoyer'));
      await tester.pumpAndSettle();
      expect(actions.whatsApp!.host, 'wa.me');
      expect(actions.whatsApp!.path, '/221765554433');
      expect(repo.recordedReminders, [('credit', 'k1', 'whatsapp')]);
      expect(find.text('Rappel noté pour Ndèye Sarr'), findsOneWidget);
    });

    testWidgets('facture : SMS et appel', (tester) async {
      phoneSize(tester);
      final actions = RecordingActions();
      final (_, repo) = await pumpSama(
        tester,
        location: '/reminders',
        overrides: [receiptActionsProvider.overrideWithValue(actions)],
      );
      await tester.tap(find.byTooltip('Relancer par SMS').at(1));
      await tester.pumpAndSettle();
      expect(find.text('Relance par SMS'), findsOneWidget);
      await tester.tap(find.text('Envoyer'));
      await tester.pumpAndSettle();
      expect(actions.whatsApp!.scheme, 'sms');
      expect(actions.whatsApp!.queryParameters['body'], contains('FAC-2026-0007'));
      expect(repo.recordedReminders.last, ('invoice', 'inv7', 'sms'));

      await tester.tap(find.byTooltip('Appeler Restaurant Le Lagon'));
      await tester.pumpAndSettle();
      expect(actions.whatsApp!.scheme, 'tel');
      expect(repo.recordedReminders.last, ('invoice', 'inv7', 'call'));
    });

    testWidgets('annuler ne note rien', (tester) async {
      phoneSize(tester);
      final (_, repo) = await pumpSama(tester, location: '/reminders');
      await tester.tap(find.text('WhatsApp').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Annuler'));
      await tester.pumpAndSettle();
      expect(repo.recordedReminders, isEmpty);
    });
  });
}

ReminderItem _with(ReminderItem i, int daysLate) => ReminderItem(
  kind: i.kind,
  id: i.id,
  customerId: i.customerId,
  name: i.name,
  amount: i.amount,
  since: i.since,
  daysLate: daysLate,
  invoiceNumber: i.invoiceNumber,
  due: i.due,
);
