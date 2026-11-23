import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/models.dart';
import 'package:sama360/core/repositories.dart';
import 'package:sama360/features/catalog/product_photo.dart';
import 'package:sama360/features/invoicing/invoice_pdf.dart';
import 'package:sama360/features/sales/receipt.dart';

import 'helpers.dart';

DocDetail sampleInvoice({String status = 'partial', int paid = 30000}) => DocDetail(
  id: 'f1',
  kind: DocKind.invoice,
  number: 'FAC-2026-0001',
  status: status,
  customer: const Contact(
    id: 'c1',
    name: 'Hôtel Teranga',
    phone: '+221338200000',
    address: 'Route de la Corniche, Dakar',
  ),
  issueDate: DateTime(2026, 11, 16),
  dueDate: DateTime(2026, 12, 1),
  subtotal: 80000,
  discount: 5000,
  total: 75000,
  paid: paid,
  due: 75000 - paid,
  note: 'Livraison sous 72 h',
  related: (id: 'q1', number: 'DEV-2026-0001'),
  lines: const [
    DocLine(name: 'Nappe brodée', quantity: 4, unitPrice: 15000, total: 60000),
    DocLine(name: 'Livraison et pose', description: 'Plateau', quantity: 1, unitPrice: 20000, total: 20000),
  ],
  payments: [DocPayment(method: PayMethod.wave, amount: paid, reference: 'WV-123', paidAt: DateTime(2026, 11, 18))],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await initializeDateFormatting('fr');
    await loadTestFonts();
  });

  group('documents', () {
    test('texte WhatsApp d’une facture', () {
      final t = docText(sampleInvoice(), demoBusiness);
      expect(t, contains('Facture FAC-2026-0001 du 16 novembre 2026'));
      expect(t, contains('4 × Nappe brodée : 60 000 F'));
      expect(t, contains('*Total : 75 000 F*'));
      expect(t, contains('Déjà payé : 30 000 F'));
      expect(t, contains('*Reste à payer : 45 000 F*'));
      expect(t, contains('À payer avant le 1 décembre 2026'));
    });

    test('titres et échéances', () {
      expect(docTitle(sampleInvoice(status: 'cancelled', paid: 0)), 'FACTURE ANNULÉE');
      expect(docDueLine(sampleInvoice()), 'À payer avant le 1 décembre 2026');
      expect(docFileName(sampleInvoice()), 'Facture-FAC-2026-0001.pdf');
      expect(docStatusLabel('partial'), 'Payé en partie');
      expect(docStatusLabel('unpaid', overdue: true), 'En retard');
    });

    test('PDF A4 valide', () async {
      final bytes = await buildDocumentPdf(sampleInvoice(), demoBusiness, fonts: await ReceiptFonts.load());
      expect(ascii.decode(bytes.sublist(0, 5)), '%PDF-');
      expect(bytes.length, greaterThan(3000));
    });

    test('PDF A4 avec le logo de l’entreprise', () async {
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
      );
      final fonts = await ReceiptFonts.load();
      final without = await buildDocumentPdf(sampleInvoice(), demoBusiness, fonts: fonts);
      final withLogo = await buildDocumentPdf(sampleInvoice(), demoBusiness, fonts: fonts, logo: png);
      expect(ascii.decode(withLogo.sublist(0, 5)), '%PDF-');
      expect(latin1.decode(withLogo), contains('/Subtype/Image'));
      expect(latin1.decode(without), isNot(contains('/Subtype/Image')));
      // Une image illisible ne bloque pas le document
      final broken = await buildDocumentPdf(sampleInvoice(), demoBusiness, fonts: fonts, logo: [1, 2, 3]);
      expect(ascii.decode(broken.sublist(0, 5)), '%PDF-');
    });

    test('corps envoyé à l’API', () {
      final body = SamaRepository.documentBody(
        customerId: 'c1',
        lines: const [
          DocLineDraft(productId: 'p1', name: 'Savon', quantity: 2, unitPrice: 1500),
          DocLineDraft(name: 'Livraison', quantity: 1, unitPrice: 2000),
        ],
        discount: 500,
        issueDate: DateTime(2026, 11, 16),
        dueDate: DateTime(2026, 12, 16),
        note: '  ',
      );
      expect(body, {
        'customerId': 'c1',
        'lines': [
          {'productId': 'p1', 'name': 'Savon', 'quantity': 2.0, 'unitPrice': 1500},
          {'name': 'Livraison', 'quantity': 1.0, 'unitPrice': 2000},
        ],
        'discount': 500,
        'issueDate': '2026-11-16',
        'dueDate': '2026-12-16',
        'note': null,
      });
    });
  });

  testWidgets('devis → facture → paiement, depuis l’accueil', (tester) async {
    phoneSize(tester);
    final (_, repo) = await pumpSama(tester);

    await tester.ensureVisible(find.text('Factures'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Factures'));
    await tester.pumpAndSettle();
    expect(find.text('À encaisser sur factures'), findsOneWidget);

    await tester.tap(find.text('Nouveau'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nouveau devis'));
    await tester.pumpAndSettle();

    // Client
    await tester.tap(find.text('Choisir le client'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hôtel Teranga'));
    await tester.pumpAndSettle();

    // Un produit du catalogue, deux fois
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.text('Produit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Beurre de karité 250 g').last);
      await tester.pumpAndSettle();
    }
    expect(find.textContaining(RegExp(r'^2 × 3.500 F = 7.000 F$')), findsOneWidget);

    // Une ligne libre
    await tester.tap(find.text('Ligne libre'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('lineName')), 'Livraison');
    await tester.enterText(find.byKey(const Key('linePrice')), '2000');
    await tester.tap(find.text('Valider la ligne'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('docDiscount')), '1000');
    await tester.pump();
    expect(find.textContaining(RegExp(r'^8.000 F$')), findsOneWidget);

    await tester.tap(find.text('Créer le devis'));
    await tester.pumpAndSettle();
    final body = repo.docBodies.values.single;
    expect(body['discount'], 1000);
    expect((body['lines'] as List).length, 2);
    expect(body['dueDate'], isNotNull); // validité 30 jours par défaut
    expect(find.textContaining('DEV-'), findsWidgets);
    expect(find.text('En attente'), findsOneWidget);

    // Devis → facture
    await tester.tap(find.text('Transformer en facture'));
    await tester.pumpAndSettle();
    expect(find.textContaining('FAC-'), findsWidgets);
    expect(find.text('FACTURE'), findsOneWidget);

    // Paiement partiel
    await tester.tap(find.text('Enregistrer un paiement'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('payAmount')), '3000');
    await tester.tap(find.text('Wave'));
    await tester.pump();
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();
    expect(find.text('Payé en partie'), findsOneWidget);
    expect(find.text('Reste à payer'), findsOneWidget);
  });

  testWidgets('annuler une facture sans paiement', (tester) async {
    phoneSize(tester);
    final (c, repo) = await pumpSama(tester);
    await repo.createDocument(
      id: 'f9',
      kind: DocKind.invoice,
      body: {
        'customerId': 'c1',
        'lines': [
          {'name': 'Couture', 'quantity': 1, 'unitPrice': 12000},
        ],
        'discount': 0,
      },
    );
    routerOf(c).push('/invoices/f9');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Annuler la facture'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('cancelReason')), 'Erreur de client');
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Oui, annuler')));
    await tester.pumpAndSettle();
    expect(repo.docs['f9']!.status, 'cancelled');
    expect(find.text('Annulée'), findsOneWidget);
  });

  testWidgets('logo : ajouté depuis le profil, proposé sur les factures', (tester) async {
    phoneSize(tester);
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
    );
    final (_, repo) = await pumpSama(
      tester,
      location: '/invoices',
      overrides: [photoPickerProvider.overrideWithValue((_) async => PickedPhoto(png, 'logo.png'))],
    );
    expect(find.text('Ajoutez votre logo'), findsOneWidget);
    await tester.tap(find.text('Ajoutez votre logo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choisir dans la galerie'));
    await tester.pumpAndSettle();
    expect(repo.logoFileId, 'logo-1');
    expect(find.text('Logo enregistré'), findsOneWidget);
    expect(find.text('Ajoutez votre logo'), findsNothing);
  });
}
