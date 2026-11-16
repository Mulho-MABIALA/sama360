import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/format.dart';
import '../../core/models.dart';
import '../sales/receipt.dart' show ReceiptFonts, receiptMoney;

final _date = DateFormat('d MMMM yyyy', 'fr');
String docDate(DateTime d) => _date.format(d);

/// Titre du document : « FACTURE », « DEVIS », « FACTURE ANNULÉE ».
String docTitle(DocDetail d) => switch ((d.kind, d.status)) {
  (DocKind.invoice, 'cancelled') => 'FACTURE ANNULÉE',
  (DocKind.invoice, _) => 'FACTURE',
  _ => 'DEVIS',
};

/// Phrase d'échéance ou de validité.
String? docDueLine(DocDetail d) {
  if (d.isQuote) return d.dueDate == null ? null : 'Valable jusqu’au ${docDate(d.dueDate!)}';
  if (d.dueDate == null) return 'Payable à réception';
  return 'À payer avant le ${docDate(d.dueDate!)}';
}

/// Texte WhatsApp d'un devis ou d'une facture.
String docText(DocDetail d, CurrentBusiness b) {
  final out = StringBuffer()
    ..writeln('*${b.name}*')
    ..writeln('${d.kind.label} ${d.number} du ${docDate(d.issueDate)}')
    ..writeln('Client : ${d.customer.name}')
    ..writeln();
  for (final l in d.lines) {
    out.writeln('${qty(l.quantity)} × ${l.name} : ${receiptMoney(l.total)}');
  }
  out.writeln();
  if (d.discount > 0) out.writeln('Remise : -${receiptMoney(d.discount)}');
  out.writeln('*Total : ${receiptMoney(d.total)}*');
  if (!d.isQuote && d.paid > 0) out.writeln('Déjà payé : ${receiptMoney(d.paid)}');
  if (!d.isQuote && d.due > 0 && !d.cancelled) out.writeln('*Reste à payer : ${receiptMoney(d.due)}*');
  final due = docDueLine(d);
  if (due != null && !d.cancelled) out.writeln(due);
  out
    ..writeln()
    ..write('Merci de votre confiance !');
  return out.toString();
}

/// « +221 33 820 00 00 » pour un numéro sénégalais, sinon tel quel.
String prettyPhone(String e164) {
  final local = displayPhone(e164);
  return local == e164 ? e164 : '+221 $local';
}

String docFileName(DocDetail d) => '${d.isQuote ? 'Devis' : 'Facture'}-${d.number}.pdf';

/// Devis / facture au format A4.
Future<List<int>> buildDocumentPdf(DocDetail d, CurrentBusiness b, {ReceiptFonts? fonts}) async {
  final f = fonts ?? await ReceiptFonts.load();
  const green = PdfColor.fromInt(0xFF097E4F);
  const ink = PdfColor.fromInt(0xFF13241C);
  const muted = PdfColor.fromInt(0xFF5E6E66);
  const soft = PdfColor.fromInt(0xFFE4F5EC);
  const line = PdfColor.fromInt(0xFFE3EBE6);
  final base = pw.TextStyle(font: f.regular, fontSize: 9.5, color: ink);
  final bold = pw.TextStyle(font: f.bold, fontSize: 9.5, color: ink);
  final small = base.copyWith(fontSize: 8.5, color: muted);

  pw.Widget totalRow(String label, String value, {bool strong = false, PdfColor? color}) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 2.5),
    child: pw.Row(
      children: [
        pw.Expanded(child: pw.Text(label, style: strong ? bold.copyWith(fontSize: 11) : base)),
        pw.Text(value, style: (strong ? bold.copyWith(fontSize: 11) : bold).copyWith(color: color)),
      ],
    ),
  );

  final businessLines = [
    [b.address, b.city].whereType<String>().where((x) => x.isNotEmpty).join(', '),
    if (b.phone != null) 'Tél. ${b.phone}',
    if (b.ninea != null) 'NINEA ${b.ninea}',
  ].where((x) => x.isNotEmpty);

  final doc = pw.Document(title: '${d.kind.label} ${d.number}', author: b.name, creator: 'Sama360');
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4.copyWith(marginLeft: 40, marginRight: 40, marginTop: 40, marginBottom: 40),
      theme: pw.ThemeData.withFont(base: f.regular, bold: f.bold),
      footer: (ctx) => pw.Row(
        children: [
          pw.Expanded(child: pw.Text('${b.name} · ${d.kind.label} ${d.number}', style: small)),
          pw.Text('Page ${ctx.pageNumber}/${ctx.pagesCount} · Émis avec Sama360', style: small),
        ],
      ),
      build: (ctx) => [
        // En-tête : entreprise à gauche, titre et numéro à droite
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(b.name, style: bold.copyWith(fontSize: 18, color: green)),
                  pw.SizedBox(height: 4),
                  for (final l in businessLines) pw.Text(l, style: small),
                ],
              ),
            ),
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: [
                pw.Text(docTitle(d), style: bold.copyWith(fontSize: 22, letterSpacing: 1)),
                pw.Text(d.number, style: bold.copyWith(fontSize: 12, color: green)),
                pw.SizedBox(height: 4),
                pw.Text('Date : ${docDate(d.issueDate)}', style: base),
                if (docDueLine(d) != null && !d.cancelled) pw.Text(docDueLine(d)!, style: base),
                if (d.related != null)
                  pw.Text('${d.isQuote ? 'Facture' : 'Devis'} : ${d.related!.number}', style: small),
              ],
            ),
          ],
        ),
        pw.SizedBox(height: 24),
        // Client
        pw.Container(
          width: double.infinity,
          padding: const pw.EdgeInsets.all(12),
          decoration: pw.BoxDecoration(color: soft, borderRadius: pw.BorderRadius.circular(8)),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(d.isQuote ? 'DEVIS POUR' : 'FACTURÉ À', style: small.copyWith(letterSpacing: 1)),
              pw.SizedBox(height: 3),
              pw.Text(d.customer.name, style: bold.copyWith(fontSize: 12)),
              if ((d.customer.address ?? '').isNotEmpty) pw.Text(d.customer.address!, style: base),
              if (d.customer.phone != null) pw.Text('Tél. ${prettyPhone(d.customer.phone!)}', style: base),
              if ((d.customer.email ?? '').isNotEmpty) pw.Text(d.customer.email!, style: base),
            ],
          ),
        ),
        pw.SizedBox(height: 18),
        // Lignes
        pw.TableHelper.fromTextArray(
          border: null,
          headers: ['Désignation', 'Qté', 'Prix unitaire', 'Montant'],
          data: [
            for (final l in d.lines)
              [
                (l.description ?? '').isEmpty ? l.name : '${l.name}\n${l.description}',
                qty(l.quantity),
                receiptMoney(l.unitPrice),
                receiptMoney(l.total),
              ],
          ],
          headerStyle: bold.copyWith(color: PdfColors.white, fontSize: 9),
          headerDecoration: const pw.BoxDecoration(color: green),
          cellStyle: base,
          cellPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          rowDecoration: const pw.BoxDecoration(
            border: pw.Border(bottom: pw.BorderSide(color: line, width: 0.6)),
          ),
          columnWidths: {
            0: const pw.FlexColumnWidth(5),
            1: const pw.FlexColumnWidth(1),
            2: const pw.FlexColumnWidth(2),
            3: const pw.FlexColumnWidth(2),
          },
          cellAlignments: {
            0: pw.Alignment.centerLeft,
            1: pw.Alignment.centerRight,
            2: pw.Alignment.centerRight,
            3: pw.Alignment.centerRight,
          },
          headerAlignments: {
            0: pw.Alignment.centerLeft,
            1: pw.Alignment.centerRight,
            2: pw.Alignment.centerRight,
            3: pw.Alignment.centerRight,
          },
        ),
        pw.SizedBox(height: 12),
        // Totaux
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              child: d.note == null
                  ? pw.SizedBox()
                  : pw.Padding(
                      padding: const pw.EdgeInsets.only(right: 24),
                      child: pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          pw.Text('Note', style: small.copyWith(letterSpacing: 1)),
                          pw.Text(d.note!, style: base),
                        ],
                      ),
                    ),
            ),
            pw.SizedBox(
              width: 220,
              child: pw.Column(
                children: [
                  if (d.discount > 0) ...[
                    totalRow('Sous-total', receiptMoney(d.subtotal)),
                    totalRow('Remise', '-${receiptMoney(d.discount)}'),
                  ],
                  pw.Divider(color: line),
                  totalRow('TOTAL', receiptMoney(d.total), strong: true),
                  if (!d.isQuote && d.paid > 0) totalRow('Déjà payé', receiptMoney(d.paid)),
                  if (!d.isQuote && !d.cancelled && d.due > 0)
                    totalRow('Reste à payer', receiptMoney(d.due), strong: true, color: green),
                  if (!d.isQuote && d.status == 'paid') totalRow('Statut', 'Payée', color: green),
                ],
              ),
            ),
          ],
        ),
        if (d.payments.isNotEmpty) ...[
          pw.SizedBox(height: 18),
          pw.Text('Paiements reçus', style: bold),
          pw.SizedBox(height: 4),
          for (final p in d.payments)
            pw.Text(
              '${docDate(p.paidAt.toLocal())} · ${p.method?.label ?? 'Autre'} · ${receiptMoney(p.amount)}'
              '${p.reference == null ? '' : ' · réf. ${p.reference}'}',
              style: base,
            ),
        ],
        if (d.cancelled && d.cancelReason != null) ...[
          pw.SizedBox(height: 18),
          pw.Text('Facture annulée : ${d.cancelReason}', style: bold.copyWith(color: PdfColors.red800)),
        ],
        pw.SizedBox(height: 28),
        pw.Text(
          d.isQuote ? 'Bon pour accord — date et signature du client :' : 'Merci de votre confiance !',
          style: d.isQuote ? base : bold,
        ),
      ],
    ),
  );
  return doc.save();
}
