import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/pdf_brand.dart';
import '../../core/models.dart';
import '../../core/format.dart';
import '../sales/receipt.dart' show ReceiptFonts, receiptMoney;

String _day(DateTime d) => DateFormat('d MMMM yyyy', 'fr').format(d);
String _period(ReportOverview r) => r.from == r.to ? _day(r.from) : 'du ${_day(r.from)} au ${_day(r.to)}';
String _iso(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

String reportFileName(ReportOverview r) =>
    r.from == r.to ? 'Rapport-${_iso(r.from)}.pdf' : 'Rapport-${_iso(r.from)}-au-${_iso(r.to)}.pdf';

/// Rapport A4 à partager (comptable, associé) ou à garder.
Future<List<int>> buildReportPdf(ReportOverview r, CurrentBusiness b, {ReceiptFonts? fonts}) async {
  final f = fonts ?? await ReceiptFonts.load();
  final brandColors = pdfBrandColors(b);
  final green = brandColors.brand;
  const ink = PdfColor.fromInt(0xFF13241C);
  const muted = PdfColor.fromInt(0xFF5E6E66);
  final soft = brandColors.soft;
  final base = pw.TextStyle(font: f.regular, fontSize: 9.5, color: ink);
  final bold = pw.TextStyle(font: f.bold, fontSize: 9.5, color: ink);
  final small = base.copyWith(fontSize: 8.5, color: muted);
  final h2 = bold.copyWith(fontSize: 12, color: green);
  String pct(double? p) => p == null ? '—' : '${p >= 0 ? '+' : ''}${p.toStringAsFixed(1).replaceAll('.', ',')} %';

  pw.Widget kpi(String label, String value, {String? hint}) => pw.Container(
    padding: const pw.EdgeInsets.all(10),
    decoration: pw.BoxDecoration(color: soft, borderRadius: pw.BorderRadius.circular(6)),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(label, style: small),
        pw.Text(value, style: bold.copyWith(fontSize: 13)),
        if (hint != null) pw.Text(hint, style: small),
      ],
    ),
  );

  pw.Widget table(List<String> headers, List<List<String>> rows) => pw.TableHelper.fromTextArray(
    border: null,
    headers: headers,
    data: rows,
    headerStyle: bold.copyWith(color: PdfColors.white, fontSize: 9),
    headerDecoration: pw.BoxDecoration(color: green),
    cellStyle: base,
    cellPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
    rowDecoration: const pw.BoxDecoration(
      border: pw.Border(bottom: pw.BorderSide(color: PdfColor.fromInt(0xFFE3EBE6), width: 0.6)),
    ),
    cellAlignments: {for (var i = 1; i < headers.length; i++) i: pw.Alignment.centerRight},
    headerAlignments: {for (var i = 1; i < headers.length; i++) i: pw.Alignment.centerRight},
  );

  final dayFmt = DateFormat(r.byMonth ? 'MMMM yyyy' : 'EEE d MMM', 'fr');
  final doc = pw.Document(title: 'Rapport ${_period(r)}', author: b.name, creator: 'Sama360');
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4.copyWith(marginLeft: 40, marginRight: 40, marginTop: 40, marginBottom: 40),
      theme: pw.ThemeData.withFont(base: f.regular, bold: f.bold),
      footer: (ctx) => pw.Row(
        children: [
          pw.Expanded(child: pw.Text('${b.name} · Rapport ${_period(r)}', style: small)),
          pw.Text('Page ${ctx.pageNumber}/${ctx.pagesCount} · Sama360', style: small),
        ],
      ),
      build: (ctx) => [
        pw.Text(b.name, style: bold.copyWith(fontSize: 18, color: green)),
        pw.Text('Rapport d’activité ${_period(r)}', style: bold.copyWith(fontSize: 13)),
        pw.Text('Comparé à la période précédente de même durée', style: small),
        pw.SizedBox(height: 16),
        pw.GridView(
          crossAxisCount: 3,
          childAspectRatio: 0.42,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
          children: [
            kpi('Chiffre d’affaires', receiptMoney(r.revenue), hint: pct(r.revenueChange)),
            kpi('Bénéfice net', receiptMoney(r.netProfit), hint: pct(r.profitChange)),
            kpi('Ventes', '${r.salesCount}', hint: pct(r.salesChange)),
            kpi(
              'Bénéfice brut',
              receiptMoney(r.grossProfit),
              hint: 'Marge ${r.marginRate.toStringAsFixed(1).replaceAll('.', ',')} %',
            ),
            kpi('Dépenses', receiptMoney(r.expenses)),
            kpi('Panier moyen', receiptMoney(r.averageBasket)),
            kpi('Encaissé', receiptMoney(r.collected)),
            kpi('Vendu à crédit', receiptMoney(r.onCredit)),
            kpi('Remises', receiptMoney(r.discounts), hint: '${r.voidedCount} vente(s) annulée(s)'),
          ],
        ),
        pw.SizedBox(height: 18),
        pw.Text(r.byMonth ? 'Par mois' : 'Par jour', style: h2),
        pw.SizedBox(height: 6),
        table(
          ['Période', 'Ventes', 'Chiffre d’affaires', 'Bénéfice brut'],
          [
            for (final p in r.series.where((p) => p.salesCount > 0 || r.series.length <= 31))
              [
                dayFmt.format(DateTime.parse(p.period.length == 7 ? '${p.period}-01' : p.period)),
                '${p.salesCount}',
                receiptMoney(p.revenue),
                receiptMoney(p.grossProfit),
              ],
          ],
        ),
        if (r.topProducts.isNotEmpty) ...[
          pw.SizedBox(height: 18),
          pw.Text('Meilleurs produits', style: h2),
          pw.SizedBox(height: 6),
          table(
            ['Produit', 'Quantité', 'Chiffre d’affaires', 'Bénéfice brut'],
            [
              for (final p in r.topProducts)
                [p.name, qty(p.quantity), receiptMoney(p.revenue), receiptMoney(p.grossProfit)],
            ],
          ),
        ],
        if (r.byMethod.isNotEmpty) ...[
          pw.SizedBox(height: 18),
          pw.Text('Moyens de paiement', style: h2),
          pw.SizedBox(height: 6),
          table(
            ['Moyen', 'Ventes', 'Montant'],
            [
              for (final m in r.byMethod) [m.method?.label ?? 'Autre', '${m.salesCount}', receiptMoney(m.amount)],
            ],
          ),
        ],
        if (r.bySeller.isNotEmpty) ...[
          pw.SizedBox(height: 18),
          pw.Text('Vendeurs', style: h2),
          pw.SizedBox(height: 6),
          table(
            ['Vendeur', 'Ventes', 'Chiffre d’affaires'],
            [
              for (final v in r.bySeller) [v.name, '${v.salesCount}', receiptMoney(v.revenue)],
            ],
          ),
        ],
        if (r.expensesByCategory.isNotEmpty) ...[
          pw.SizedBox(height: 18),
          pw.Text('Dépenses', style: h2),
          pw.SizedBox(height: 6),
          table(
            ['Catégorie', 'Montant'],
            [
              for (final e in r.expensesByCategory)
                ['${e.category[0].toUpperCase()}${e.category.substring(1)}', receiptMoney(e.amount)],
            ],
          ),
        ],
        if (r.invoiceCount > 0 || r.invoicePayments > 0) ...[
          pw.SizedBox(height: 18),
          pw.Text('Factures', style: h2),
          pw.SizedBox(height: 6),
          pw.Text(
            '${r.invoiceCount} facture(s) émise(s) : ${receiptMoney(r.invoiced)} · paiements reçus : ${receiptMoney(r.invoicePayments)}',
            style: base,
          ),
        ],
      ],
    ),
  );
  return doc.save();
}
