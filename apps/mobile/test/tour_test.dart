@Tags(['screenshots'])
library;

/// Tour complet de l'app : une capture par écran (390 × 844) pour relecture.
/// SAMA_SCREENSHOTS=1 flutter test test/tour_test.dart --update-goldens
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sama360/core/api/api_client.dart';
import 'package:sama360/core/models.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_ui/material_ui.dart';

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
  for (final e in routes.entries) {
    testWidgets(e.key, (tester) async {
      phoneSize(tester);
      await pumpSama(tester, location: e.value);
      await _shot(tester, e.key);
    });
  }
}
