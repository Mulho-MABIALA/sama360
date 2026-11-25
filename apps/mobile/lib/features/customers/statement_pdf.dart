import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/pdf_brand.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../sales/receipt.dart' show ReceiptFonts, receiptMoney;

String statementFileName(CustomerOverview o, [DateTime? now]) {
  final slug = o.customer.name.trim().replaceAll(RegExp(r'[^A-Za-z0-9À-ÿ]+'), '-').replaceAll(RegExp(r'^-|-$'), '');
  return 'Releve-$slug-${DateFormat('yyyy-MM-dd').format(now ?? DateTime.now())}.pdf';
}

/// Relevé de compte A4 : tous les mouvements du carnet de crédit avec le solde après chacun.
Future<List<int>> buildStatementPdf(
  CustomerOverview o,
  CurrentBusiness b, {
  ReceiptFonts? fonts,
  List<int>? logo,
  DateTime? now,
}) async {
  final f = fonts ?? await ReceiptFonts.load();
  final brandColors = pdfBrandColors(b);
  final green = brandColors.brand;
  const ink = PdfColor.fromInt(0xFF13241C);
  const muted = PdfColor.fromInt(0xFF5E6E66);
  final soft = brandColors.soft;
  const warn = PdfColor.fromInt(0xFFB25E00);
  final base = pw.TextStyle(font: f.regular, fontSize: 9.5, color: ink);
  final bold = pw.TextStyle(font: f.bold, fontSize: 9.5, color: ink);
  final small = base.copyWith(fontSize: 8.5, color: muted);
  final day = DateFormat('d MMM yyyy', 'fr');
  final today = now ?? DateTime.now();

  pw.ImageProvider? logoImage;
  if (logo != null && logo.isNotEmpty) {
    try {
      logoImage = pw.MemoryImage(Uint8List.fromList(logo));
    } catch (_) {
      logoImage = null;
    }
  }

  final c = o.customer;
  // Du plus ancien au plus récent, comme un relevé bancaire
  final entries = o.entries.reversed.toList();
  final debit = entries.where((e) => e.amount > 0).fold(0, (s, e) => s + e.amount);
  final credit = entries.where((e) => e.amount < 0).fold(0, (s, e) => s - e.amount);

  final doc = pw.Document(title: 'Relevé de compte ${c.name}', author: b.name, creator: 'Sama360');
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4.copyWith(marginLeft: 40, marginRight: 40, marginTop: 40, marginBottom: 40),
      theme: pw.ThemeData.withFont(base: f.regular, bold: f.bold),
      footer: (ctx) => pw.Row(
        children: [
          pw.Expanded(child: pw.Text('${b.name} · Relevé de ${c.name}', style: small)),
          pw.Text('Page ${ctx.pageNumber}/${ctx.pagesCount} · Sama360', style: small),
        ],
      ),
      build: (ctx) => [
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            if (logoImage != null)
              pw.Container(
                width: 52,
                height: 52,
                margin: const pw.EdgeInsets.only(right: 12),
                child: pw.Image(logoImage, fit: pw.BoxFit.contain),
              ),
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(b.name, style: bold.copyWith(fontSize: 16, color: green)),
                  if (b.phone != null) pw.Text(displayPhone(b.phone!), style: small),
                  if (b.address != null) pw.Text(b.address!, style: small),
                ],
              ),
            ),
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: [
                pw.Text('RELEVÉ DE COMPTE', style: bold.copyWith(fontSize: 13)),
                pw.Text('Au ${day.format(today)}', style: small),
              ],
            ),
          ],
        ),
        pw.SizedBox(height: 18),
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              child: pw.Container(
                padding: const pw.EdgeInsets.all(10),
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: const PdfColor.fromInt(0xFFE3EBE6)),
                  borderRadius: pw.BorderRadius.circular(6),
                ),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text('Client', style: small),
                    pw.Text(c.name, style: bold.copyWith(fontSize: 11)),
                    if (c.phone != null) pw.Text(displayPhone(c.phone!), style: base),
                    if (c.address != null) pw.Text(c.address!, style: base),
                  ],
                ),
              ),
            ),
            pw.SizedBox(width: 10),
            pw.Container(
              width: 190,
              padding: const pw.EdgeInsets.all(10),
              decoration: pw.BoxDecoration(color: soft, borderRadius: pw.BorderRadius.circular(6)),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(o.balance >= 0 ? 'Reste à payer' : 'Avoir du client', style: small),
                  pw.Text(
                    receiptMoney(o.balance.abs()),
                    style: bold.copyWith(fontSize: 16, color: o.balance > 0 ? warn : green),
                  ),
                  if (o.oldestUnpaidAt != null)
                    pw.Text('Dette la plus ancienne : ${day.format(o.oldestUnpaidAt!.toLocal())}', style: small),
                  if (c.creditLimit != null) pw.Text('Crédit maximum : ${receiptMoney(c.creditLimit!)}', style: small),
                ],
              ),
            ),
          ],
        ),
        pw.SizedBox(height: 16),
        if (entries.isEmpty)
          pw.Text('Aucun mouvement au carnet de crédit.', style: small)
        else
          pw.TableHelper.fromTextArray(
            border: null,
            headers: ['Date', 'Libellé', 'Dette', 'Paiement', 'Solde'],
            data: [
              for (final e in entries)
                [
                  day.format(e.at.toLocal()),
                  e.label,
                  e.amount > 0 ? receiptMoney(e.amount) : '',
                  e.amount < 0 ? receiptMoney(-e.amount) : '',
                  e.balanceAfter == null ? '' : receiptMoney(e.balanceAfter!),
                ],
            ],
            headerStyle: bold.copyWith(color: PdfColors.white, fontSize: 9),
            headerDecoration: pw.BoxDecoration(color: green),
            cellStyle: base,
            cellPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
            rowDecoration: const pw.BoxDecoration(
              border: pw.Border(bottom: pw.BorderSide(color: PdfColor.fromInt(0xFFE3EBE6), width: 0.6)),
            ),
            columnWidths: {
              0: const pw.FixedColumnWidth(70),
              1: const pw.FlexColumnWidth(),
              2: const pw.FixedColumnWidth(72),
              3: const pw.FixedColumnWidth(72),
              4: const pw.FixedColumnWidth(78),
            },
            cellAlignments: {2: pw.Alignment.centerRight, 3: pw.Alignment.centerRight, 4: pw.Alignment.centerRight},
            headerAlignments: {2: pw.Alignment.centerRight, 3: pw.Alignment.centerRight, 4: pw.Alignment.centerRight},
          ),
        if (entries.isNotEmpty) ...[
          pw.SizedBox(height: 8),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.end,
            children: [
              pw.Text('Total dettes ${receiptMoney(debit)}   ·   Total payé ${receiptMoney(credit)}', style: small),
            ],
          ),
        ],
        pw.SizedBox(height: 18),
        pw.Text(
          o.balance > 0
              ? 'Merci de régler le solde de ${receiptMoney(o.balance)} dès que possible. Pour toute question, contactez ${b.name}.'
              : 'Votre compte est à jour. Merci de votre confiance !',
          style: base,
        ),
      ],
    ),
  );
  return doc.save();
}
