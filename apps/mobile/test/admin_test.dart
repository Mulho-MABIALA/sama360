import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/admin_models.dart';
import 'package:sama360/core/models.dart';
import 'package:sama360/features/admin/admin_widgets.dart';
import 'helpers.dart';

AdminBusinessDetail detailOf(AdminBusiness b, {String? suspendedReason, String status = 'active'}) =>
    AdminBusinessDetail.fromJson({
      'id': b.id,
      'name': b.name,
      'slug': b.slug,
      'country': b.country.code,
      'createdAt': '2026-10-02T09:00:00Z',
      'status': status,
      'owner': {'id': 'u', 'name': b.ownerName, 'phone': b.ownerPhone},
      'plan': {'state': b.plan.name, 'endsAt': '2026-12-20T00:00:00Z', 'daysLeft': 27},
      'everPaid': b.everPaid,
      'stats': {
        'sales30': b.sales30,
        'revenue30': b.revenue30,
        'sales7': b.sales7,
        'lastSaleAt': b.lastSaleAt?.toUtc().toIso8601String(),
        'products': 35,
        'customers': 18,
      },
      'currency': 'XOF',
      'suspendedReason': suspendedReason,
      'referralCode': 'AWA7K2',
      'referrals': [
        {'id': 'b2', 'name': 'Chez Maman Mav', 'createdAt': '2026-11-01T09:00:00Z'},
      ],
      'members': [
        {'name': b.ownerName, 'phone': b.ownerPhone, 'role': 'Propriétaire', 'roleKey': 'owner'},
        {'name': 'Fatou', 'phone': '+221770000002', 'role': 'Caissier', 'roleKey': 'cashier'},
      ],
      'locations': [
        {'name': 'Boutique principale', 'main': true},
        {'name': 'Dépôt Pikine', 'main': false},
      ],
      'payments': [
        {
          'id': 'p1',
          'source': 'online',
          'businessId': b.id,
          'businessName': b.name,
          'cycle': 'monthly',
          'amount': 5000,
          'method': 'chariow',
          'status': 'paid',
          'createdAt': '2026-11-02T09:00:00Z',
          'settledAt': '2026-11-02T09:01:00Z',
        },
      ],
      'actions': [
        {
          'action': 'gift',
          'details': {'days': 15, 'reason': 'Panne réseau'},
          'at': '2026-11-10T12:00:00Z',
          'by': 'Mulho',
        },
      ],
    });

FakeRepo adminRepo() {
  final awa = fakeAdminBusiness('b1', 'Boutique Awa', plan: 'active', revenue30: 2450000);
  final mav = fakeAdminBusiness('b2', 'Chez Maman Mav', country: 'CG', phone: '+242061234567');
  final kone = fakeAdminBusiness('b3', 'Koné Market', country: 'CI', plan: 'expired', revenue30: 1810000);
  return FakeRepo()
    ..platformAdmin = true
    ..adminBusinessList.addAll([awa, mav, kone])
    ..adminDetails.addAll({'b1': detailOf(awa), 'b2': detailOf(mav), 'b3': detailOf(kone)})
    ..adminPaymentList.addAll([
      AdminPayment.fromJson({
        'id': 'p1',
        'source': 'online',
        'businessId': 'b1',
        'businessName': 'Boutique Awa',
        'cycle': 'yearly',
        'amount': 50000,
        'method': 'chariow',
        'status': 'paid',
        'createdAt': '2026-11-20T09:00:00Z',
      }),
      AdminPayment.fromJson({
        'id': 'p2',
        'source': 'manual',
        'businessId': 'b3',
        'businessName': 'Koné Market',
        'cycle': 'monthly',
        'amount': 5000,
        'method': 'mtn_momo',
        'reference': 'MP2611',
        'status': 'rejected',
        'note': 'Référence introuvable',
        'createdAt': '2026-11-19T09:00:00Z',
      }),
    ]);
}

PaymentRequest req(String id, String name, Country c) => PaymentRequest(
  id: id,
  cycle: 'monthly',
  amount: 5000,
  method: PayMethod.wave,
  reference: 'TX-$id',
  status: 'pending',
  createdAt: DateTime(2026, 11, 18, 9),
  payerPhone: '+2250707123456',
  businessName: name,
  businessCountry: c,
  businessCity: 'Abidjan',
);

void desktopSize(WidgetTester tester) {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('fr');
  });

  testWidgets('depuis le profil : tableau de bord, puis paiements à valider et refuser', (tester) async {
    phoneSize(tester);
    final repo = adminRepo()
      ..adminQueue.addAll([req('a', 'Koné Market', Country.ci), req('b', 'Chez Maman Mav', Country.cg)]);
    await pumpSama(tester, location: '/account', repo: repo);
    await tester.scrollUntilVisible(find.byKey(const Key('admin_row')), 200, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.text('Back office'), findsOneWidget);
    await tester.tap(find.byKey(const Key('admin_row')));
    await tester.pumpAndSettle();

    // Tableau de bord
    expect(find.text('Tableau de bord'), findsWidgets);
    expect(find.byKey(const Key('admin_revenue')), findsOneWidget);
    expect(find.textContaining('185'), findsWidgets);
    expect(find.text('128'), findsWidgets); // boutiques
    expect(find.byKey(const Key('admin_pending_banner')), findsOneWidget);

    // Autre période : le tableau de bord est rechargé
    await tester.tap(find.byKey(const Key('admin_days_7')));
    await tester.pumpAndSettle();
    expect(find.text('Encaissé sur 7 jours'), findsOneWidget);

    // Paiements à vérifier
    await tester.tap(find.byKey(const Key('admin_tab_payments')));
    await tester.pumpAndSettle();
    expect(find.text('Koné Market'), findsOneWidget);
    expect(find.textContaining('depuis +225 07 07 12 34 56'), findsWidgets);

    await tester.tap(find.byKey(const Key('approve_a')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Valider').last);
    await tester.pumpAndSettle();
    expect(repo.adminOps.single, ('approve', 'a', null));
    expect(find.text('Koné Market'), findsNothing);

    await tester.tap(find.byKey(const Key('reject_b')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('reject_note')), 'Référence introuvable');
    await tester.tap(find.text('Refuser').last);
    await tester.pumpAndSettle();
    expect(repo.adminOps.last, ('reject', 'b', 'Référence introuvable'));
    expect(find.text('Tout est à jour'), findsOneWidget);

    // Historique : en ligne et par transfert
    await tester.tap(find.byKey(const Key('pay_tab_history')));
    await tester.pumpAndSettle();
    expect(find.text('Boutique Awa'), findsOneWidget);
    expect(find.textContaining('Référence introuvable'), findsOneWidget);
    await tester.tap(find.text('Payés'));
    await tester.pumpAndSettle();
    expect(find.text('Koné Market'), findsNothing);
    expect(find.text('Encaissé : 50 000 F'.replaceAll(' ', ' ')), findsNothing); // séparateur fin selon la locale
    expect(find.textContaining('Encaissé'), findsOneWidget);
  });

  testWidgets('commerçants : recherche, filtres, fiche, offrir du Pro, suspendre', (tester) async {
    phoneSize(tester);
    final repo = adminRepo();
    await pumpSama(tester, location: '/admin/merchants', repo: repo);
    expect(find.text('Boutique Awa'), findsOneWidget);
    expect(find.text('Chez Maman Mav'), findsOneWidget);
    expect(find.text('3 boutiques'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('admin_search')), 'kon');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('Koné Market'), findsOneWidget);
    expect(find.text('Boutique Awa'), findsNothing);
    expect(repo.adminQueries.last.search, 'kon');

    await tester.tap(find.byTooltip('Effacer'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('admin_plan_active')));
    await tester.pumpAndSettle();
    expect(repo.adminQueries.last.plan, AdminPlan.active);
    expect(find.text('Boutique Awa'), findsOneWidget);
    expect(find.text('Chez Maman Mav'), findsNothing);

    // Fiche
    await tester.tap(find.byKey(const Key('admin_biz_b1')));
    await tester.pumpAndSettle();
    expect(find.text('Boutique Awa'), findsWidgets);
    expect(find.text('Offrir des jours de Pro'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Dépôt Pikine'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.textContaining('15 jour(s) de Pro offert(s)'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const Key('admin_gift')),
      -300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('admin_gift')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('gift_90')));
    await tester.enterText(find.byKey(const Key('gift_reason')), 'Merci pour votre fidélité');
    await tester.tap(find.text('Offrir'));
    await tester.pumpAndSettle();
    expect(repo.adminOps.last, ('gift:90', 'b1', 'Merci pour votre fidélité'));

    await tester.tap(find.byKey(const Key('admin_suspend')));
    await tester.pumpAndSettle();
    // Raison obligatoire
    final confirm = find.widgetWithText(FilledButton, 'Suspendre');
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('suspend_reason')), 'Fraude signalée');
    await tester.pump();
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(repo.adminOps.last, ('suspend', 'b1', 'Fraude signalée'));
  });

  testWidgets('grand écran : menu latéral et tableau des commerçants', (tester) async {
    desktopSize(tester);
    final repo = adminRepo();
    await pumpSama(tester, location: '/admin', repo: repo);
    expect(find.text('Back office'), findsOneWidget);
    expect(find.byKey(const Key('admin_side_merchants')), findsOneWidget);
    expect(find.byKey(const Key('admin_tab_merchants')), findsNothing);
    expect(find.text('Boutiques les plus actives'), findsOneWidget);
    expect(find.text('Essais qui se terminent'), findsOneWidget);

    await tester.tap(find.byKey(const Key('admin_side_merchants')));
    await tester.pumpAndSettle();
    expect(find.text('Dernière vente'), findsOneWidget); // en-tête du tableau
    expect(find.text('Koné Market'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('réservé à l’équipe Sama360', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/admin', repo: FakeRepo()..platformAdmin = false);
    expect(find.text('Réservé à l’équipe Sama360'), findsOneWidget);
  });

  test('libellés de durée et montants courts', () {
    final now = DateTime(2026, 11, 23, 15);
    expect(sinceLabel(null, now: now), 'jamais');
    expect(sinceLabel(DateTime(2026, 11, 23, 8), now: now), 'aujourd’hui');
    expect(sinceLabel(DateTime(2026, 11, 22, 23), now: now), 'hier');
    expect(sinceLabel(DateTime(2026, 11, 13), now: now), 'il y a 10 j');
    expect(sinceLabel(DateTime(2026, 8, 1), now: now), 'il y a 3 mois');
    expect(compactMoney(2450000), '2,5 M F');
    expect(compactMoney(48500000), '49 M F');
    expect(compactMoney(185000), '185 k F');
    expect(AdminOverview.change(21, 14), 50);
    expect(AdminOverview.change(3, 0), isNull);
  });
}
