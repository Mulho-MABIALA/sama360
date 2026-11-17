import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/pdf_brand.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../sales/receipt.dart' show ReceiptFonts, receiptMoney;

String purchaseFileName(PurchaseDetail d) => 'Bon-de-commande-${d.number}.pdf';

/// Bon de commande en texte, à envoyer au fournisseur par WhatsApp.
String purchaseText(PurchaseDetail d, CurrentBusiness b) {
  final day = DateFormat('d MMMM yyyy', 'fr');
  return [
    'Bonjour ${d.supplier.name},',
    'Voici notre commande ${d.number} (${b.name}) :',
    for (final l in d.lines) '• ${qty(l.quantity)} ${l.unit == 'pièce' ? '×' : l.unit} ${l.name}',
    if (d.summary.expectedDate != null) 'Livraison souhaitée le ${day.format(d.summary.expectedDate!)}.',
    if ((d.note ?? '').isNotEmpty) d.note!,
    'Merci de nous confirmer la disponibilité et le prix.',
  ].join('\n');
}

/// Bon de commande A4 : lignes, quantités, prix d'achat convenus et total.
Future<List<int>> buildPurchasePdf(PurchaseDetail d, CurrentBusiness b, {ReceiptFonts? fonts, List<int>? logo}) async {
  final f = fonts ?? await ReceiptFonts.load();
  final brandColors = pdfBrandColors(b);
  final green = brandColors.brand;
  const ink = PdfColor.fromInt(0xFF13241C);
  const muted = PdfColor.fromInt(0xFF5E6E66);
  final soft = brandColors.soft;
  final base = pw.TextStyle(font: f.regular, fontSize: 9.5, color: ink);
  final bold = pw.TextStyle(font: f.bold, fontSize: 9.5, color: ink);
  final small = base.copyWith(fontSize: 8.5, color: muted);
  final day = DateFormat('d MMMM yyyy', 'fr');

  pw.ImageProvider? logoImage;
  if (logo != null && logo.isNotEmpty) {
    try {
      logoImage = pw.MemoryImage(Uint8List.fromList(logo));
    } catch (_) {
      logoImage = null;
    }
  }

  final doc = pw.Document(title: 'Bon de commande ${d.number}', author: b.name, creator: 'Sama360');
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4.copyWith(marginLeft: 40, marginRight: 40, marginTop: 40, marginBottom: 40),
      theme: pw.ThemeData.withFont(base: f.regular, bold: f.bold),
      footer: (ctx) => pw.Row(
        children: [
          pw.Expanded(child: pw.Text('${b.name} · ${d.number}', style: small)),
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
                  if (b.phone != null) pw.Text(b.phone!, style: small),
                  if (b.address != null) pw.Text(b.address!, style: small),
                  if (b.ninea != null) pw.Text('${b.country.taxIdLabel} ${b.ninea}', style: small),
                ],
              ),
            ),
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: [
                pw.Text('BON DE COMMANDE', style: bold.copyWith(fontSize: 13)),
                pw.Text(d.number, style: bold),
                pw.Text('Du ${day.format(d.summary.orderDate)}', style: small),
                if (d.summary.expectedDate != null)
                  pw.Text('Livraison souhaitée le ${day.format(d.summary.expectedDate!)}', style: small),
              ],
            ),
          ],
        ),
        pw.SizedBox(height: 18),
        pw.Container(
          width: double.infinity,
          padding: const pw.EdgeInsets.all(10),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: const PdfColor.fromInt(0xFFE3EBE6)),
            borderRadius: pw.BorderRadius.circular(6),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('Fournisseur', style: small),
              pw.Text(d.supplier.name, style: bold.copyWith(fontSize: 11)),
              if (d.supplier.phone != null) pw.Text(displayPhone(d.supplier.phone!), style: base),
            ],
          ),
        ),
        pw.SizedBox(height: 16),
        pw.TableHelper.fromTextArray(
          border: null,
          headers: ['Désignation', 'Quantité', 'Prix unitaire', 'Montant'],
          data: [
            for (final l in d.lines)
              [
                l.name,
                '${qty(l.quantity)}${l.unit == 'pièce' ? '' : ' ${l.unit}'}',
                receiptMoney(l.unitCost),
                receiptMoney(l.total),
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
            0: const pw.FlexColumnWidth(),
            1: const pw.FixedColumnWidth(70),
            2: const pw.FixedColumnWidth(85),
            3: const pw.FixedColumnWidth(90),
          },
          cellAlignments: {1: pw.Alignment.centerRight, 2: pw.Alignment.centerRight, 3: pw.Alignment.centerRight},
          headerAlignments: {1: pw.Alignment.centerRight, 2: pw.Alignment.centerRight, 3: pw.Alignment.centerRight},
        ),
        pw.SizedBox(height: 10),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.end,
          children: [
            pw.Container(
              padding: const pw.EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: pw.BoxDecoration(color: soft, borderRadius: pw.BorderRadius.circular(6)),
              child: pw.Row(
                children: [
                  pw.Text('Total commandé   ', style: base),
                  pw.Text(receiptMoney(d.summary.total), style: bold.copyWith(fontSize: 13, color: green)),
                ],
              ),
            ),
          ],
        ),
        if ((d.note ?? '').isNotEmpty) ...[
          pw.SizedBox(height: 16),
          pw.Text('Note', style: small),
          pw.Text(d.note!, style: base),
        ],
        pw.SizedBox(height: 18),
        pw.Text('Merci de confirmer la disponibilité, le prix et la date de livraison.', style: base),
      ],
    ),
  );
  return doc.save();
}
