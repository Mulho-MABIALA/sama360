import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/api/api_client.dart';
import 'package:sama360/core/format.dart';
import 'package:sama360/core/models.dart';
import 'package:sama360/core/widgets.dart';
import 'package:sama360/features/pro/pro_screen.dart';
import 'package:sama360/features/sales/receipt_screen.dart';

import 'helpers.dart';
import 'receipt_test.dart' show RecordingActions;

void main() {
  setUpAll(loadTestFonts);

  group('textes', () {
    test('lien et message de parrainage', () {
      expect(referralLink('http://192.168.1.12:3000/', 'AWA7K2'), 'http://192.168.1.12:3000/app/?ref=AWA7K2');
      final m = referralMessage(business: 'Awa Beauté', code: 'AWA7K2', link: 'https://x/app/?ref=AWA7K2');
      expect(m, contains('Je gère Awa Beauté avec Sama360'));
      expect(m, contains('mon code *AWA7K2*'));
      expect(m, contains('1 mois de Sama360 Pro'));
      expect(m, endsWith('👉 https://x/app/?ref=AWA7K2'));
    });

    test('statut lisible', () async {
      await initializeDateFormatting('fr');
      ProStatus s(ProState st, {int days = 0, DateTime? end}) => ProStatus(
        pro: st == ProState.trial || st == ProState.active,
        state: st,
        daysLeft: days,
        endsAt: end,
        monthly: 5000,
        yearly: 50000,
        methods: const [],
      );
      expect(proHeadline(s(ProState.trial, days: 23)), 'Essai Pro offert · 23 jours restants');
      expect(proHeadline(s(ProState.trial, days: 1)), 'Essai Pro offert · dernier jour');
      expect(proHeadline(s(ProState.active, end: DateTime(2026, 12, 18, 12))), 'Pro actif jusqu’au 18 décembre 2026');
      expect(proHeadline(s(ProState.expired)), 'Votre Sama360 Pro est terminé');
    });
  });

  testWidgets('sans Pro : la tuile Livraison mène à l’offre, puis « J’ai payé »', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo()..proUntil = DateTime(2026, 1, 1);
    await pumpSama(tester, repo: repo);
    await tester.ensureVisible(find.byIcon(Icons.apps_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.apps_rounded));
    await tester.pumpAndSettle();
    expect(find.text('PRO'), findsWidgets); // tuiles verrouillées marquées
    await tester.tap(find.text('Livraison'));
    await tester.pumpAndSettle();

    expect(find.text('Votre Sama360 Pro est terminé'), findsOneWidget);
    expect(find.text('« Livraisons et livreurs » fait partie de Sama360 Pro.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('cycle_yearly')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('pay_submit')),
      300,
      scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first,
    );
    await tester.ensureVisible(find.byKey(const Key('pay_submit')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Envoyez ${moneyShort(50000)} à : Wave au 77 000 00 00 (Zolaa Tech)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('pay_submit')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Recopiez la référence'), findsOneWidget);

    await tester.tap(find.text('Orange Money'));
    await tester.enterText(find.byKey(const Key('pay_ref')), 'OM2611.1834.A12345');
    await tester.enterText(find.byKey(const Key('pay_phone')), '77 555 66 77');
    await tester.tap(find.byKey(const Key('pay_submit')));
    await tester.pumpAndSettle();
    expect(repo.proPayments.single, {
      'cycle': 'yearly',
      'method': PayMethod.orangeMoney,
      'reference': 'OM2611.1834.A12345',
      'payerPhone': '+221775556677',
    });
    expect(find.byKey(const Key('pay_pending')), findsOneWidget);
    expect(find.textContaining('réf. OM2611.1834.A12345'), findsOneWidget);
  });

  testWidgets('avec Pro (essai) : statut dans le profil, tuiles ouvertes', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo()
      ..proUntil = DateTime.now().add(const Duration(days: 23, hours: 2))
      ..proTrial = true;
    await pumpSama(tester, location: '/account', repo: repo);
    await tester.scrollUntilVisible(find.byKey(const Key('pro_row')), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Essai · 24 j'), findsOneWidget);
    await tester.tap(find.byKey(const Key('pro_row')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Essai Pro offert'), findsOneWidget);
  });

  testWidgets('erreur PRO_REQUIRED : proposer Pro au lieu d’une erreur rouge', (tester) async {
    phoneSize(tester);
    final (c, _) = await pumpSama(tester, location: '/');
    final ctx = tester.element(find.byType(Scaffold).first);
    showError(
      ctx,
      const ApiException(
        'PRO_REQUIRED',
        'Livraisons et livreurs : fonction Sama360 Pro',
        details: {'feature': 'delivery'},
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Passer à Pro'), findsOneWidget);
    await tester.tap(find.text('Passer à Pro'));
    await tester.pumpAndSettle();
    expect(routerOf(c).state.uri.toString(), '/pro?feature=delivery');
  });

  testWidgets('parrainage : code, invitation WhatsApp, filleuls', (tester) async {
    phoneSize(tester);
    final actions = RecordingActions();
    final repo = FakeRepo()
      ..referralInfo = ReferralInfo(
        code: 'AWA7K2',
        bonusDays: 30,
        daysEarned: 30,
        referrals: [
          Referral(name: 'Ibou Quincaillerie', city: 'Thiès', joinedAt: DateTime(2026, 11, 2), rewarded: true),
          Referral(name: 'Chez Maman Mav', joinedAt: DateTime(2026, 11, 15), rewarded: false),
        ],
      );
    await pumpSama(
      tester,
      location: '/referral',
      repo: repo,
      overrides: [receiptActionsProvider.overrideWithValue(actions)],
    );
    expect(find.text('AWA7K2'), findsOneWidget);
    expect(find.text('+1 mois'), findsOneWidget);
    expect(find.text('En essai'), findsOneWidget);
    await tester.tap(find.byKey(const Key('share_referral')));
    await tester.pump();
    final text = Uri.decodeFull(actions.whatsApp.toString());
    expect(text, contains('mon code *AWA7K2*'));
    expect(text, contains('/app/?ref=AWA7K2'));
  });

  testWidgets('création d’entreprise avec un code de parrainage', (tester) async {
    phoneSize(tester);
    final (_, repo) = await pumpSama(tester, location: '/business');
    await tester.tap(find.text('Créer une entreprise'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('businessName')), 'Ibou Quincaillerie');
    await tester.ensureVisible(find.byKey(const Key('referralCode')));
    await tester.enterText(find.byKey(const Key('referralCode')), 'awa7k2 ');
    await tester.ensureVisible(find.text("Créer l'entreprise"));
    await tester.tap(find.text("Créer l'entreprise"));
    await tester.pumpAndSettle();
    expect(repo.createdBusinesses.single, containsPair('referralCode', 'AWA7K2'));
  });

  testWidgets('équipe Sama360 : valider et refuser des paiements', (tester) async {
    phoneSize(tester);
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
    final repo = FakeRepo()
      ..platformAdmin = true
      ..adminQueue.addAll([req('a', 'Koné Market', Country.ci), req('b', 'Chez Maman Mav', Country.cg)]);
    await pumpSama(tester, location: '/account', repo: repo);
    await tester.scrollUntilVisible(find.byKey(const Key('admin_row')), 200, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(find.byKey(const Key('admin_row')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('admin_row')));
    await tester.pumpAndSettle();
    expect(find.text('Koné Market'), findsOneWidget);
    expect(find.textContaining('payé depuis +225 07 07 12 34 56'), findsWidgets);

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
    expect(find.text('Rien ici'), findsOneWidget);
  });
}
