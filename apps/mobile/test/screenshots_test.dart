@Tags(['screenshots'])
library;

/// Captures des écrans (390 × 844) pour relecture visuelle.
/// Générer : SAMA_SCREENSHOTS=1 flutter test test/screenshots_test.dart --update-goldens
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/biometrics.dart';
import 'package:sama360/core/pin_lock.dart';
import 'package:sama360/core/display.dart';
import 'package:sama360/core/api/session_store.dart';
import 'package:sama360/core/models.dart';
import 'package:sama360/core/offline/pending_sales.dart';
import 'package:sama360/core/providers.dart';
import 'package:sama360/features/auth/auth_controller.dart';
import 'package:sama360/features/catalog/barcode_scanner.dart';
import 'package:sama360/features/catalog/product_photo.dart';
import 'package:sama360/features/home/monument.dart';
import 'package:sama360/main.dart';

import 'package:sama360/features/shop/status_screen.dart';
import 'helpers.dart';

/// Dépôt dont les photos de produits sont de vraies images.
class _PhotoRepo extends FakeRepo {
  @override
  Future<List<int>?> fileBytes(String fileId) async => File('test/fixtures/photos/$fileId.jpg').readAsBytesSync();
}

class _SignedOut extends AuthController {
  @override
  Future<AuthState> build() async => const AuthState();
}

Future<void> _shot(WidgetTester tester, String name) async {
  debugDisableShadows = false; // ombres floues réelles, comme sur le téléphone
  try {
    // Les photos affichées doivent être décodées avant la capture.
    for (final e in find.byType(Image).evaluate().toList()) {
      await tester.runAsync(() => precacheImage((e.widget as Image).image, e));
    }
    for (final r in tester.allRenderObjects) {
      r.markNeedsPaint();
    }
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('screenshots/$name.png'));
  } finally {
    debugDisableShadows = true;
  }
}

Future<void> _precacheMonument(WidgetTester tester, DateTime day) async {
  final ctx = tester.element(find.byType(MonumentBackdrop));
  await tester.runAsync(() => precacheImage(AssetImage(monumentOfDay(day).asset), ctx));
  await tester.pumpAndSettle();
}

void main() {
  if (Platform.environment['SAMA_SCREENSHOTS'] != '1') return; // rendu dépendant de la machine
  setUpAll(loadTestFonts);

  testWidgets('connexion', (tester) async {
    phoneSize(tester);
    await initializeDateFormatting('fr');
    final c = ProviderContainer(
      overrides: [
        sessionStoreProvider.overrideWithValue(MemorySessionStore()),
        authProvider.overrideWith(_SignedOut.new),
      ],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const SamaApp(googleFonts: false)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '77 123 45 67');
    await _shot(tester, '1_connexion');
  });

  /// Accueil avec la photo du monument du jour réellement décodée.
  Future<void> home(WidgetTester tester, DateTime day, String name) async {
    phoneSize(tester);
    await pumpSama(tester, overrides: [monumentDateProvider.overrideWithValue(day)]);
    final ctx = tester.element(find.byType(MonumentBackdrop));
    await tester.runAsync(() => precacheImage(AssetImage(monumentOfDay(day).asset), ctx));
    await tester.pumpAndSettle();
    await _shot(tester, name);
  }

  testWidgets('accueil', (tester) => home(tester, DateTime(2026, 11, 16), '2_accueil'));
  testWidgets('tous les services (photos)', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, overrides: [monumentDateProvider.overrideWithValue(DateTime(2026, 11, 16))]);
    await tester.ensureVisible(find.byIcon(Icons.apps_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.apps_rounded));
    await tester.pumpAndSettle();
    await _shot(tester, '2e_tous_les_services');
  });
  testWidgets('accueil (Djenné)', (tester) => home(tester, DateTime(2026, 11, 17), '2c_accueil_djenne'));
  testWidgets('accueil (Gizeh)', (tester) => home(tester, DateTime(2026, 11, 18), '2d_accueil_gizeh'));
  testWidgets('accueil (Tour Eiffel)', (tester) => home(tester, DateTime(2026, 11, 19), '2e_accueil_eiffel'));

  testWidgets('accueil (montants masqués)', (tester) async {
    phoneSize(tester);
    final (c, _) = await pumpSama(tester, overrides: [monumentDateProvider.overrideWithValue(DateTime(2026, 11, 16))]);
    final ctx = tester.element(find.byType(MonumentBackdrop));
    await tester.runAsync(() => precacheImage(AssetImage(monumentOfDay(DateTime(2026, 11, 16)).asset), ctx));
    await tester.tap(find.byTooltip('Masquer les montants'));
    await tester.pumpAndSettle();
    await _shot(tester, '2f_accueil_masque');
    await c.read(displaySettingsProvider.notifier).toggleAmounts();
  });

  testWidgets('accueil (bas, carrousel)', (tester) async {
    phoneSize(tester);
    await pumpSama(tester);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -420));
    await _shot(tester, '2b_accueil_carrousel');
  });

  testWidgets('caisse', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/pos');
    await tester.tap(find.text('Beurre de karité 250 g'));
    await tester.tap(find.text('Beurre de karité 250 g'));
    await tester.tap(find.text('Huile de coco 500 ml'));
    await tester.tap(find.text('Wave'));
    await _shot(tester, '3_caisse');
  });

  testWidgets('stock', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/stock');
    await _shot(tester, '4_stock');
  });

  testWidgets('credits', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/customers');
    await _shot(tester, '5_credits');
  });

  testWidgets('fiche client', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/customers/k1');
    await _shot(tester, '6_fiche_client');
  });

  testWidgets('nouveau produit', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/stock');
    await tester.tap(find.text('Nouveau produit'));
    await _shot(tester, '7_nouveau_produit');
  });

  testWidgets('reçu', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/sales/s2');
    await _shot(tester, '9_recu');
  });

  testWidgets('ventes du jour', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/sales');
    await _shot(tester, '9b_ventes_du_jour');
  });

  testWidgets('profil', (tester) async {
    phoneSize(tester);
    await pumpSama(tester);
    await tester.tap(find.text('AD').first);
    await _shot(tester, '8_profil');
  });

  testWidgets('profil (bas)', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/account');
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -700));
    await _shot(tester, '8b_profil_bas');
  });

  Future<void> offlineSales(WidgetTester tester) async {
    final (c, repo) = await pumpSama(tester, location: '/pos');
    repo.offline = true;
    for (final (id, p, q) in [('o1', demoProducts[0], 2.0), ('o2', demoProducts[2], 1.0)]) {
      await c
          .read(pendingSalesProvider.notifier)
          .checkout(
            id: id,
            businessId: 'b1',
            lines: [(product: p, quantity: q)],
            payments: [(method: PayMethod.cash, amount: (p.price * q).round())],
            total: (p.price * q).round(),
          );
    }
    c.read(apiClientProvider).online.value = false; // le client a constaté la coupure
    await tester.pumpAndSettle();
  }

  testWidgets('hors ligne : caisse', (tester) async {
    phoneSize(tester);
    await offlineSales(tester);
    await _shot(tester, '10_hors_ligne_caisse');
  });

  testWidgets('hors ligne : accueil', (tester) async {
    phoneSize(tester);
    await offlineSales(tester);
    await tester.tap(find.text('Accueil'));
    await tester.pumpAndSettle();
    await _shot(tester, '10b_hors_ligne_accueil');
  });

  testWidgets('hors ligne : historique', (tester) async {
    phoneSize(tester);
    await offlineSales(tester);
    await tester.tap(find.byTooltip("Ventes d'aujourd'hui"));
    await _shot(tester, '10c_hors_ligne_historique');
  });

  testWidgets('équipe', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/team');
    await _shot(tester, '11_equipe');
  });

  testWidgets('équipe : invitation', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/team');
    await tester.tap(find.text('Inviter'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('invitePhone')), '70 123 45 67');
    await tester.enterText(find.byKey(const Key('inviteName')), 'Ibou Ndiaye');
    FocusManager.instance.primaryFocus?.unfocus();
    await _shot(tester, '11b_equipe_invitation');
  });

  testWidgets('accueil : vendeurs du jour', (tester) async {
    phoneSize(tester);
    await pumpSama(tester);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -900));
    await _shot(tester, '11c_vendeurs_du_jour');
  });

  Future<FakeRepo> seedDocs(FakeRepo repo) async {
    Map<String, dynamic> body(List<Map<String, Object>> lines, {int discount = 0, String? due, String? note}) => {
      'customerId': 'c1',
      'lines': lines,
      'discount': discount,
      'dueDate': ?due,
      'note': ?note,
    };
    await repo.createDocument(
      id: 'q1',
      kind: DocKind.quote,
      body: body(
        [
          {'name': 'Nappe brodée', 'quantity': 4, 'unitPrice': 15000},
          {'name': 'Livraison et pose', 'description': 'Plateau, Dakar', 'quantity': 1, 'unitPrice': 20000},
        ],
        discount: 5000,
        due: '2026-12-16',
        note: 'Livraison sous 72 h',
      ),
    );
    await repo.quoteAction('q1', 'accept');
    final inv = await repo.convertQuote('q1');
    await repo.payInvoice(inv.id, paymentId: 'p1', amount: 30000, method: PayMethod.wave, reference: 'WV-123');
    await repo.createDocument(
      id: 'f2',
      kind: DocKind.invoice,
      body: body([
        {'name': 'Couture tenue de cérémonie', 'quantity': 2, 'unitPrice': 25000},
      ], due: '2026-11-30'),
    );
    return repo;
  }

  testWidgets('factures : liste', (tester) async {
    phoneSize(tester);
    final repo = await seedDocs(FakeRepo());
    await pumpSama(tester, location: '/invoices', repo: repo);
    await _shot(tester, '12_factures');
  });

  testWidgets('factures : détail', (tester) async {
    phoneSize(tester);
    final repo = await seedDocs(FakeRepo());
    await pumpSama(tester, location: '/invoices/inv-q1', repo: repo);
    await _shot(tester, '12b_facture');
  });

  testWidgets('factures : éditeur', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/invoices/new?kind=quote');
    await tester.tap(find.text('Choisir le client'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hôtel Teranga'));
    await tester.pumpAndSettle();
    for (final name in ['Beurre de karité 250 g', 'Savon noir', 'Savon noir']) {
      await tester.tap(find.text('Produit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(name).last);
      await tester.pumpAndSettle();
    }
    await _shot(tester, '12c_devis_editeur');
  });

  testWidgets('rapports', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/reports');
    await _shot(tester, '13_rapports');
  });

  testWidgets('premiers pas', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo()
      ..onboardingValue = const Onboarding(
        focus: 'products',
        dismissed: false,
        steps: [
          OnboardingStep('add_products', true),
          OnboardingStep('first_sale', true),
          OnboardingStep('logo_phone', false),
          OnboardingStep('shop_online', false),
          OnboardingStep('invite_member', false),
        ],
      );
    await pumpSama(
      tester,
      repo: repo,
      overrides: [monumentDateProvider.overrideWithValue(DateTime(2026, 11, 16))],
      biometrics: FakeBiometrics(kindValue: BiometricKind.fingerprint),
    );
    await tester.drag(find.byType(ListView).first, const Offset(0, -330));
    await tester.pumpAndSettle();
    await _shot(tester, '0f_premiers_pas');
  });

  testWidgets('premiers pas (question)', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo()..onboardingValue = const Onboarding(dismissed: false, steps: []);
    await pumpSama(tester, repo: repo, overrides: [monumentDateProvider.overrideWithValue(DateTime(2026, 11, 16))]);
    await tester.drag(find.byType(ListView).first, const Offset(0, -330));
    await tester.pumpAndSettle();
    await _shot(tester, '0g_question_activite');
  });

  testWidgets('création d’entreprise', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/business');
    await tester.tap(find.text('Créer une entreprise'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('businessName')), 'Salon Ndeye');
    await tester.tap(find.text('Salon / beauté'));
    await tester.pumpAndSettle();
    await _shot(tester, '0h_creation_entreprise');
  });

  testWidgets('code secret', (tester) async {
    phoneSize(tester);
    await pumpSama(
      tester,
      pinStore: MemoryPinStore(StoredPin(userId: 'u1', hash: hashPin('2580'))),
      overrides: [monumentDateProvider.overrideWithValue(DateTime(2026, 11, 17))],
    );
    await _precacheMonument(tester, DateTime(2026, 11, 17));
    await tester.tap(find.byKey(const Key('pin_key_2')));
    await tester.tap(find.byKey(const Key('pin_key_5')));
    await tester.pumpAndSettle();
    await _shot(tester, '0c_code_secret');
  });

  testWidgets('code secret (création)', (tester) async {
    phoneSize(tester);
    await pumpSama(
      tester,
      pinStore: MemoryPinStore(),
      overrides: [monumentDateProvider.overrideWithValue(DateTime(2026, 11, 20))],
    );
    await _precacheMonument(tester, DateTime(2026, 11, 20));
    await _shot(tester, '0d_code_creation');
  });

  testWidgets('code secret (action sensible)', (tester) async {
    phoneSize(tester);
    final store = MemoryPinStore(StoredPin(userId: 'u1', hash: hashPin('2580')));
    final (c, _) = await pumpSama(
      tester,
      location: '/sales/s2',
      pinStore: store,
      overrides: [monumentDateProvider.overrideWithValue(DateTime(2026, 11, 18))],
    );
    await c.read(pinLockProvider.notifier).unlockWithBiometrics();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Annuler la vente'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('voidReason')), 'Erreur de saisie');
    await tester.tap(find.text('Oui, annuler'));
    await tester.pumpAndSettle();
    await _precacheMonument(tester, DateTime(2026, 11, 18));
    await tester.tap(find.byKey(const Key('pin_key_2')));
    await tester.pumpAndSettle();
    await _shot(tester, '0e_code_confirmation');
  });

  testWidgets('réservations', (tester) async {
    phoneSize(tester);
    final now = DateTime.now();
    DateTime at(int h, [int m = 0]) => DateTime(now.year, now.month, now.day, h, m);
    Appointment a(String id, String name, String service, int price, DateTime t, int d, AppointmentStatus s) =>
        Appointment(
          id: id,
          customerName: name,
          customerPhone: '+221775556677',
          serviceName: service,
          price: price,
          startsAt: t,
          durationMinutes: d,
          status: s,
        );
    final repo = FakeRepo()
      ..appointmentList.addAll([
        a('a1', 'Fatou Sow', 'Tresses africaines', 15000, at(9), 120, AppointmentStatus.done),
        a('a2', 'Mariama Ba', 'Brushing', 3000, at(11, 30), 30, AppointmentStatus.booked),
        a('a3', 'Khady Ndiaye', 'Pose de vernis', 2500, at(14), 45, AppointmentStatus.booked),
        a('a4', 'Aminata Fall', 'Coupe enfant', 2000, at(16), 30, AppointmentStatus.noShow),
        a('a5', 'Coumba Diop', 'Tissage', 20000, at(17), 180, AppointmentStatus.booked),
      ]);
    await pumpSama(tester, location: '/booking', repo: repo);
    await _shot(tester, '18_reservations');
  });

  testWidgets('réservation en ligne (réglages)', (tester) async {
    phoneSize(tester);
    const tresses = Product(id: 's1', name: 'Tresses', price: 15000, cost: 0, isService: true, trackStock: false);
    final repo = FakeRepo()
      ..extraProducts = const [tresses]
      ..bookingSettingsValue = const BookingSettings(onlineEnabled: true, capacity: 2, bookingPath: '/r/awa-beaute');
    await pumpSama(tester, location: '/booking/settings', repo: repo);
    await _shot(tester, '18b_reservation_en_ligne');
  });

  testWidgets('assistant', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/assistant');
    await _shot(tester, '17_assistant');
    await tester.tap(find.text("Combien j'ai vendu aujourd'hui ?"));
    await tester.pumpAndSettle();
    await _shot(tester, '17b_assistant_reponse');
  });

  testWidgets('documents', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/documents');
    await _shot(tester, '16_documents');
  });

  testWidgets('document (fiche)', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/documents/d1');
    await _shot(tester, '16b_document');
  });

  testWidgets('analyses', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/insights');
    await _shot(tester, '13c_analyses');
    await tester.scrollUntilVisible(find.text('Produits qui ne se vendent plus'), 300);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -260));
    await tester.pumpAndSettle();
    await _shot(tester, '13d_analyses_bas');
  });

  testWidgets('rapport de la semaine', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/insights/week');
    await _shot(tester, '13e_rapport_semaine');
  });

  testWidgets('rapports (bas)', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/reports');
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -900));
    await _shot(tester, '13b_rapports_bas');
  });

  testWidgets('fiche produit', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/products/p2');
    await _shot(tester, '14_fiche_produit');
  });

  testWidgets('fiche produit (bas)', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/products/p2');
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -700));
    await _shot(tester, '14b_fiche_produit_bas');
  });

  testWidgets('catégories', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/categories');
    await _shot(tester, '14c_categories');
  });

  testWidgets('fiche client : bas (carnet)', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/customers/k1');
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -760));
    await _shot(tester, '15_fiche_client_carnet');
  });

  testWidgets('fiche client : rappel', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/customers/k1');
    await tester.tap(find.text('Envoyer un rappel'));
    await tester.pumpAndSettle();
    await _shot(tester, '15b_rappel');
  });

  testWidgets('nouveau client', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/customers/k1/edit');
    await _shot(tester, '15c_modifier_client');
  });

  testWidgets('achats', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/purchases');
    await _shot(tester, '16_achats');
  });

  testWidgets('bon de commande', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/purchases/po2');
    await _shot(tester, '16b_bon_commande');
  });

  testWidgets('réception', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/purchases/po1');
    await tester.tap(find.text('Réceptionner'));
    await tester.pumpAndSettle();
    await _shot(tester, '16c_reception');
  });

  testWidgets('fournisseur', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/suppliers/s1');
    await _shot(tester, '16d_fournisseur');
  });

  testWidgets('nouvel achat depuis le stock bas', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/purchases/new?low=1&supplierId=s1');
    await _shot(tester, '16e_nouvel_achat');
  });

  testWidgets('boutique', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/shop');
    await _shot(tester, '17_boutique');
  });

  testWidgets('boutique fermée', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/shop', repo: FakeRepo()..shopEnabled = false);
    await _shot(tester, '17b_boutique_ouvrir');
  });

  testWidgets('commande en ligne', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/shop/orders/so1');
    await _shot(tester, '17c_commande_en_ligne');
  });

  testWidgets('réglages boutique', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/shop/settings');
    await _shot(tester, '17d_reglages_boutique');
  });

  testWidgets('boîte de dialogue : annuler rouge, valider vert', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/customers/c9/edit');
    await tester.tap(find.byIcon(Icons.delete_rounded));
    await tester.pumpAndSettle();
    await _shot(tester, '18_dialogue_boutons');
  });

  testWidgets('caisse ouverte', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/cash');
    await _shot(tester, '20_caisse_ouverte');
  });

  testWidgets('clôture de caisse', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/cash/close?session=cs1');
    await tester.enterText(find.byKey(const Key('count_cash')), '43000');
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    await _shot(tester, '21_cloture_caisse');
  });

  testWidgets('rapport Z', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/cash/sessions/cs0');
    await _shot(tester, '22_rapport_z');
  });

  testWidgets('livraisons', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo()
      ..ordersToDeliver = const [
        OrderToDeliver(
          orderId: 'o1',
          number: 'CMD-0042',
          customerName: 'Aminata Diop',
          customerPhone: '+221776667788',
          address: 'Sacré-Cœur 3, villa 12',
          total: 18500,
        ),
      ]
      ..courierBalances = const [CourierBalance(courierId: 'c1', name: 'Moussa Fall', owed: 25500, deliveries: 3)]
      ..deliveryList.addAll(const [
        Delivery(
          id: 'd1',
          customerName: 'Khady Sarr',
          address: 'Ouakam, près de la mosquée',
          courierId: 'c1',
          courierName: 'Moussa Fall',
          amountToCollect: 7000,
          status: DeliveryStatus.picked,
        ),
        Delivery(id: 'd2', customerName: 'Ousmane Ba', address: 'Médina rue 11', status: DeliveryStatus.pending),
      ]);
    await pumpSama(tester, location: '/deliveries', repo: repo);
    await _shot(tester, '20_livraisons');
  });

  Future<void> statusShot(WidgetTester tester, String ids, String name, {int percent = 0}) async {
    phoneSize(tester);
    final repo = _PhotoRepo()
      ..extraProducts = const [
        Product(id: 'x1', name: 'Tomates fraîches (le kilo)', price: 1200, cost: 700, imageFileId: 'ventes'),
        Product(id: 'x2', name: 'Riz parfumé 5 kg', price: 6500, cost: 5200, imageFileId: 'achats'),
        Product(id: 'x3', name: 'Coffret cadeau', price: 15000, cost: 9000, imageFileId: 'fidelite'),
      ];
    await pumpSama(tester, location: '/status?ids=$ids', repo: repo);
    if (percent > 0) {
      await tester.tap(find.text('-$percent %'));
      await tester.pumpAndSettle();
    }
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byType(StatusCard),
      200,
      scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first,
    );
    await tester.pumpAndSettle();
    await _shot(tester, name);
  }

  testWidgets('statut WhatsApp (1 produit)', (tester) => statusShot(tester, 'x1', '21_statut_whatsapp', percent: 20));
  testWidgets('statut WhatsApp (3 produits)', (tester) => statusShot(tester, 'x1,x2,x3', '21b_statut_promo'));

  testWidgets('sama360 pro', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo()
      ..proUntil = DateTime.now().add(const Duration(days: 23, hours: 3))
      ..proTrial = true;
    await pumpSama(tester, location: '/pro?feature=delivery', repo: repo);
    await _shot(tester, '22_sama360_pro');
  });

  testWidgets('parrainage', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo()
      ..referralInfo = ReferralInfo(
        code: 'AWA7K2',
        bonusDays: 30,
        daysEarned: 30,
        referrals: [
          Referral(name: 'Ibou Quincaillerie', city: 'Thiès', joinedAt: DateTime(2026, 11, 2), rewarded: true),
          Referral(name: 'Koné Market', city: 'Abidjan', joinedAt: DateTime(2026, 11, 12), rewarded: false),
          Referral(name: 'Chez Maman Mav', city: 'Brazzaville', joinedAt: DateTime(2026, 11, 15), rewarded: false),
        ],
      );
    await pumpSama(tester, location: '/referral', repo: repo);
    await _shot(tester, '23_parrainage');
  });

  testWidgets('facture en photo', (tester) async {
    phoneSize(tester);
    await pumpSama(
      tester,
      location: '/purchases',
      overrides: [
        documentPhotoPickerProvider.overrideWithValue((_) async => PickedPhoto(List<int>.filled(8, 1), 'f.jpg')),
      ],
    );
    await _shot(tester, '30_achats_facture_photo');
    await tester.tap(find.byKey(const Key('scan_invoice_banner')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Prendre une photo'));
    await tester.pumpAndSettle();
    await _shot(tester, '31_facture_verification');
  });

  testWidgets('services de l’accueil', (tester) async {
    phoneSize(tester);
    await pumpSama(tester);
    await tester.scrollUntilVisible(find.text('Vos services'), 300, scrollable: find.byType(Scrollable).first);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -200));
    await tester.pumpAndSettle();
    await _shot(tester, '35_services_accueil');
    await tester.tap(find.text('Plus'));
    await tester.pumpAndSettle();
    await _shot(tester, '36_tous_les_services');
  });

  testWidgets('points de vente', (tester) async {
    phoneSize(tester);
    const two = [
      ShopLocation(id: 'loc1', name: 'Boutique principale', isDefault: true, todayRevenue: 58000, stockValue: 820000),
      ShopLocation(
        id: 'loc2',
        name: 'Boutique Médina',
        address: 'Rue 11 x 6, Médina',
        todayRevenue: 28500,
        stockValue: 420000,
        members: 1,
      ),
    ];
    final repo = FakeRepo()..shopLocations = two;
    await pumpSama(tester, repo: repo);
    await _shot(tester, '32_accueil_points_de_vente');
    await tester.tap(find.byKey(const Key('location_chip')));
    await tester.pumpAndSettle();
    await _shot(tester, '33_choix_point_de_vente');
  });

  testWidgets('gestion des points de vente', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo()
      ..shopLocations = const [
        ShopLocation(id: 'loc1', name: 'Boutique principale', isDefault: true, todayRevenue: 58000, stockValue: 820000),
        ShopLocation(id: 'loc2', name: 'Boutique Médina', address: 'Rue 11 x 6', todayRevenue: 28500, members: 1),
      ];
    await pumpSama(tester, location: '/locations', repo: repo);
    await _shot(tester, '34_points_de_vente');
  });

  testWidgets('notifications', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/notifications');
    await _shot(tester, '23_notifications');
  });

  testWidgets('relances', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/reminders');
    await _shot(tester, '24_relances');
  });

  testWidgets('relance WhatsApp', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/reminders');
    await tester.tap(find.text('WhatsApp').first);
    await tester.pumpAndSettle();
    await _shot(tester, '25_relance_whatsapp');
  });

  testWidgets('scan depuis l’accueil', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, overrides: [barcodeScannerProvider.overrideWithValue((_) async => '6001234567891')]);
    await tester.tap(find.byTooltip('Scanner un article'));
    await tester.pumpAndSettle();
    await _shot(tester, '26_scan_accueil');
  });

  testWidgets('affichage', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/settings/display');
    await _shot(tester, '27_affichage');
  });

  testWidgets('accueil en mode sombre', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, dark: true, overrides: [monumentDateProvider.overrideWithValue(DateTime(2026, 11, 16))]);
    final ctx = tester.element(find.byType(MonumentBackdrop));
    await tester.runAsync(() => precacheImage(AssetImage(monumentOfDay(DateTime(2026, 11, 16)).asset), ctx));
    await tester.pumpAndSettle();
    await _shot(tester, '28_accueil_sombre');
  });

  testWidgets('couleur de boutique Océan', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/pos', repo: FakeRepo()..brandColor = '#1565C0');
    await _shot(tester, '29_couleur_ocean');
  });
}
