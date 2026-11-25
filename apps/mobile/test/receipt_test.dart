import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show Key;
import 'package:pdf/pdf.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:sama360/core/models.dart';
import 'package:sama360/features/sales/receipt.dart';
import 'package:sama360/features/sales/receipt_screen.dart';

import 'helpers.dart';

class RecordingActions extends ReceiptActions {
  Uri? whatsApp;
  List<int>? shared;
  String? sharedName;
  List<int>? printed;

  @override
  Future<bool> openWhatsApp(Uri uri) async {
    whatsApp = uri;
    return true;
  }

  @override
  Future<void> sharePdf(List<int> bytes, String filename) async {
    shared = bytes;
    sharedName = filename;
  }

  @override
  Future<void> printPdf(List<int> bytes, String name, {PdfPageFormat format = PdfPageFormat.roll80}) async =>
      printed = bytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await initializeDateFormatting('fr');
    await loadTestFonts();
  });

  group('reçu', () {
    test('texte WhatsApp complet', () {
      final t = receiptText(demoSale, demoBusiness);
      expect(t, contains('*Awa Beauté*'));
      expect(t, contains('Reçu VEN-2026-0042'));
      expect(t, contains('2 × Beurre de karité 250 g : 7 000 F'));
      expect(t, contains('Réduction : -500 F'));
      expect(t, contains('*Total : 9 000 F*'));
      expect(t, contains('Payé (Wave) : 5 000 F'));
      expect(t, contains('*Reste à payer : 4 000 F*'));
      expect(t, isNot(contains(' ')));
    });

    test('vente annulée signalée', () {
      expect(receiptText(demoVoidedSale, demoBusiness), contains('VENTE ANNULÉE'));
    });

    test('lien WhatsApp vers le client', () {
      final u = whatsAppUri('Bonjour é', phone: '+221 76 555 12 34');
      expect(u.toString(), startsWith('https://wa.me/221765551234?text='));
      expect(Uri.decodeComponent(u.query.substring(5)), 'Bonjour é');
      expect(whatsAppUri('x').toString(), 'https://wa.me/?text=x');
    });

    test('PDF ticket valide', () async {
      final bytes = await buildReceiptPdf(demoSale, demoBusiness, fonts: await ReceiptFonts.load());
      expect(ascii.decode(bytes.sublist(0, 5)), '%PDF-');
      expect(bytes.length, greaterThan(2000));
      expect(receiptFileName(demoSale), 'Recu-VEN-2026-0042.pdf');
    });

    test('PDF ticket avec logo (et sans si l’image est illisible)', () async {
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
      );
      final fonts = await ReceiptFonts.load();
      final withLogo = await buildReceiptPdf(demoSale, demoBusiness, fonts: fonts, logo: png);
      expect(latin1.decode(withLogo), contains('/Subtype/Image'));
      final broken = await buildReceiptPdf(demoSale, demoBusiness, fonts: fonts, logo: [1, 2, 3]);
      expect(ascii.decode(broken.sublist(0, 5)), '%PDF-');
      expect(latin1.decode(broken), isNot(contains('/Subtype/Image')));
    });

    test('modèle depuis l’API', () {
      final s = SaleDetail.fromJson({
        'id': 'x',
        'number': 'VEN-2026-0001',
        'status': 'completed',
        'soldAt': '2026-11-16T09:00:00Z',
        'subtotal': 1000,
        'discount': 0,
        'total': 1000,
        'paid': 600,
        'due': 400,
        'items': [
          {'name': 'Savon', 'quantity': '1.500', 'unitPrice': 1000, 'discount': 0, 'total': 1000},
        ],
        'payments': [
          {'method': 'orange_money', 'amount': 600},
        ],
        'customer': {'id': 'c', 'name': 'Fatou', 'phone': '+221770000000'},
        'cashierName': 'Awa',
      });
      expect(s.lines.single.quantity, 1.5);
      expect(s.payments.single.amount, 600);
      expect(s.customer!.name, 'Fatou');
      expect(
        SaleSummary.fromJson({
          'id': 'x',
          'number': 'n',
          'total': 900,
          'paid': 500,
          'soldAt': '2026-11-16T09:00:00Z',
        }).due,
        400,
      );
    });
  });

  testWidgets('écran reçu : PDF en premier, message au client s’il a un numéro, impression', (tester) async {
    final actions = RecordingActions();
    await pumpSama(tester, location: '/sales/s2', overrides: [receiptActionsProvider.overrideWithValue(actions)]);

    expect(find.text('REÇU VEN-2026-0042'), findsOneWidget);
    expect(find.text('Aminata Ba'), findsOneWidget);
    expect(find.text('Reste à payer'), findsOneWidget);

    await tester.tap(find.text('Message au client'));
    await tester.pumpAndSettle();
    expect(actions.whatsApp!.path, '/221765551234');

    await tester.runAsync(() async {
      await tester.tap(find.text('Envoyer le reçu (PDF)'));
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await tester.pumpAndSettle();
    expect(actions.sharedName, 'Recu-VEN-2026-0042.pdf');

    await tester.runAsync(() async {
      await tester.tap(find.text('Imprimer'));
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await tester.pumpAndSettle();
    expect(actions.printed, isNotNull);
  });

  testWidgets('vente annulée : tampon visible', (tester) async {
    await pumpSama(tester, location: '/sales/voided');
    expect(find.text('VENTE ANNULÉE'), findsOneWidget);
    // Sans client connu : le PDF, pas de message direct
    expect(find.text('Envoyer le reçu (PDF)'), findsOneWidget);
    expect(find.text('Message au client'), findsNothing);
  });

  testWidgets('recherche d’un reçu par son numéro', (tester) async {
    await pumpSama(tester, location: '/sales');
    await tester.enterText(find.byKey(const Key('sale_search')), '42');
    await tester.pumpAndSettle();
    expect(find.text('Aminata Ba'), findsOneWidget);
    expect(find.text('Beurre de karité 250 g + 2 autres'), findsNothing);
    await tester.enterText(find.byKey(const Key('sale_search')), '999');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sale_search_empty')), findsOneWidget);
  });

  testWidgets('historique : ouvre le reçu', (tester) async {
    await pumpSama(tester, location: '/sales');
    // Titrée par le client, sinon par ce qui a été vendu ; le numéro en petit dessous
    expect(find.text('Aminata Ba'), findsOneWidget);
    expect(find.text('Beurre de karité 250 g + 2 autres'), findsOneWidget);
    expect(find.text('VEN-2026-0041'), findsOneWidget); // sans articles connus : le numéro
    expect(find.textContaining('VEN-2026-0042'), findsOneWidget);
    expect(find.textContaining('Crédit 4'), findsOneWidget);
    expect(find.text('2'), findsOneWidget); // ventes non annulées
    await tester.tap(find.text('Aminata Ba'));
    await tester.pumpAndSettle();
    expect(find.text('REÇU VEN-2026-0042'), findsOneWidget);
  });

  testWidgets('après encaissement : bouton « Voir le reçu »', (tester) async {
    await pumpSama(tester, location: '/pos');
    expect(find.byTooltip("Ventes d'aujourd'hui"), findsOneWidget);
  });
}
