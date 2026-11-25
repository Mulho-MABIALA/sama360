@Tags(['screenshots'])
library;

/// Tour complet de l'app : une capture par écran (390 × 844) pour relecture.
/// SAMA_SCREENSHOTS=1 flutter test test/tour_test.dart --update-goldens
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sama360/core/api/api_client.dart';
import 'package:sama360/core/admin_models.dart';
import 'package:sama360/core/models.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_ui/material_ui.dart';

import 'admin_test.dart' show adminRepo;
import 'package:sama360/features/auth/auth_controller.dart';

import 'helpers.dart';

Future<void> _shot(WidgetTester tester, String name) async {
  debugDisableShadows = false;
  try {
    for (final r in tester.allRenderObjects) {
      r.markNeedsPaint();
    }
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('screenshots/tour/$name.png'));
  } finally {
    debugDisableShadows = true;
  }
}

const routes = <String, String>{
  '01_accueil': '/',
  '02_caisse': '/pos',
  '03_stock': '/stock',
  '04_clients': '/customers',
  '05_ventes': '/sales',
  '06_recu': '/sales/s2',
  '07_produit_nouveau': '/products/new',
  '08_produit_fiche': '/products/p1',
  '09_variantes': '/products/p1/variants',
  '10_categories': '/categories',
  '11_client_fiche': '/customers/k1',
  '12_client_nouveau': '/customers/new',
  '13_profil': '/account',
  '14_ma_boutique': '/business/settings',
  '15_comptes_paiement': '/business/pay-accounts',
  '16_entreprises': '/business',
  '17_caisse_jour': '/cash',
  '18_fin_journee': '/cash/close',
  '19_historique_caisse': '/cash/history',
  '20_notifications': '/notifications',
  '21_relances': '/reminders',
  '22_affichage': '/settings/display',
  '23_fidelite': '/loyalty',
  '24_fidelite_reglages': '/loyalty/settings',
  '25_boutique_ligne': '/shop',
  '26_boutique_reglages': '/shop/settings',
  '27_boutique_produits': '/shop/products',
  '28_commande_ligne': '/shop/orders/so1',
  '29_pro': '/pro',
  '30_parrainage': '/referral',
  '31_statut': '/status',
  '32_achats': '/purchases',
  '33_achat_nouveau': '/purchases/new',
  '34_achat_fiche': '/purchases/po1',
  '35_fournisseur': '/suppliers/sp1',
  '36_points_vente': '/locations',
  '37_transfert': '/stock/transfer',
  '38_equipe': '/team',
  '39_rapports': '/reports',
  '40_analyses': '/insights',
  '41_semaine': '/insights/week',
  '42_livraisons': '/deliveries',
  '43_livraison_nouvelle': '/deliveries/new',
  '44_livreurs': '/deliveries/couriers',
  '45_rdv': '/booking',
  '46_rdv_reglages': '/booking/settings',
  '47_rdv_nouveau': '/booking/new',
  '48_assistant': '/assistant',
  '49_documents': '/documents',
  '50_factures': '/invoices',
  '51_facture_nouvelle': '/invoices/new',
  '52_facture_fiche': '/invoices/inv7',
  '53_code_pin': '/pin/change',
  '54_suppression_compte': '/account/delete',
  '55_achat_scan': '/purchases/scan',
};

void main() {
  if (Platform.environment['SAMA_SCREENSHOTS'] != '1') return;
  setUpAll(() async {
    await loadTestFonts();
    await initializeDateFormatting('fr');
    final serif = FontLoader('serif');
    for (final f in ['DejaVuSerif.ttf', 'DejaVuSerif-Italic.ttf']) {
      serif.addFont(Future.value(ByteData.view(File('/usr/share/fonts/truetype/dejavu/$f').readAsBytesSync().buffer)));
    }
    await serif.load();
  });
  // Version gratuite : l'offre Pro, la jauge de produits, un rapport au-delà de 30 jours
  final free = {
    '56_pro_gratuit': ('/pro', null),
    '57_stock_gratuit': ('/stock', null),
    '58_rapport_bloque': ('/reports', 'history'),
  };
  for (final e in free.entries) {
    testWidgets(e.key, (tester) async {
      phoneSize(tester);
      final repo = FakeRepo()
        ..proUntil = DateTime(2026, 1, 1)
        ..extraProducts = [for (var i = 0; i < 42; i++) Product(id: 'x$i', name: 'Article $i', price: 1000, cost: 500)];
      if (e.value.$2 != null) {
        repo.reportsError = const ApiException(
          'PRO_REQUIRED',
          'Version gratuite : rapports des 30 derniers jours. Passez à Pro pour tout votre historique',
          details: {'feature': 'history'},
        );
      }
      await pumpSama(tester, location: e.value.$1, repo: repo);
      await _shot(tester, e.key);
    });
  }
  // Métiers : l'accueil d'une boutique d'habits et d'un restaurant, et l'écran des services
  final trades = {
    '59_accueil_mode': ('/', 'mode'),
    '60_accueil_restaurant': ('/', 'restaurant'),
    '61_services': ('/business/services', 'mode'),
  };
  for (final e in trades.entries) {
    testWidgets(e.key, (tester) async {
      phoneSize(tester);
      await pumpSama(tester, location: e.value.$1, repo: FakeRepo()..businessCategory = e.value.$2);
      if (e.value.$1 == '/') {
        await tester.ensureVisible(find.byIcon(Icons.apps_rounded));
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.apps_rounded));
        await tester.pumpAndSettle();
      }
      await _shot(tester, e.key);
    });
  }
  // Suggestions : l'écran du commerçant, et ce que l'équipe reçoit (avec le suivi par semaine)
  testWidgets('65_nom', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, auth: _NoNameAuth.new);
    await _shot(tester, '65_nom');
  });
  // Retouches du test : création d'entreprise, « Plus », conditions
  testWidgets('69_variantes_parfum', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/products/p1/variants', repo: FakeRepo()..businessCategory = 'cosmetique');
    await _shot(tester, '69_variantes_parfum');
  });
  testWidgets('70_unites', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/products/new', repo: FakeRepo()..businessCategory = 'quincaillerie');
    await tester.tap(find.byKey(const Key('pMore')));
    await tester.pumpAndSettle();
    final unit = find.text('Vendu par');
    await tester.scrollUntilVisible(unit, 200, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.ancestor(of: unit, matching: find.byType(InputDecorator)),
        matching: find.byType(DropdownButton<String>),
      ),
    );
    await tester.pumpAndSettle();
    await _shot(tester, '70_unites');
  });
  testWidgets('71_photos', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo();
    await pumpSama(tester, location: '/products/new', repo: repo);
    await tester.enterText(find.byKey(const Key('pName')), 'Eau de parfum Oud');
    await tester.pumpAndSettle();
    await _shot(tester, '71_photos');
  });
  testWidgets('66_creation', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/business');
    await tester.tap(find.text('Créer une entreprise'));
    await tester.pumpAndSettle();
    await _shot(tester, '66_creation');
  });
  testWidgets('67_plus', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, repo: FakeRepo()..businessCategory = 'cosmetique');
    await tester.ensureVisible(find.byIcon(Icons.apps_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.apps_rounded));
    await tester.pumpAndSettle();
    await tester.drag(find.text('Tous les services'), const Offset(0, -900));
    await tester.pumpAndSettle();
    await _shot(tester, '67_plus');
  });
  testWidgets('68_conditions', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/account');
    await tester.scrollUntilVisible(find.byKey(const Key('legal_row')), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(const Key('legal_row')));
    await tester.pumpAndSettle();
    await _shot(tester, '68_conditions');
  });
  testWidgets('62_suggestions', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/feedback');
    await tester.enterText(
      find.byKey(const Key('fb_message')),
      'Pouvoir envoyer le reçu par SMS aux clients sans WhatsApp',
    );
    await tester.pumpAndSettle();
    await _shot(tester, '62_suggestions');
  });
  for (final name in ['63_admin_suggestions', '64_admin_semaines']) {
    testWidgets(name, (tester) async {
      phoneSize(tester);
      final repo = adminRepo()
        ..feedbackInbox.addAll([
          AdminFeedback(
            id: 'f1',
            kind: FeedbackKind.idea,
            message: 'Ajoutez le wolof, mes vendeuses lisent mal le français.',
            status: FeedbackStatus.fresh,
            createdAt: DateTime(2026, 11, 25, 10, 30),
            userPhone: '+221770000001',
            userName: 'Awa Ndiaye',
            businessId: 'b1',
            businessName: 'Awa Beauté',
            category: 'cosmetique',
            appVersion: '1.0.0',
          ),
          AdminFeedback(
            id: 'f2',
            kind: FeedbackKind.problem,
            message: 'Le reçu ne s’imprime pas sur mon imprimante Bluetooth.',
            status: FeedbackStatus.fresh,
            createdAt: DateTime(2026, 11, 24, 18, 5),
            userPhone: '+221770000002',
            businessName: 'Quincaillerie Touba',
            category: 'quincaillerie',
          ),
        ]);
      await pumpAdmin(tester, repo: repo, location: name.contains('suggestions') ? '/admin/feedback' : '/admin');
      if (name.contains('semaines')) {
        await tester.scrollUntilVisible(
          find.byKey(const Key('admin_weeks')),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
      }
      await _shot(tester, name);
    });
  }
  for (final e in routes.entries) {
    testWidgets(e.key, (tester) async {
      phoneSize(tester);
      await pumpSama(tester, location: e.value);
      await _shot(tester, e.key);
    });
  }
}

class _NoNameAuth extends AuthController {
  @override
  Future<AuthState> build() async => const AuthState(
    me: Me(id: 'u1', phone: '+221771234567', fullName: null, createdAt: null, businesses: []),
  );
}
