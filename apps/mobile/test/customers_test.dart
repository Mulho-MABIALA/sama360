import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/format.dart';
import 'package:sama360/core/models.dart';
import 'package:sama360/core/providers.dart';
import 'package:sama360/features/customers/customers_screens.dart';
import 'package:sama360/features/customers/statement_pdf.dart';
import 'package:sama360/features/sales/receipt.dart';
import 'package:sama360/features/sales/receipt_screen.dart';

import 'helpers.dart';
import 'receipt_test.dart' show RecordingActions;

/// Montants : espaces insécables fines dans le format français.
Finder textMatching(String pattern) => find.byWidgetPredicate(
  (w) => w is Text && w.data != null && RegExp(pattern).hasMatch(w.data!.replaceAll(RegExp(r'[  ]'), ' ')),
);

const cashierBusiness = CurrentBusiness(
  id: 'b1',
  name: 'Awa Beauté',
  slug: 'awa-beaute',
  role: 'cashier',
  permissions: ['business:read', 'contacts:read', 'contacts:write', 'sales:read', 'sales:create'],
  modules: ['sales', 'inventory'],
);

void main() {
  setUpAll(() async {
    await initializeDateFormatting('fr');
    await loadTestFonts();
  });

  group('messages et dates', () {
    final now = DateTime(2026, 11, 16, 10);
    final o = CustomerOverview(
      customer: const Contact(id: 'k1', name: 'Fatou Ndiaye', phone: '+221774120855'),
      balance: 17500,
      oldestUnpaidAt: DateTime(2026, 11, 2, 16),
      entries: [
        LedgerEntry(id: 'e1', type: 'debt', amount: 4000, at: DateTime(2026, 11, 14)),
        LedgerEntry(id: 'e2', type: 'repayment', amount: -10000, at: DateTime(2026, 11, 9)),
        LedgerEntry(id: 'e3', type: 'debt', amount: 8500, at: DateTime(2026, 11, 6)),
      ],
    );
    String flat(String s) => s.replaceAll(RegExp(r'[  ]'), ' ');

    test('rappel aimable, ferme et détaillé', () {
      expect(
        flat(reminderText(o, 'Awa Beauté')),
        'Bonjour Fatou, c’est Awa Beauté. Petit rappel : il vous reste 17 500 F à régler. '
        'Vous pouvez payer en boutique, par Wave ou Orange Money. Merci et bonne journée !',
      );
      expect(
        flat(reminderText(o, 'Awa Beauté', tone: ReminderTone.firm, now: now)),
        'Bonjour Fatou, Awa Beauté vous rappelle que votre solde de 17 500 F est en attente '
        'depuis le 2 novembre (13 jours). Merci de le régler au plus vite.',
      );
      final detailed = flat(reminderText(o, 'Awa Beauté', tone: ReminderTone.detailed));
      expect(detailed, contains('• 14 nov. : 4 000 F'));
      expect(detailed, contains('• 6 nov. : 8 500 F'));
      expect(detailed, isNot(contains('10 000')));
      expect(detailed, contains('Reste à payer : 17 500 F.'));
    });

    test('ancienneté', () {
      expect(sinceText(DateTime(2026, 11, 16, 8), now), 'aujourd’hui');
      expect(sinceText(DateTime(2026, 11, 15, 23), now), 'hier');
      expect(sinceText(DateTime(2026, 11, 2), now), 'il y a 14 j');
      expect(o.debtAgeDays(now), 13);
    });

    test('libellés du carnet', () {
      LedgerEntry e(String type, {String? ref, String? note, String? method}) =>
          LedgerEntry(id: 'x', type: type, amount: 1, at: now, refType: ref, note: note, method: method);
      expect(e('debt', note: 'VEN-1').label, 'Vente à crédit · VEN-1');
      expect(e('repayment', method: 'orange_money').label, 'Remboursement Orange Money');
      expect(e('adjustment', ref: 'opening_debt', note: 'Cahier').label, 'Ancienne dette · Cahier');
      expect(e('adjustment', ref: 'write_off').label, 'Remise de dette');
      expect(e('adjustment', ref: 'sale_void', note: 'Annulation VEN-1').label, 'Annulation VEN-1');
    });

    test('lecture de la fiche client renvoyée par l’API', () {
      final parsed = CustomerOverview.fromJson(
        jsonDecode('''{
        "customer": {"id": "k1", "name": "Fatou", "phone": null, "creditLimit": "25000", "lastRemindedAt": null},
        "balance": "17500", "creditLimit": 25000, "availableCredit": 7500, "oldestUnpaidAt": "2026-11-02T16:00:00Z",
        "stats": {"salesCount": 6, "totalSpent": 64500, "totalPaid": 47000, "averageBasket": 10750,
                  "firstPurchaseAt": null, "lastPurchaseAt": null, "openInvoices": 0, "openInvoicesDue": 0},
        "topProducts": [{"name": "Savon", "quantity": 2.5, "total": "3750"}],
        "recentSales": [{"id": "s1", "number": "VEN-1", "total": 9000, "paid": 5000, "due": 4000,
                         "status": "completed", "soldAt": "2026-11-14T10:00:00Z", "itemCount": 3}],
        "entries": [{"id": "e1", "entryType": "debt", "amount": "4000", "method": null, "refType": "sale",
                     "refId": "s1", "note": "VEN-1", "occurredAt": "2026-11-14T10:00:00Z", "balanceAfter": "17500"}]
      }''')
            as Map<String, dynamic>,
      );
      expect(parsed.balance, 17500);
      expect(parsed.customer.balance, 17500);
      expect(parsed.creditLimit, 25000);
      expect(parsed.availableCredit, 7500);
      expect(parsed.topProducts.single.quantity, 2.5);
      expect(parsed.recentSales.single.due, 4000);
      expect(parsed.entries.single.balanceAfter, 17500);
      expect(parsed.entries.single.refType, 'sale');
    });
  });

  group('annuaire', () {
    testWidgets('totaux, filtre « doivent », plafond dépassé, recherche', (tester) async {
      phoneSize(tester);
      final (_, repo) = await pumpSama(tester, location: '/customers');
      expect(textMatching(r'^36 000 FCFA$'), findsOneWidget);
      expect(find.text('Ousmane Fall'), findsOneWidget);
      expect(find.text('Plafond dépassé'), findsWidgets); // pastille + chiffre d'en-tête

      await tester.tap(find.text('Doivent de l’argent'));
      await tester.pumpAndSettle();
      expect(find.text('Ousmane Fall'), findsNothing);
      expect(repo.customerQueries.last.$2, CustomerFilter.debt);
      expect(repo.customerQueries.last.$3, CustomerSort.balance); // tri par dette automatique
      // Plus grosse dette en premier
      final fatou = tester.getTopLeft(find.text('Fatou Ndiaye')).dy;
      final coumba = tester.getTopLeft(find.text('Coumba Diop')).dy;
      expect(fatou, lessThan(coumba));
      expect(find.text('Doit depuis le 2 nov.'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('customerSearch')), 'coumba');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('Fatou Ndiaye'), findsNothing);
      expect(find.text('Coumba Diop'), findsOneWidget);
    });

    testWidgets('le raccourci « Crédits » ouvre directement les débiteurs', (tester) async {
      phoneSize(tester);
      final (_, repo) = await pumpSama(tester, location: '/customers?debt=1');
      expect(repo.customerQueries.last.$2, CustomerFilter.debt);
      expect(find.text('Ousmane Fall'), findsNothing);
    });

    testWidgets('nouveau client depuis l’annuaire, avec plafond', (tester) async {
      phoneSize(tester);
      final (c, repo) = await pumpSama(tester, location: '/customers');
      await tester.tap(find.text('Nouveau client'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ajouter le client'));
      await tester.pumpAndSettle();
      expect(find.text('Indiquez le nom du client'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('cName')), 'Aïda Mbaye');
      await tester.enterText(find.byKey(const Key('cPhone')), '77 12');
      await tester.tap(find.byKey(const Key('cHasLimit')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ajouter le client'));
      await tester.pumpAndSettle();
      expect(find.text('9 chiffres, ex. 77 123 45 67'), findsOneWidget);
      expect(find.text('Indiquez le montant maximum'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('cPhone')), '77 987 65 43');
      await tester.enterText(find.byKey(const Key('cLimit')), '30000');
      await tester.ensureVisible(find.byKey(const Key('cNotes')));
      await tester.enterText(find.byKey(const Key('cNotes')), 'Revendeuse à Thiès');
      await tester.tap(find.text('Ajouter le client'));
      await tester.pumpAndSettle();
      final (id, body) = repo.savedCustomers.single;
      expect(id, isNull);
      expect(body, {
        'name': 'Aïda Mbaye',
        'phone': '+221779876543',
        'email': null,
        'address': null,
        'notes': 'Revendeuse à Thiès',
        'creditLimit': 30000,
        'birthDay': null,
        'birthMonth': null,
      });
      expect(routerOf(c).state.matchedLocation, '/customers');
    });

    testWidgets('caissier : modifie le client, pas son plafond', (tester) async {
      phoneSize(tester);
      final (_, repo) = await pumpSama(
        tester,
        location: '/customers/k1/edit',
        overrides: [currentBusinessProvider.overrideWith((ref) async => cashierBusiness)],
      );
      expect(find.text('Seul le gérant ou le propriétaire peut le modifier'), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline_rounded), findsOneWidget);
      await tester.enterText(find.byKey(const Key('cName')), 'Fatou Ndiaye Diallo');
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();
      final (id, body) = repo.savedCustomers.single;
      expect(id, 'k1');
      expect(body['name'], 'Fatou Ndiaye Diallo');
      expect(body['address'], 'Liberté 6, Dakar');
      expect(body.containsKey('creditLimit'), isFalse);
    });

    testWidgets('suppression refusée tant que le client doit de l’argent', (tester) async {
      phoneSize(tester);
      final (_, repo) = await pumpSama(tester, location: '/customers/k1/edit');
      await tester.tap(find.byIcon(Icons.delete_outline_rounded));
      await tester.pumpAndSettle();
      expect(textMatching(r'doit encore 17 500 FCFA'), findsOneWidget);
      expect(repo.deletedCustomers, isEmpty);
    });

    testWidgets('suppression d’un client sans dette', (tester) async {
      phoneSize(tester);
      final (c, repo) = await pumpSama(tester, location: '/customers/c9/edit');
      await tester.tap(find.byIcon(Icons.delete_outline_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Supprimer'));
      await tester.pumpAndSettle();
      expect(repo.deletedCustomers, ['c9']);
      expect(routerOf(c).state.matchedLocation, '/customers');
    });
  });

  group('fiche client', () {
    testWidgets('solde, ancienneté, plafond, statistiques, factures, notes et achats', (tester) async {
      phoneSize(tester);
      final (c, _) = await pumpSama(tester, location: '/customers/k1');
      expect(textMatching(r'^17 500 FCFA$'), findsOneWidget);
      expect(textMatching(r'^Doit depuis 14 jours'), findsOneWidget);
      expect(textMatching(r'^Plafond 25 000 F · encore 7 500 F possible$'), findsOneWidget);
      expect(find.text('Dernier rappel il y a 3 j'), findsOneWidget);
      expect(textMatching(r'^64 500 FCFA$'), findsOneWidget);
      expect(find.text('Client depuis juin 2026'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Paie en fin de mois'), 200, scrollable: find.byType(Scrollable).first);
      expect(textMatching(r'^1 facture à encaisser : 30 000 FCFA$'), findsOneWidget);

      // Carnet avec le solde après chaque mouvement
      await tester.scrollUntilVisible(
        find.text('Ancienne dette · Cahier papier'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(textMatching(r'solde 13 500 F$'), findsOneWidget);

      await tester.scrollUntilVisible(find.text('Achats'), -200, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('Achats'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Ce qu’il achète le plus'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Beurre de karité 250 g'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('VEN-2026-0412'), -200, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('VEN-2026-0412'));
      await tester.pumpAndSettle();
      expect(routerOf(c).state.matchedLocation, '/sales/s1');
    });

    testWidgets('rappel : ton choisi, message modifiable, envoi WhatsApp ou SMS et date notée', (tester) async {
      phoneSize(tester);
      final actions = RecordingActions();
      final (_, repo) = await pumpSama(
        tester,
        location: '/customers/k1',
        overrides: [receiptActionsProvider.overrideWithValue(actions)],
      );
      await tester.tap(find.text('Envoyer un rappel'));
      await tester.pumpAndSettle();
      expect(find.text('Rappel de paiement'), findsOneWidget);
      await tester.tap(find.text('Ferme'));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(find.byKey(const Key('reminderText')));
      expect(field.controller!.text, contains('vous rappelle que votre solde'));

      await tester.tap(find.text('WhatsApp').last);
      await tester.pumpAndSettle();
      expect(actions.whatsApp!.host, 'wa.me');
      expect(actions.whatsApp!.path, '/221774120855');
      expect(actions.whatsApp!.queryParameters['text'], contains('Awa Beauté vous rappelle'));
      expect(repo.customerReminders, [('k1', 'whatsapp')]);

      await tester.tap(find.text('Envoyer un rappel'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('reminderText')), 'Bonjour Fatou, on se voit samedi ?');
      await tester.tap(find.text('SMS').last);
      await tester.pumpAndSettle();
      expect(actions.whatsApp!.scheme, 'sms');
      expect(actions.whatsApp!.path, '+221774120855');
      expect(actions.whatsApp!.queryParameters['body'], 'Bonjour Fatou, on se voit samedi ?');
      expect(repo.customerReminders.last, ('k1', 'sms'));
    });

    testWidgets('ajustement : reprise d’ancienne dette par le gérant', (tester) async {
      phoneSize(tester);
      final (_, repo) = await pumpSama(tester, location: '/customers/k1');
      await tester.tap(find.byTooltip('Plus d’actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ajuster le solde'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('adjustAmount')), '5000');
      await tester.enterText(find.byKey(const Key('adjustReason')), 'Cahier de 2025');
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();
      expect(repo.adjustments, [('k1', 5000, 'Cahier de 2025')]);
      expect(find.text('Solde mis à jour'), findsOneWidget);
    });

    testWidgets('ajustement : remise de dette limitée à la dette', (tester) async {
      phoneSize(tester);
      final (_, repo) = await pumpSama(tester, location: '/customers/k1');
      await tester.tap(find.byTooltip('Plus d’actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ajuster le solde'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remise de dette'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('adjustAmount')), '20000');
      await tester.enterText(find.byKey(const Key('adjustReason')), 'Geste commercial');
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();
      expect(repo.adjustments, isEmpty);
      await tester.enterText(find.byKey(const Key('adjustAmount')), '2500');
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();
      expect(repo.adjustments, [('k1', -2500, 'Geste commercial')]);
    });

    testWidgets('caissier : pas d’ajustement, remboursement possible', (tester) async {
      phoneSize(tester);
      await pumpSama(
        tester,
        location: '/customers/k1',
        overrides: [currentBusinessProvider.overrideWith((ref) async => cashierBusiness)],
      );
      expect(find.text('Encaisser un remboursement'), findsOneWidget);
      await tester.tap(find.byTooltip('Plus d’actions'));
      await tester.pumpAndSettle();
      expect(find.text('Relevé de compte (PDF)'), findsOneWidget);
      expect(find.text('Ajuster le solde'), findsNothing);
    });

    testWidgets('relevé de compte partagé en PDF', (tester) async {
      phoneSize(tester);
      final actions = RecordingActions();
      await pumpSama(tester, location: '/customers/k1', overrides: [receiptActionsProvider.overrideWithValue(actions)]);
      await tester.tap(find.byTooltip('Plus d’actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Relevé de compte (PDF)'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
      await tester.pumpAndSettle();
      expect(actions.sharedName, matches(RegExp(r'^Releve-Fatou-Ndiaye-\d{4}-\d{2}-\d{2}\.pdf$')));
      expect(utf8.decode(actions.shared!.take(5).toList()), '%PDF-');
    });

    testWidgets('client sans dette : compte à jour, pas de rappel', (tester) async {
      phoneSize(tester);
      await pumpSama(tester, location: '/customers/c9');
      expect(find.text('Compte à jour'), findsOneWidget);
      expect(find.text('Envoyer un rappel'), findsNothing);
      expect(find.text('Encaisser un remboursement'), findsNothing);
    });
  });

  test('relevé PDF : en-tête, tableau et polices embarquées', () async {
    final repo = FakeRepo();
    final o = await repo.customerOverview('k1');
    final bytes = await buildStatementPdf(
      o,
      demoBusiness,
      fonts: await ReceiptFonts.load(),
      now: DateTime(2026, 11, 16),
    );
    final raw = latin1.decode(bytes);
    expect(raw.startsWith('%PDF-'), isTrue);
    expect(raw, contains('/FontFile2'));
    expect(statementFileName(o, DateTime(2026, 11, 16)), 'Releve-Fatou-Ndiaye-2026-11-16.pdf');
    expect(moneyShort(17500).replaceAll(RegExp(r'[  ]'), ' '), '17 500 F');
  });
}
