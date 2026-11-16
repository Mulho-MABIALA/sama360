import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/features/reports/report_pdf.dart';
import 'package:sama360/features/reports/reports_screen.dart';
import 'package:sama360/features/sales/receipt.dart';

import 'helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await initializeDateFormatting('fr');
    await loadTestFonts();
  });

  test('bornes des périodes', () {
    final now = DateTime(2026, 11, 16, 15, 30);
    expect(ReportRange.today.bounds(now), (from: DateTime(2026, 11, 16), to: DateTime(2026, 11, 16)));
    expect(ReportRange.week.bounds(now), (from: DateTime(2026, 11, 10), to: DateTime(2026, 11, 16)));
    expect(ReportRange.thisMonth.bounds(now), (from: DateTime(2026, 11, 1), to: DateTime(2026, 11, 16)));
    expect(ReportRange.lastMonth.bounds(now), (from: DateTime(2026, 10, 1), to: DateTime(2026, 10, 31)));
    expect(ReportRange.lastMonth.bounds(DateTime(2027, 1, 5)), (
      from: DateTime(2026, 12, 1),
      to: DateTime(2026, 12, 31),
    ));
    expect(ReportRange.year.bounds(now).from, DateTime(2025, 12, 1));
  });

  test('PDF du rapport', () async {
    final repo = FakeRepo();
    final r = await repo.report(DateTime(2026, 11, 10), DateTime(2026, 11, 16));
    final bytes = await buildReportPdf(r, demoBusiness, fonts: await ReceiptFonts.load());
    expect(ascii.decode(bytes.sublist(0, 5)), '%PDF-');
    expect(reportFileName(r), 'Rapport-2026-11-10-au-2026-11-16.pdf');
  });

  testWidgets('rapports : 7 jours par défaut, changement de période, détail d’une barre', (tester) async {
    phoneSize(tester);
    final (_, repo) = await pumpSama(tester);
    await tester.ensureVisible(find.text('Rapports'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rapports'));
    await tester.pumpAndSettle();

    expect(find.text('Chiffre d’affaires'), findsWidgets);
    expect(find.text('+18 %'), findsOneWidget);
    expect(find.text('Chiffre d’affaires par jour'), findsOneWidget);
    final (from, to) = repo.reportRequests.last;
    expect(to.difference(from).inDays, 6);

    await tester.ensureVisible(find.text('12 mois'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('12 mois'));
    await tester.pumpAndSettle();
    expect(repo.reportRequests.last.$2.difference(repo.reportRequests.last.$1).inDays, greaterThan(300));
    expect(find.text('Chiffre d’affaires par mois'), findsOneWidget);

    await tester.ensureVisible(find.text('7 jours'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('7 jours'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(RevenueChart), warnIfMissed: false);
    await tester.pump();
    expect(find.textContaining('vente(s) · bénéfice'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('Meilleurs produits'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.text('Moyens de paiement'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Vendeurs'), 300, scrollable: find.byType(Scrollable).first);
    await tester.scrollUntilVisible(find.text('Loyer'), 300, scrollable: find.byType(Scrollable).first);
  });
}
