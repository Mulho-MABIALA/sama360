import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/models.dart';
import '../sales/receipt.dart' show ReceiptFonts, receiptDate, receiptMoney;

String cashFileName(CashSession s) => 'Rapport-${s.number}.pdf';

/// Rapport Z sur rouleau 80 mm : attendu, compté et écart par moyen de paiement.
Future<List<int>> buildCashZPdf(CashSession s, CurrentBusiness b, {ReceiptFonts? fonts}) async {
  final f = fonts ?? await ReceiptFonts.load();
  final base = pw.TextStyle(font: f.regular, fontSize: 8.5);
  final bold = pw.TextStyle(font: f.bold, fontSize: 8.5);
  pw.Widget row(String left, String right, {pw.TextStyle? style}) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 1.2),
    child: pw.Row(
      children: [
        pw.Expanded(child: pw.Text(left, style: style ?? base)),
        pw.Text(right, style: style ?? base),
      ],
    ),
  );
  pw.Widget dash() => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 5),
    child: pw.Container(
      height: 1,
      decoration: const pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(width: 0.6, style: pw.BorderStyle.dashed)),
      ),
    ),
  );
  String signed(int v) => v == 0 ? '0 F' : '${v > 0 ? '+' : '-'}${receiptMoney(v.abs())}';
  final r = s.report;
  final doc = pw.Document(title: 'Rapport ${s.number}', author: b.name, creator: 'Sama360');
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
          dash(),
          pw.Text(
            s.open ? 'ÉTAT DE CAISSE ${s.number}' : 'RAPPORT Z ${s.number}',
            textAlign: pw.TextAlign.center,
            style: bold.copyWith(fontSize: 10),
          ),
          pw.SizedBox(height: 4),
          if (s.userName != null) row('Vendeur', s.userName!),
          row('Ouverture', receiptDate(s.openedAt)),
          if (s.closedAt != null) row('Clôture', receiptDate(s.closedAt!)),
          if (s.closedByName != null && s.closedByName != s.userName) row('Clôturée par', s.closedByName!),
          dash(),
          row('Ventes', '${r.salesCount}'),
          row('Chiffre d’affaires', receiptMoney(r.salesTotal), style: bold),
          if (r.creditTotal > 0) row('Dont à crédit', receiptMoney(r.creditTotal)),
          if (r.discountTotal > 0) row('Remises', receiptMoney(r.discountTotal)),
          if (r.voidedCount > 0) row('Annulées (${r.voidedCount})', receiptMoney(r.voidedTotal)),
          for (final m in r.methods) ...[
            dash(),
            pw.Text(m.method.label.toUpperCase(), style: bold),
            for (final (label, amount) in m.breakdown) row('  $label', signed(amount)),
            row('Attendu', receiptMoney(m.expected), style: bold),
            if (s.lines != null)
              for (final l in s.lines!.where((l) => l.method == m.method)) ...[
                row('Compté', receiptMoney(l.counted)),
                row('Écart', signed(l.difference), style: bold),
              ],
          ],
          if (s.movements.isNotEmpty) ...[
            dash(),
            pw.Text('ENTRÉES ET SORTIES', style: bold),
            for (final mv in s.movements) row(mv.reason, '${mv.isIn ? '+' : '-'}${receiptMoney(mv.amount)}'),
          ],
          if (s.difference != null) ...[
            dash(),
            row('ÉCART TOTAL', signed(s.difference!), style: bold.copyWith(fontSize: 10)),
          ],
          if ((s.closingNote ?? '').isNotEmpty) ...[pw.SizedBox(height: 4), pw.Text(s.closingNote!, style: base)],
          dash(),
          pw.SizedBox(height: 14),
          row('Signature vendeur', '________________'),
          pw.SizedBox(height: 10),
          row('Signature gérant', '________________'),
          pw.SizedBox(height: 8),
          pw.Text('Sama360', textAlign: pw.TextAlign.center, style: base.copyWith(fontSize: 7)),
        ],
      ),
    ),
  );
  return doc.save();
}
