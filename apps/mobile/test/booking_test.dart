import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/models.dart';
import 'package:sama360/features/booking/booking_screen.dart';
import 'package:sama360/features/sales/cart.dart';
import 'package:sama360/features/sales/receipt_screen.dart';

import 'helpers.dart';
import 'receipt_test.dart' show RecordingActions;

final _today = DateTime.now();
DateTime _at(int h, [int m = 0]) => DateTime(_today.year, _today.month, _today.day, h, m);

const _tresses = Product(
  id: 's1',
  name: 'Tresses africaines',
  price: 15000,
  cost: 0,
  isService: true,
  trackStock: false,
);

Appointment _appt(String id, String name, DateTime at, {String? serviceId, int price = 15000, bool overlaps = false}) =>
    Appointment(
      id: id,
      customerId: id == 'a1' ? 'k1' : null,
      customerName: name,
      customerPhone: '+221775556677',
      serviceId: serviceId,
      serviceName: serviceId == null ? 'Brushing' : 'Tresses africaines',
      price: price,
      startsAt: at,
      durationMinutes: 120,
      status: AppointmentStatus.booked,
      overlaps: overlaps,
    );

void main() {
  setUpAll(() async {
    await loadTestFonts();
    await initializeDateFormatting('fr');
  });

  group('textes', () {
    test('durées, jour, rappel', () {
      expect(durationLabel(45), '45 min');
      expect(durationLabel(90), '1 h 30');
      expect(durationLabel(120), '2 h');
      final now = DateTime(2026, 11, 17, 8);
      expect(dayTitle(DateTime(2026, 11, 17), now), 'Aujourd’hui');
      expect(dayTitle(DateTime(2026, 11, 18), now), 'Demain');
      expect(dayTitle(DateTime(2026, 11, 19), now), 'Jeudi 19 novembre');
      final a = _appt('a1', 'Fatou Sow', DateTime(2026, 11, 18, 10), serviceId: 's1');
      expect(
        reminderMessage(a, 'Awa Beauté', now),
        'Bonjour Fatou, petit rappel : votre rendez-vous (Tresses africaines) chez Awa Beauté est prévu demain à 10 h. À bientôt !',
      );
    });
  });

  testWidgets('agenda : rendez-vous du jour, attendus, chevauchement, rappel WhatsApp, absent', (tester) async {
    phoneSize(tester);
    final actions = RecordingActions();
    final repo = FakeRepo()
      ..appointmentList.addAll([
        _appt('a1', 'Fatou Sow', _at(10), serviceId: 's1', overlaps: true),
        _appt('a2', 'Mariama Ba', _at(11), price: 3000, overlaps: true),
      ]);
    await pumpSama(
      tester,
      location: '/booking',
      repo: repo,
      overrides: [receiptActionsProvider.overrideWithValue(actions)],
    );
    expect(find.text('Aujourd’hui'), findsWidgets);
    expect(find.text('Fatou Sow'), findsOneWidget);
    expect(find.text('2 à venir · 18 000 F attendus'), findsOneWidget);
    expect(find.text('Même heure qu’un autre rendez-vous'), findsNWidgets(2));

    await tester.tap(find.text('Fatou Sow'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rappel WhatsApp'));
    await tester.pumpAndSettle();
    expect(Uri.decodeFull(actions.whatsApp.toString()), contains('Bonjour Fatou, petit rappel'));

    await tester.tap(find.text('Mariama Ba'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Client absent'));
    await tester.pumpAndSettle();
    expect(repo.appointmentChanges.last.$1, 'a2');
    expect(repo.appointmentChanges.last.$2, {'status': 'no_show'});
    expect(find.text('Absent'), findsOneWidget);
  });

  testWidgets('client venu : encaisser → caisse avec la prestation et le client', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo()
      ..extraProducts = const [_tresses]
      ..appointmentList.add(_appt('a1', 'Fatou Sow', _at(10), serviceId: 's1'));
    final (c, _) = await pumpSama(tester, location: '/booking', repo: repo);
    await tester.tap(find.text('Fatou Sow'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Client venu : encaisser'));
    await tester.pumpAndSettle();
    expect(routerOf(c).state.uri.path, '/pos');
    final cart = c.read(cartProvider);
    expect(cart.lines.values.single.product.id, 's1');
    expect(cart.customer?.id, 'k1');
    expect(repo.appointmentChanges.single.$1, 'a1');
    expect(repo.appointmentChanges.single.$2, {'status': 'done'});
  });

  testWidgets('nouveau rendez-vous : client de passage, prestation du catalogue, heure, durée', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo()..extraProducts = const [_tresses];
    final (c, _) = await pumpSama(tester, location: '/booking', repo: repo);
    await tester.tap(find.byKey(const Key('new_appointment')));
    await tester.pumpAndSettle();
    expect(find.text('Nouveau rendez-vous'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('appt_name')), 'Awa Ndiaye');
    await tester.enterText(find.byKey(const Key('appt_phone')), '77 111 22 33');
    await tester.tap(find.text('Tresses africaines · 15 000 F'));
    await tester.pump();
    expect(tester.widget<TextField>(find.byKey(const Key('appt_price'))).controller!.text, '15000');
    await tester.tap(find.text('2 h'));

    // Sans heure : refus
    await tester.ensureVisible(find.text('Noter le rendez-vous'));
    await tester.tap(find.text('Noter le rendez-vous'));
    await tester.pumpAndSettle();
    expect(find.text('Choisissez l’heure'), findsOneWidget);
    expect(repo.createdAppointments, isEmpty);

    await tester.tap(find.byKey(const Key('appt_time')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Noter le rendez-vous'));
    await tester.pumpAndSettle();

    final sent = repo.createdAppointments.single;
    expect(sent['customerName'], 'Awa Ndiaye');
    expect(sent['customerPhone'], '77 111 22 33');
    expect(sent['serviceId'], 's1');
    expect(sent['serviceName'], isNull);
    expect(sent['price'], 15000);
    expect(sent['durationMinutes'], 120);
    expect(DateTime.parse(sent['startsAt']! as String).toLocal().hour, 10);
    expect(routerOf(c).state.uri.path, '/booking');
    expect(find.text('Awa Ndiaye'), findsOneWidget);
  });
}
