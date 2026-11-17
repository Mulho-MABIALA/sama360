import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/format.dart';
import 'package:sama360/core/models.dart';
import 'package:sama360/features/delivery/delivery_screen.dart';
import 'package:sama360/features/sales/receipt_screen.dart';

import 'helpers.dart';
import 'receipt_test.dart' show RecordingActions;

const _order = OrderToDeliver(
  orderId: 'o1',
  number: 'CMD-0042',
  customerName: 'Aminata Diop',
  customerPhone: '+221776667788',
  address: 'Sacré-Cœur 3, villa 12',
  total: 18500,
);

Delivery _delivery(String id, DeliveryStatus status, {int amount = 7000}) => Delivery(
  id: id,
  customerName: 'Khady Sarr',
  customerPhone: '+221770001122',
  address: 'Ouakam, près de la mosquée',
  courierId: 'c1',
  courierName: 'Moussa Fall',
  courierPhone: '+221771112233',
  amountToCollect: amount,
  status: status,
);

void main() {
  setUpAll(loadTestFonts);

  group('textes', () {
    test('lien carte et message au livreur', () {
      expect(
        mapsLink('Sacré-Cœur 3', 'Dakar'),
        'https://www.google.com/maps/search/?api=1&query=Sacr%C3%A9-C%C5%93ur%203%2C%20Dakar',
      );
      final msg = courierMessage(_delivery('d1', DeliveryStatus.assigned), business: 'Boutique Awa', city: 'Dakar');
      expect(msg, contains('Course Boutique Awa'));
      expect(msg, contains('Client : Khady Sarr · +221770001122'));
      expect(msg, contains('Adresse : Ouakam, près de la mosquée'));
      expect(msg, contains('google.com/maps'));
      expect(msg, contains('À encaisser'));
      final paid = courierMessage(_delivery('d2', DeliveryStatus.assigned, amount: 0), business: 'B');
      expect(paid, contains('Rien à encaisser'));
    });
  });

  testWidgets('commande en ligne : assigner un livreur → message WhatsApp', (tester) async {
    phoneSize(tester);
    final actions = RecordingActions();
    final repo = FakeRepo()..ordersToDeliver = [_order];
    await pumpSama(
      tester,
      location: '/deliveries',
      repo: repo,
      overrides: [receiptActionsProvider.overrideWithValue(actions)],
    );
    expect(find.text('Commandes en ligne à livrer'), findsOneWidget);
    expect(find.text('Aminata Diop · CMD-0042'), findsOneWidget);

    await tester.tap(find.byKey(const Key('assign_o1')));
    await tester.pumpAndSettle();
    expect(find.text('Quel livreur ?'), findsOneWidget);
    await tester.tap(find.text('Moussa Fall'));
    await tester.pumpAndSettle();

    expect(repo.deliveryOps.single.$1, 'create');
    expect(repo.deliveryOps.single.$2, {'orderId': 'o1', 'courierId': 'c1'});
    expect(actions.whatsApp.toString(), contains('221771112233'));
    final text = Uri.decodeFull(actions.whatsApp.toString());
    expect(text, contains('Aminata Diop'));
    expect(text, contains('Sacré-Cœur 3, villa 12'));
    // La commande a quitté « à livrer » et la course apparaît.
    expect(find.text('Commandes en ligne à livrer'), findsNothing);
    expect(find.text('Courses'), findsOneWidget);
  });

  testWidgets('suivi : en route, livrée, échec avec raison', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo()
      ..deliveryList.addAll([
        _delivery('d1', DeliveryStatus.assigned),
        Delivery(
          id: 'd2',
          customerName: 'Ousmane Ba',
          address: 'Médina rue 11',
          courierId: 'c2',
          courierName: 'Ibou Ndiaye',
          status: DeliveryStatus.picked,
        ),
      ]);
    await pumpSama(tester, location: '/deliveries', repo: repo);

    await tester.tap(find.text('Khady Sarr'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Colis récupéré : en route'));
    await tester.pumpAndSettle();
    expect(repo.deliveryOps.last.$2, {'id': 'd1', 'status': 'picked'});

    await tester.tap(find.text('Khady Sarr'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Livrée'));
    await tester.pumpAndSettle();
    expect(repo.deliveryOps.last.$2, {'id': 'd1', 'status': 'delivered'});
    expect(find.text('Khady Sarr'), findsNothing); // passe dans « Terminées »

    await tester.tap(find.text('Ousmane Ba'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Échec de livraison'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Client injoignable'));
    await tester.pumpAndSettle();
    expect(repo.deliveryOps.last.$2, {'id': 'd2', 'status': 'failed', 'failureReason': 'Client injoignable'});

    await tester.tap(find.text('Terminées'));
    await tester.pumpAndSettle();
    expect(find.text('Khady Sarr'), findsOneWidget);
    expect(find.text('Ousmane Ba'), findsOneWidget);
  });

  testWidgets('argent chez les livreurs : remise confirmée', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo()
      ..courierBalances = [const CourierBalance(courierId: 'c1', name: 'Moussa Fall', owed: 25500, deliveries: 3)];
    await pumpSama(tester, location: '/deliveries', repo: repo);
    expect(find.text('Argent chez les livreurs'), findsOneWidget);
    expect(find.textContaining(moneyShort(25500)), findsWidgets);

    await tester.tap(find.byKey(const Key('settle_c1')));
    await tester.pumpAndSettle();
    expect(find.textContaining('vous a remis'), findsOneWidget);
    await tester.tap(find.text('Argent reçu').last);
    await tester.pumpAndSettle();
    expect(repo.deliveryOps.single, ('settle', 'c1'));
    expect(find.text('Argent chez les livreurs'), findsNothing);
  });

  testWidgets('livraison manuelle avec livreur → enregistrée et envoyée', (tester) async {
    phoneSize(tester);
    final actions = RecordingActions();
    final repo = FakeRepo();
    final (c, _) = await pumpSama(
      tester,
      location: '/deliveries',
      repo: repo,
      overrides: [receiptActionsProvider.overrideWithValue(actions)],
    );
    expect(find.text('Aucune livraison en cours'), findsOneWidget);
    await tester.tap(find.byKey(const Key('new_delivery')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('dl_name')), 'Fatou Sow');
    await tester.enterText(find.byKey(const Key('dl_phone')), '+221775556677');
    await tester.enterText(find.byKey(const Key('dl_address')), 'Point E, rue de Fatick');
    await tester.enterText(find.byKey(const Key('dl_amount')), '12 000');
    await tester.tap(find.byKey(const Key('dl_courier')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ibou Ndiaye'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Envoyer au livreur'));
    await tester.tap(find.text('Envoyer au livreur'));
    await tester.pumpAndSettle();

    final data = repo.deliveryOps.single.$2 as Map<String, Object?>;
    expect(data['customerName'], 'Fatou Sow');
    expect(data['address'], 'Point E, rue de Fatick');
    expect(data['amountToCollect'], 12000);
    expect(data['courierId'], 'c2');
    expect(actions.whatsApp.toString(), contains('221774445566'));
    expect(routerOf(c).state.uri.path, '/deliveries');
    expect(find.text('Fatou Sow'), findsOneWidget);
  });

  testWidgets('mes livreurs : ajouter', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo();
    await pumpSama(tester, location: '/deliveries/couriers', repo: repo);
    expect(find.text('Moussa Fall'), findsOneWidget);
    await tester.tap(find.byKey(const Key('add_courier')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('courier_name')), 'Pape Diouf');
    await tester.enterText(find.byKey(const Key('courier_phone')), '+221779990000');
    await tester.tap(find.text('Voiture'));
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();
    expect(repo.courierList.last.name, 'Pape Diouf');
    expect(repo.courierList.last.vehicle, 'voiture');
    expect(find.text('Pape Diouf'), findsOneWidget);
  });
}
