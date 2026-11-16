import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/format.dart';
import '../../core/models.dart';

/// Montant pour le reçu, avec espaces simples (certaines imprimantes et polices
/// n'affichent pas l'espace fine insécable du format français).
String receiptMoney(num amount) => moneyShort(amount).replaceAll(' ', ' ').replaceAll(' ', ' ');

String receiptDate(DateTime d) => DateFormat('dd/MM/yyyy HH:mm', 'fr').format(d.toLocal());

String paymentLabel(PayMethod? m) => m?.label ?? 'Autre';

/// Ligne « 2 × 3 500 F » (ou « 1,5 × … »).
String lineDetail(ReceiptLine l) => '${qty(l.quantity)} × ${receiptMoney(l.unitPrice)}';

/// Reçu en texte, pour WhatsApp (*gras* compris par WhatsApp).
String receiptText(SaleDetail s, CurrentBusiness b) {
  final out = StringBuffer()
    ..writeln('*${b.name}*')
    ..writeln('Reçu ${s.number} - ${receiptDate(s.soldAt)}');
  if (s.voided) out.writeln('*VENTE ANNULÉE*');
  out.writeln();
  for (final l in s.lines) {
    out.writeln('${qty(l.quantity)} × ${l.name} : ${receiptMoney(l.total)}');
  }
  out.writeln();
  if (s.discount > 0) out.writeln('Remise : -${receiptMoney(s.discount)}');
  out.writeln('*Total : ${receiptMoney(s.total)}*');
  for (final p in s.payments) {
    out.writeln('Payé (${paymentLabel(p.method)}) : ${receiptMoney(p.amount)}');
  }
  if (s.due > 0) out.writeln('*Reste à payer : ${receiptMoney(s.due)}*');
  out
    ..writeln()
    ..write('Merci de votre confiance !');
  return out.toString();
}

/// Polices du PDF, chargées une fois depuis les assets de l'app.
class ReceiptFonts {
  ReceiptFonts(this.regular, this.bold);
  final pw.Font regular;
  final pw.Font bold;

  static ReceiptFonts? _cache;
  static Future<ReceiptFonts> load() async => _cache ??= ReceiptFonts(
    pw.Font.ttf(await rootBundle.load('assets/fonts/Roboto-Regular.ttf')),
    pw.Font.ttf(await rootBundle.load('assets/fonts/Roboto-Bold.ttf')),
  );
}

/// Reçu PDF au format ticket de caisse (rouleau 80 mm) : imprimable et partageable.
Future<List<int>> buildReceiptPdf(SaleDetail s, CurrentBusiness b, {ReceiptFonts? fonts}) async {
  final f = fonts ?? await ReceiptFonts.load();
  final doc = pw.Document(title: 'Reçu ${s.number}', author: b.name, creator: 'Sama360');
  final base = pw.TextStyle(font: f.regular, fontSize: 8.5);
  final bold = pw.TextStyle(font: f.bold, fontSize: 8.5);
  pw.Widget row(String left, String right, {pw.TextStyle? style}) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 1.2),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(child: pw.Text(left, style: style ?? base)),
        pw.SizedBox(width: 6),
        pw.Text(right, style: style ?? base),
      ],
    ),
  );
  // Nouvelle instance à chaque usage : un widget pdf garde son état de mise en page.
  pw.Widget dash() => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 5),
    child: pw.Container(
      height: 1,
      decoration: const pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(width: 0.6, style: pw.BorderStyle.dashed)),
      ),
    ),
  );

  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.roll80.copyWith(marginLeft: 12, marginRight: 12, marginTop: 14, marginBottom: 14),
      build: (_) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Text(
            b.name,
            textAlign: pw.TextAlign.center,
            style: pw.TextStyle(font: f.bold, fontSize: 13),
          ),
          for (final line in [
            [b.address, b.city].whereType<String>().where((x) => x.isNotEmpty).join(', '),
            if (b.phone != null) 'Tél. ${b.phone}',
            if (b.ninea != null) 'NINEA ${b.ninea}',
          ].where((x) => x.isNotEmpty))
            pw.Text(line, textAlign: pw.TextAlign.center, style: base.copyWith(fontSize: 7.5)),
          dash(),
          pw.Text('REÇU ${s.number}', textAlign: pw.TextAlign.center, style: bold.copyWith(fontSize: 10)),
          pw.Text(receiptDate(s.soldAt), textAlign: pw.TextAlign.center, style: base),
          if (s.voided)
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 4),
              child: pw.Text('VENTE ANNULÉE', textAlign: pw.TextAlign.center, style: bold.copyWith(fontSize: 11)),
            ),
          pw.SizedBox(height: 4),
          if (s.cashierName != null) row('Vendeur', s.cashierName!),
          if (s.customer != null) row('Client', s.customer!.name),
          dash(),
          for (final l in s.lines) ...[
            pw.Text(l.name, style: bold),
            row(lineDetail(l), receiptMoney(l.total)),
            if (l.discount > 0) row('  Remise', '-${receiptMoney(l.discount)}'),
          ],
          dash(),
          if (s.discount > 0) ...[
            row('Sous-total', receiptMoney(s.subtotal)),
            row('Remise', '-${receiptMoney(s.discount)}'),
          ],
          row('TOTAL', receiptMoney(s.total), style: bold.copyWith(fontSize: 11)),
          pw.SizedBox(height: 3),
          for (final p in s.payments) row('Payé (${paymentLabel(p.method)})', receiptMoney(p.amount)),
          if (s.due > 0) row('Reste à payer', receiptMoney(s.due), style: bold),
          dash(),
          pw.Text('Merci de votre confiance !', textAlign: pw.TextAlign.center, style: bold),
          pw.SizedBox(height: 2),
          pw.Text('Reçu émis avec Sama360', textAlign: pw.TextAlign.center, style: base.copyWith(fontSize: 6.5)),
        ],
      ),
    ),
  );
  return doc.save();
}

/// Nom de fichier du PDF : « Recu-VEN-2026-0004.pdf ».
String receiptFileName(SaleDetail s) => 'Recu-${s.number}.pdf';
