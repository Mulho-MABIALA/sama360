import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:sama360/core/models.dart';
import 'package:sama360/features/sales/pay_qr_sheet.dart';
import 'helpers.dart';

void main() {
  setUpAll(() async {
    await initializeDateFormatting('fr');
  });

  testWidgets('le patron enregistre son numéro et son lien Wave depuis le profil', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo();
    await pumpSama(tester, location: '/business/settings', repo: repo);
    await tester.scrollUntilVisible(
      find.byKey(const Key('pay_accounts_row')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('À configurer'), findsOneWidget);
    await tester.tap(find.byKey(const Key('pay_accounts_row')));
    await tester.pumpAndSettle();

    // Sénégal : Wave, Orange Money, Free Money
    expect(find.byKey(const Key('pay_number_free_money')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('pay_link_wave')), 'pay.wave.com/m/abc');
    await tester.scrollUntilVisible(
      find.byKey(const Key('pay_accounts_save')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pay_accounts_save')));
    await tester.pumpAndSettle();
    expect(find.text('Collez un lien qui commence par https://'), findsOneWidget);
    expect(repo.payAccounts, isEmpty);

    await tester.enterText(find.byKey(const Key('pay_link_wave')), 'https://pay.wave.com/m/M_sn_abc/c/sn/');
    await tester.enterText(find.byKey(const Key('pay_number_wave')), '77 123 45 67');
    await tester.enterText(find.byKey(const Key('pay_number_orange_money')), '78 765 43 21');
    await tester.scrollUntilVisible(
      find.byKey(const Key('pay_accounts_save')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pay_accounts_save')));
    await tester.pumpAndSettle();
    expect(repo.payAccounts.keys, unorderedEquals([PayMethod.wave, PayMethod.orangeMoney]));
    expect(repo.payAccounts[PayMethod.wave]!.link, 'https://pay.wave.com/m/M_sn_abc/c/sn/');
    expect(find.text('Wave, Orange Money'), findsOneWidget);
  });

  testWidgets('caisse : QR Wave avec le montant, puis encaissé', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo()
      ..payAccounts = {
        PayMethod.wave: const PayAccount(number: '771234567', link: 'https://pay.wave.com/m/M_sn_abc/c/sn/'),
        PayMethod.orangeMoney: const PayAccount(number: '787654321'),
      };
    await pumpSama(tester, location: '/pos', repo: repo);
    await tester.tap(find.text('Beurre de karité 250 g'));
    await tester.pump();
    // Espèces : rien à montrer
    expect(find.byKey(const Key('show_pay_qr')), findsNothing);

    await tester.tap(find.text('Wave'));
    await tester.pump();
    expect(find.text('Montrer le QR au client'), findsOneWidget);
    await tester.tap(find.byKey(const Key('show_pay_qr')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pay_qr_code')), findsOneWidget);
    expect(tester.widget<QrImageView>(find.byKey(const Key('pay_qr_code'))), isNotNull);
    expect(find.text('Payez par Wave'), findsOneWidget);
    expect(find.text('77 123 45 67'), findsOneWidget);

    // Retour : rien n'est encaissé
    await tester.ensureVisible(find.text('Retour'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retour'));
    await tester.pumpAndSettle();
    expect(repo.sales, isEmpty);

    // Orange Money : numéro seulement
    await tester.tap(find.text('O. Money'));
    await tester.pump();
    expect(find.text('Montrer mon numéro au client'), findsOneWidget);
    await tester.tap(find.byKey(const Key('show_pay_qr')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pay_qr_code')), findsNothing);
    expect(find.text('Envoyez le montant au'), findsOneWidget);
    expect(find.text('78 765 43 21'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('pay_qr_received')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pay_qr_received')));
    await tester.pumpAndSettle();
    expect(repo.sales, hasLength(1));
    expect((repo.sales.single['payments'] as List).single['method'], 'orange_money');
  });

  testWidgets('caisse : sans numéro, le patron est invité à l’ajouter', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/pos');
    await tester.tap(find.text('Beurre de karité 250 g'));
    await tester.tap(find.text('Wave'));
    await tester.pump();
    expect(find.byKey(const Key('show_pay_qr')), findsNothing);
    await tester.tap(find.byKey(const Key('setup_pay_qr')));
    await tester.pumpAndSettle();
    expect(find.text('Paiement mobile'), findsOneWidget);
  });

  test('numéro lisible avec ou sans indicatif', () {
    expect(payNumberDisplay('771234567', Country.sn), '77 123 45 67');
    expect(payNumberDisplay('+2250707123456', Country.sn), '07 07 12 34 56');
    expect(payNumberDisplay('12', Country.sn), '12');
  });
}
