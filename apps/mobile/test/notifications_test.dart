import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/models.dart';
import 'package:sama360/features/notifications/notifications_screen.dart';

import 'helpers.dart';

void main() {
  setUpAll(() async {
    await loadTestFonts();
    await initializeDateFormatting('fr');
  });

  group('logique', () {
    final now = DateTime(2026, 11, 16, 15, 0);
    test('heure lisible', () {
      expect(notificationTime(now.subtract(const Duration(seconds: 20)), now), 'à l’instant');
      expect(notificationTime(now.subtract(const Duration(minutes: 12)), now), 'il y a 12 min');
      expect(notificationTime(DateTime(2026, 11, 16, 9, 5), now), '09:05');
      expect(notificationTime(DateTime(2026, 11, 15, 22, 40), now), 'hier, 22:40');
      expect(notificationTime(DateTime(2026, 11, 12, 8), now), isNot(contains(':')));
    });
    test('groupes', () {
      expect(notificationGroup(DateTime(2026, 11, 16, 1), now), 'Aujourd’hui');
      expect(notificationGroup(DateTime(2026, 11, 15, 23), now), 'Hier');
      expect(notificationGroup(DateTime(2026, 11, 10), now), 'Plus tôt');
    });
    test('chaque type a son icône', () {
      for (final k in ['stock_low', 'shop_order', 'sale_voided', 'invoices_overdue', 'credit_stale', 'cash_open', 'welcome', 'autre']) {
        expect(notificationStyle(k).$1, isA<IconData>());
      }
    });
  });

  group('écrans', () {
    testWidgets('la cloche affiche le nombre de non lues et ouvre la liste', (tester) async {
      phoneSize(tester);
      final (c, repo) = await pumpSama(tester);
      expect(find.byTooltip('Notifications : 3 non lues'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);

      await tester.tap(find.byTooltip('Notifications : 3 non lues'));
      await tester.pumpAndSettle();
      expect(find.text('Notifications'), findsOneWidget);
      expect(find.text('Aujourd’hui'), findsOneWidget);
      expect(find.text('Hier'), findsOneWidget);
      expect(find.text('Plus tôt'), findsOneWidget);
      expect(find.text('Nouvelle commande CMD-2026-0012'), findsOneWidget);
      expect(find.text('il y a 12 min'), findsOneWidget);
      expect(find.byKey(const ValueKey('unread_n1')), findsOneWidget);
      expect(find.byKey(const ValueKey('unread_n4')), findsNothing); // déjà lue

      // Ouvrir une notification : marquée lue, écran correspondant ouvert
      await tester.tap(find.text('Stock bas : Huile de coco 500 ml'));
      await tester.pumpAndSettle();
      expect(repo.notificationReads, ['n2']);
      expect(routerOf(c).state.uri.path, '/stock');
    });

    testWidgets('tout marquer comme lu', (tester) async {
      phoneSize(tester);
      final (_, repo) = await pumpSama(tester, location: '/notifications');
      expect(find.text('Tout lire'), findsOneWidget);
      await tester.tap(find.text('Tout lire'));
      await tester.pumpAndSettle();
      expect(repo.readAllCalls, 1);
      expect(find.byKey(const ValueKey('unread_n1')), findsNothing);
      expect(find.text('Tout lire'), findsNothing);
    });

    testWidgets('aucune notification', (tester) async {
      phoneSize(tester);
      final repo = FakeRepo()..demoNotifications = <AppNotification>[];
      await pumpSama(tester, location: '/notifications', repo: repo);
      expect(find.text('Rien de nouveau'), findsOneWidget);
    });
  });
}
