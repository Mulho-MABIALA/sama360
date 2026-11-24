import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/api/session_store.dart';
import 'package:sama360/core/format.dart';
import 'package:sama360/core/models.dart';
import 'package:sama360/core/providers.dart';
import 'package:sama360/features/auth/auth_controller.dart';
import 'package:sama360/features/auth/login_screens.dart';
import 'package:sama360/features/sales/cart.dart';
import 'package:sama360/main.dart';

import 'helpers.dart';

class _SignedOut extends AuthController {
  final sent = <String>[];
  final channels = <OtpChannel?>[];
  @override
  Future<AuthState> build() async => const AuthState();
  @override
  Future<OtpTarget> requestOtp(String phone, {OtpChannel? channel}) async {
    sent.add(phone);
    channels.add(channel);
    return OtpTarget(phone, channel: channel ?? OtpChannel.sms);
  }
}

void main() {
  setUpAll(loadTestFonts);

  group('numéros', () {
    test('saisie locale selon le pays', () {
      expect(localPhone('77 123 45 67', Country.sn), '+221771234567');
      expect(localPhone('07 07 12 34 56', Country.ci), '+2250707123456');
      expect(localPhone('27 22 44 55 66', Country.ci), '+2252722445566');
      expect(localPhone('06 612 34 56', Country.cg), '+242066123456');
      expect(localPhone('+221 77 123 45 67', Country.cg), '+221771234567');
      expect(localPhone('77 123 45 67', Country.ci), isNull);
      expect(localPhone('07 12 34 56', Country.ci), isNull); // ancien format à 8 chiffres
      expect(localPhone('09 612 34 56', Country.cg), isNull);
      expect(senegalPhone('771234567'), '+221771234567');
    });

    test('affichage', () {
      expect(displayPhone('+221771234567'), '77 123 45 67');
      expect(displayPhone('+2250707123456'), '07 07 12 34 56');
      expect(displayPhone('+242066123456'), '06 612 34 56');
      expect(displayPhone('+33612345678'), '+33612345678');
      expect(intlPhone('+2250707123456'), '+225 07 07 12 34 56');
      expect(intlPhone('+242066123456'), '+242 06 612 34 56');
      expect(editablePhone('+2250707123456', Country.ci), '07 07 12 34 56');
      expect(editablePhone('+221771234567', Country.ci), '+221 77 123 45 67');
      expect(invalidPhone(Country.ci), 'Numéro invalide : 10 chiffres, ex. 07 07 12 34 56');
    });

    test('paiements de la caisse par pays', () {
      expect(PaymentMode.forCountry(Country.sn), [
        PaymentMode.cash,
        PaymentMode.wave,
        PaymentMode.orangeMoney,
        PaymentMode.credit,
      ]);
      expect(PaymentMode.forCountry(Country.ci).map((m) => m.label), [
        'Espèces',
        'Wave',
        'O. Money',
        'MTN MoMo',
        'Moov',
        'Crédit',
      ]);
      expect(PaymentMode.forCountry(Country.cg).map((m) => m.method), [
        PayMethod.cash,
        PayMethod.mtnMomo,
        PayMethod.airtelMoney,
        null,
      ]);
    });
  });

  testWidgets('connexion depuis Abidjan : numéro ivoirien à 10 chiffres', (tester) async {
    phoneSize(tester);
    await initializeDateFormatting('fr');
    final auth = _SignedOut();
    final c = ProviderContainer(
      overrides: [sessionStoreProvider.overrideWithValue(MemorySessionStore()), authProvider.overrideWith(() => auth)],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const SamaApp(googleFonts: false)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('country_CI')));
    await tester.pump();
    expect(find.text('+225  '), findsOneWidget);
    await tester.enterText(find.byKey(const Key('phone')), '77 123 45 67');
    await tester.tap(find.text('Recevoir le code'));
    await tester.pump();
    expect(find.text('Numéro invalide : 10 chiffres, ex. 07 07 12 34 56'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('phone')), '07 07 12 34 56');
    await tester.tap(find.text('Recevoir le code'));
    await tester.pumpAndSettle();
    expect(auth.sent, ['+2250707123456']);
    expect(c.read(loginCountryProvider), Country.ci);
  });

  testWidgets('code par WhatsApp ou SMS au choix ; « Pas reçu ? » : SMS ou appel', (tester) async {
    phoneSize(tester);
    await initializeDateFormatting('fr');
    final auth = _SignedOut();
    final c = ProviderContainer(
      overrides: [
        sessionStoreProvider.overrideWithValue(MemorySessionStore()),
        authProvider.overrideWith(() => auth),
        otpChannelsProvider.overrideWith((_) async => OtpChannel.values),
      ],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const SamaApp(googleFonts: false)));
    await tester.pumpAndSettle();

    // WhatsApp proposé d'abord ; l'appel n'est qu'un recours
    expect(find.text('Nous vous envoyons un code de connexion par WhatsApp.'), findsOneWidget);
    expect(find.byKey(const Key('otp_by_call')), findsNothing);
    // Pas de WhatsApp sur ce numéro : SMS
    await tester.tap(find.byKey(const Key('otp_by_sms')));
    await tester.pump();
    expect(find.text('Nous vous envoyons un code de connexion par SMS.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('phone')), '78 730 87 06');
    await tester.tap(find.text('Recevoir le code'));
    await tester.pumpAndSettle();
    expect(auth.channels, [OtpChannel.sms]);
    expect(find.textContaining('Envoyé par SMS au +221 78 730 87 06'), findsOneWidget);

    // « Pas reçu ? » : WhatsApp ou appel, après 15 secondes
    final callBtn = find.byKey(const Key('otp_switch_call'));
    expect(tester.widget<ButtonStyleButton>(callBtn).onPressed, isNull);
    await tester.pump(const Duration(seconds: 16));
    await tester.ensureVisible(callBtn);
    await tester.tap(callBtn);
    await tester.pumpAndSettle();
    expect(auth.channels, [OtpChannel.sms, OtpChannel.call]);
    expect(find.textContaining('Envoyé par appel vocal'), findsOneWidget);
    expect(find.text('Décrochez : une voix vous dicte le code.'), findsOneWidget);
    // Le SMS reste retenu pour la prochaine fois (l'appel n'est qu'un recours)
    expect(c.read(preferredOtpChannelProvider), OtpChannel.sms);
    await tester.pump(const Duration(seconds: 61));
  });

  testWidgets('serveur de test : adresse vérifiée puis gardée', (tester) async {
    phoneSize(tester);
    await initializeDateFormatting('fr');
    final c = ProviderContainer(
      overrides: [
        sessionStoreProvider.overrideWithValue(MemorySessionStore()),
        authProvider.overrideWith(_SignedOut.new),
      ],
    );
    addTearDown(c.dispose);
    final tried = <String>[];
    serverReachable = (url) async {
      tried.add(url);
      return url.contains('192.168.1.20');
    };
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const SamaApp(googleFonts: false)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('server_setting')));
    await tester.tap(find.byKey(const Key('server_setting')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('server_url')), '10.0.0.9:3000');
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Pas de réponse de http://10.0.0.9:3000/health'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('server_url')), 'http://192.168.1.20:3000/');
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();
    expect(c.read(apiBaseUrlProvider), 'http://192.168.1.20:3000');
    expect(find.text('Serveur : 192.168.1.20:3000'), findsOneWidget);
  });

  testWidgets('création d’entreprise au Congo : pays et ville envoyés', (tester) async {
    phoneSize(tester);
    final (_, repo) = await pumpSama(tester, location: '/business');
    await tester.tap(find.text('Créer une entreprise'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('businessName')), 'Chez Maman Mav');
    await tester.ensureVisible(find.byKey(const Key('country_CG')));
    await tester.tap(find.byKey(const Key('country_CG')));
    await tester.pump();
    await tapCentered(tester, find.text('Pointe-Noire'));
    await tester.pump();
    await tester.pumpAndSettle();
    await tapCentered(tester, find.text("Créer l'entreprise"));
    await tester.pumpAndSettle();
    expect(repo.createdBusinesses.single, containsPair('country', 'CG'));
    expect(repo.createdBusinesses.single, containsPair('city', 'Pointe-Noire'));
  });

  testWidgets('boutique ivoirienne : caisse avec MTN MoMo et Moov, client au format ivoirien', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo()..businessCountry = Country.ci;
    final (c, _) = await pumpSama(tester, location: '/pos', repo: repo);
    expect(c.read(countryProvider), Country.ci);
    expect(find.text('MTN MoMo'), findsOneWidget);
    expect(find.text('Moov'), findsOneWidget);
    expect(find.text('Wave'), findsOneWidget);
  });

  testWidgets('profil : changer le pays de l’entreprise', (tester) async {
    phoneSize(tester);
    final (c, repo) = await pumpSama(tester, location: '/business/settings');
    await tester.scrollUntilVisible(
      find.byKey(const Key('country_row')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Sénégal'), findsOneWidget);
    await tester.tap(find.byKey(const Key('country_row')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('country_CG')).last);
    await tester.pump();
    expect(find.textContaining('numéros congolais'), findsOneWidget);
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();
    expect(repo.businessCountry, Country.cg);
    expect(c.read(countryProvider), Country.cg);
  });
}
