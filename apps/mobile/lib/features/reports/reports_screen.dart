import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/privacy.dart';
import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../sales/receipt_screen.dart' show receiptActionsProvider;
import 'report_pdf.dart';

/// Périodes proposées.
enum ReportRange {
  today('Aujourd’hui'),
  week('7 jours'),
  month('30 jours'),
  thisMonth('Ce mois'),
  lastMonth('Mois dernier'),
  year('12 mois'),
  custom('Dates…');

  const ReportRange(this.label);
  final String label;

  /// Bornes (jours entiers) de la période, à partir d'aujourd'hui.
  ({DateTime from, DateTime to}) bounds(DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    return switch (this) {
      ReportRange.today => (from: today, to: today),
      ReportRange.week => (from: today.subtract(const Duration(days: 6)), to: today),
      ReportRange.month => (from: today.subtract(const Duration(days: 29)), to: today),
      ReportRange.thisMonth => (from: DateTime(today.year, today.month), to: today),
      ReportRange.lastMonth => (from: DateTime(today.year, today.month - 1), to: DateTime(today.year, today.month, 0)),
      ReportRange.year => (from: DateTime(today.year, today.month - 11), to: today),
      _ => (from: today, to: today),
    };
  }
}

String periodLabel(DateTime from, DateTime to) {
  final f = DateFormat('d MMM yyyy', 'fr');
  if (from == to) return DateFormat('EEEE d MMMM yyyy', 'fr').format(from);
  return '${f.format(from)} – ${f.format(to)}';
}

String expenseLabel(String c) => c.isEmpty ? c : '${c[0].toUpperCase()}${c.substring(1)}';

class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key, this.now});

  /// Date du jour (remplaçable dans les tests).
  final DateTime? now;
  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  ReportRange _range = ReportRange.week;
  ({DateTime from, DateTime to})? _custom;
  bool _exporting = false;

  DateTime get _now => widget.now ?? DateTime.now();
  ({DateTime from, DateTime to}) get _period =>
      _range == ReportRange.custom && _custom != null ? _custom! : _range.bounds(_now);

  Future<void> _pickDates() async {
    final today = DateTime(_now.year, _now.month, _now.day);
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(today.year - 3),
      lastDate: today,
      initialDateRange: DateTimeRange(start: _period.from, end: _period.to),
      helpText: 'Période du rapport',
      saveText: 'Valider',
    );
    if (picked == null) return;
    setState(() {
      _range = ReportRange.custom;
      _custom = (from: picked.start, to: picked.end);
    });
  }

  Future<void> _export(ReportOverview r) async {
    setState(() => _exporting = true);
    try {
      final b = await ref.read(currentBusinessProvider.future);
      final bytes = await buildReportPdf(r, b);
      await ref.read(receiptActionsProvider).sharePdf(bytes, reportFileName(r));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = ref.watch(reportProvider(_period));
    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Rapports', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          if (report.value != null)
            ShareAction(tooltip: 'Exporter en PDF', busy: _exporting, onPressed: () => _export(report.value!)),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(reportProvider(_period)),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final r in ReportRange.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Pill(
                        label: r.label,
                        selected: _range == r,
                        onTap: r == ReportRange.custom ? _pickDates : () => setState(() => _range = r),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(periodLabel(_period.from, _period.to), style: TextStyle(color: AppColors.muted)),
            const SizedBox(height: 10),
            Glass(
              key: const Key('open_insights'),
              radius: 20,
              onTap: () => context.push('/insights'),
              padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
              child: Row(
                children: [
                  Icon(Icons.auto_graph_rounded, color: AppColors.green),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Analyses : heures de pointe, marges, produits qui dorment',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, color: AppColors.muted),
                ],
              ),
            ),
            const SizedBox(height: 12),
            AsyncView<ReportOverview>(
              value: report,
              onRetry: () => ref.invalidate(reportProvider(_period)),
              data: (r) => _ReportBody(report: r),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReportBody extends StatefulWidget {
  const _ReportBody({required this.report});
  final ReportOverview report;

  @override
  State<_ReportBody> createState() => _ReportBodyState();
}

class _ReportBodyState extends State<_ReportBody> {
  /// Les chiffres détaillés (bénéfice sur les ventes, dépenses, moyens de paiement…) sont repliés.
  bool _more = false;

  @override
  Widget build(BuildContext context) {
    final r = widget.report;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Hero(report: r),
        const SizedBox(height: 12),
        _Card(
          title: r.byMonth ? 'Vendu par mois' : 'Vendu par jour',
          child: RevenueChart(points: r.series, byMonth: r.byMonth),
        ),
        if (r.topProducts.isNotEmpty) ...[
          const SizedBox(height: 12),
          _Card(
            title: 'Meilleurs produits',
            child: Column(
              children: [
                for (final (i, p) in r.topProducts.indexed)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        Container(
                          width: 28,
                          height: 28,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: i < 3 ? AppColors.saffron.withValues(alpha: 0.18) : AppColors.line,
                            shape: BoxShape.circle,
                          ),
                          child: Text('${i + 1}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                p.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.w700),
                              ),
                              Text(
                                '${qty(p.quantity)} vendu(s) · bénéfice ${moneyShort(p.grossProfit)}',
                                style: TextStyle(fontSize: 12, color: AppColors.muted),
                              ),
                            ],
                          ),
                        ),
                        Text(moneyShort(p.revenue), style: const TextStyle(fontWeight: FontWeight.w800)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 12),
        Glass(
          key: const Key('report_more'),
          radius: 20,
          onTap: () => setState(() => _more = !_more),
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          child: Row(
            children: [
              Icon(Icons.insights_rounded, color: AppColors.green),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _more ? 'Moins de chiffres' : 'Voir plus de chiffres',
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                ),
              ),
              AnimatedRotation(
                turns: _more ? 0.5 : 0,
                duration: const Duration(milliseconds: 200),
                child: Icon(Icons.expand_more_rounded, color: AppColors.muted),
              ),
            ],
          ),
        ),
        if (_more) ...[
          const SizedBox(height: 12),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 2.1,
            children: [
              _Kpi(
                label: 'Gagné sur les ventes',
                value: moneyShort(r.grossProfit),
                hint: 'Marge ${r.marginRate.toStringAsFixed(1).replaceAll('.', ',')} %',
              ),
              _Kpi(
                label: 'Dépenses',
                value: moneyShort(r.expenses),
                hint: '${r.expensesByCategory.length} catégorie(s)',
              ),
              _Kpi(label: 'Vente moyenne', value: moneyShort(r.averageBasket), hint: '${r.salesCount} vente(s)'),
              _Kpi(label: 'Argent reçu', value: moneyShort(r.collected), hint: 'sur les ventes'),
              _Kpi(
                label: 'Vendu à crédit',
                value: moneyShort(r.onCredit),
                hint: 'on vous doit encore',
                warn: r.onCredit > 0,
              ),
              _Kpi(label: 'Réductions', value: moneyShort(r.discounts), hint: '${r.voidedCount} vente(s) annulée(s)'),
            ],
          ),
          if (r.byMethod.isNotEmpty) ...[
            const SizedBox(height: 12),
            _Card(
              title: 'Moyens de paiement',
              child: _Bars(
                rows: [
                  for (final m in r.byMethod)
                    (
                      label: m.method?.label ?? 'Autre',
                      value: m.amount,
                      sub: '${m.salesCount} vente(s)',
                      color: _methodColor(m.method),
                    ),
                ],
              ),
            ),
          ],
          if (r.bySeller.length > 1) ...[
            const SizedBox(height: 12),
            _Card(
              title: 'Vendeurs',
              child: _Bars(
                rows: [
                  for (final v in r.bySeller)
                    (
                      label: v.name.startsWith('+') ? intlPhone(v.name) : v.name,
                      value: v.revenue,
                      sub: '${v.salesCount} vente(s)',
                      color: AppColors.green,
                    ),
                ],
              ),
            ),
          ],
          if (r.expensesByCategory.isNotEmpty) ...[
            const SizedBox(height: 12),
            _Card(
              title: 'Dépenses',
              child: _Bars(
                rows: [
                  for (final e in r.expensesByCategory)
                    (label: expenseLabel(e.category), value: e.amount, sub: null, color: const Color(0xFFE0533D)),
                ],
              ),
            ),
          ],
          if (r.invoiceCount > 0 || r.invoicePayments > 0) ...[
            const SizedBox(height: 12),
            _Card(
              title: 'Factures',
              child: Row(
                children: [
                  Expanded(
                    child: _Mini(label: 'Facturé (${r.invoiceCount})', value: moneyShort(r.invoiced)),
                  ),
                  Expanded(
                    child: _Mini(label: 'Paiements reçus', value: moneyShort(r.invoicePayments)),
                  ),
                ],
              ),
            ),
          ],
        ],
        if (r.salesCount == 0)
          Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Aucune vente sur cette période.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.muted),
            ),
          ),
      ],
    );
  }

  static Color _methodColor(PayMethod? m) => switch (m) {
    PayMethod.cash => const Color(0xFF0A8453),
    PayMethod.wave => const Color(0xFF1D7AF0),
    PayMethod.orangeMoney => const Color(0xFFE07A12),
    PayMethod.freeMoney => const Color(0xFFDB2777),
    PayMethod.mtnMomo => const Color(0xFFC79A00),
    PayMethod.moovMoney => const Color(0xFF0066B3),
    PayMethod.airtelMoney => const Color(0xFFE40000),
    _ => AppColors.muted,
  };
}

/// Évolution en % : flèche et couleur (vert en hausse, rouge en baisse).
class ChangeChip extends StatelessWidget {
  const ChangeChip({super.key, required this.pct, this.onDark = false});
  final double? pct;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final p = pct;
    if (p == null) {
      return Text(
        'Pas de comparaison',
        style: TextStyle(fontSize: 12, color: onDark ? const Color(0xFFCDE9DD) : AppColors.muted),
      );
    }
    final up = p >= 0;
    final color = onDark
        ? (up ? AppColors.glow : const Color(0xFFFFB4A8))
        : (up ? AppColors.greenDark : AppColors.danger);
    final text = '${up ? '+' : ''}${p.toStringAsFixed(p.abs() >= 10 ? 0 : 1).replaceAll('.', ',')} %';
    return Semantics(
      label: '${up ? 'Hausse' : 'Baisse'} de ${p.abs().toStringAsFixed(1)} % par rapport à la période précédente',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(20)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(up ? Icons.trending_up_rounded : Icons.trending_down_rounded, size: 15, color: color),
            const SizedBox(width: 4),
            Text(
              text,
              style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12.5),
            ),
          ],
        ),
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.report});
  final ReportOverview report;

  @override
  Widget build(BuildContext context) {
    final r = report;
    const muted = Color(0xFFCDE9DD);
    return Sheen(
      radius: 26,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: AuroraBackground(
          tone: AuroraTone.deep,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const LabelWithEye('Vendu', style: TextStyle(color: muted, fontSize: 12.5)),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: MaskedText(
                    moneyShort(r.revenue),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 34,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.8,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    ChangeChip(pct: r.revenueChange, onDark: true),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        'vs ${moneyShort(r.previousRevenue)} la période précédente',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: muted, fontSize: 12),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                // Les deux autres chiffres qui comptent : ce qu'il reste en poche, ce qu'on vous doit
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: _HeroFigure(
                          key: const Key('report_gained'),
                          label: 'Gagné',
                          hint: 'après achats et dépenses',
                          value: moneyShort(r.netProfit),
                          color: r.netProfit < 0 ? const Color(0xFFFFB4A8) : AppColors.glow,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _HeroFigure(
                          key: const Key('report_owed'),
                          label: 'On vous doit',
                          hint: 'ventes à crédit',
                          value: moneyShort(r.onCredit),
                          color: r.onCredit > 0 ? const Color(0xFFFFD59A) : Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Un des chiffres clés posés sur la carte verte.
class _HeroFigure extends StatelessWidget {
  const _HeroFigure({super.key, required this.label, required this.hint, required this.value, required this.color});
  final String label;
  final String hint;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(16)),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13),
        ),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: MaskedText(
            value,
            style: TextStyle(color: color, fontWeight: FontWeight.w900, fontSize: 22),
          ),
        ),
        Text(hint, style: const TextStyle(color: Color(0xFFCDE9DD), fontSize: 11.5)),
      ],
    ),
  );
}

class _Kpi extends StatelessWidget {
  const _Kpi({required this.label, required this.value, required this.hint, this.warn = false});
  final String label;
  final String value;
  final String hint;
  final bool warn;

  @override
  Widget build(BuildContext context) => Glass(
    radius: 18,
    blur: 10,
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 12, color: AppColors.muted, fontWeight: FontWeight.w600),
        ),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: warn ? AppColors.warnText : AppColors.ink,
            ),
          ),
        ),
        Text(
          hint,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11, color: AppColors.muted),
        ),
      ],
    ),
  );
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Glass(
    radius: 22,
    padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
        ),
        const SizedBox(height: 10),
        child,
      ],
    ),
  );
}

class _Mini extends StatelessWidget {
  const _Mini({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: TextStyle(fontSize: 12, color: AppColors.muted)),
      Text(value, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
    ],
  );
}

/// Barres horizontales avec part du total.
class _Bars extends StatelessWidget {
  const _Bars({required this.rows});
  final List<({String label, int value, String? sub, Color color})> rows;

  @override
  Widget build(BuildContext context) {
    final total = rows.fold(0, (s, r) => s + r.value);
    final max = rows.fold(0, (m, r) => math.max(m, r.value));
    return Column(
      children: [
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        r.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    Text(moneyShort(r.value), style: const TextStyle(fontWeight: FontWeight.w800)),
                    SizedBox(
                      width: 48,
                      child: Text(
                        total == 0 ? '' : '${(r.value * 100 / total).round()} %',
                        textAlign: TextAlign.right,
                        style: TextStyle(color: AppColors.muted, fontSize: 12.5),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: max == 0 ? 0 : r.value / max,
                    minHeight: 7,
                    backgroundColor: AppColors.line,
                    color: r.color,
                  ),
                ),
                if (r.sub != null) ...[
                  const SizedBox(height: 2),
                  Text(r.sub!, style: TextStyle(fontSize: 11.5, color: AppColors.muted)),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

/// Graphique en barres du chiffre d'affaires (bénéfice brut en surimpression).
/// Toucher une barre affiche son détail.
class RevenueChart extends StatefulWidget {
  const RevenueChart({super.key, required this.points, required this.byMonth});
  final List<ReportPoint> points;
  final bool byMonth;
  @override
  State<RevenueChart> createState() => _RevenueChartState();
}

class _RevenueChartState extends State<RevenueChart> {
  int? _selected;

  String _label(String period, {bool long = false}) {
    if (widget.byMonth) {
      final d = DateTime.parse(period.length == 7 ? '$period-01' : period);
      return DateFormat(long ? 'MMMM yyyy' : 'MMM', 'fr').format(d);
    }
    final d = DateTime.parse(period);
    return DateFormat(long ? 'EEEE d MMMM' : (widget.points.length <= 7 ? 'EEE' : 'd/M'), 'fr').format(d);
  }

  @override
  Widget build(BuildContext context) {
    final pts = widget.points;
    if (pts.isEmpty) return const SizedBox.shrink();
    final best = pts.reduce((a, b) => b.revenue > a.revenue ? b : a);
    final sel = _selected == null ? null : pts[_selected!.clamp(0, pts.length - 1)];
    final summary =
        'Meilleur ${widget.byMonth ? 'mois' : 'jour'} : ${_label(best.period, long: true)}, ${moneyShort(best.revenue)}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          sel == null
              ? summary
              : '${_label(sel.period, long: true)} : ${moneyShort(sel.revenue)} · ${sel.salesCount} vente(s) · bénéfice ${moneyShort(sel.grossProfit)}',
          style: TextStyle(fontSize: 12.5, color: AppColors.muted),
        ),
        const SizedBox(height: 10),
        Semantics(
          label: 'Graphique du chiffre d’affaires. $summary',
          excludeSemantics: true,
          child: LayoutBuilder(
            builder: (_, c) => GestureDetector(
              onTapDown: (d) => setState(() {
                final i = (d.localPosition.dx / (c.maxWidth / pts.length)).floor().clamp(0, pts.length - 1);
                _selected = _selected == i ? null : i;
              }),
              child: CustomPaint(size: Size(c.maxWidth, 150), painter: _ChartPainter(pts, _selected)),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text(_label(pts.first.period), style: TextStyle(fontSize: 11, color: AppColors.muted)),
            const Spacer(),
            if (pts.length > 2)
              Text(_label(pts[pts.length ~/ 2].period), style: TextStyle(fontSize: 11, color: AppColors.muted)),
            const Spacer(),
            Text(_label(pts.last.period), style: TextStyle(fontSize: 11, color: AppColors.muted)),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            _Legend(color: AppColors.leaf, label: 'Vendu'),
            SizedBox(width: 14),
            _Legend(color: AppColors.greenDark, label: 'Gagné'),
          ],
        ),
      ],
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});
  final Color color;
  final String label;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
      ),
      const SizedBox(width: 5),
      Text(label, style: TextStyle(fontSize: 11.5, color: AppColors.muted)),
    ],
  );
}

class _ChartPainter extends CustomPainter {
  _ChartPainter(this.points, this.selected);
  final List<ReportPoint> points;
  final int? selected;

  @override
  void paint(Canvas canvas, Size size) {
    final maxV = points.fold(0, (m, p) => math.max(m, p.revenue));
    final grid = Paint()
      ..color = AppColors.line
      ..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final y = size.height * i / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    if (maxV == 0) return;
    final slot = size.width / points.length;
    final barW = math.max(2.0, math.min(28.0, slot * 0.62));
    for (var i = 0; i < points.length; i++) {
      final p = points[i];
      final x = slot * i + (slot - barW) / 2;
      final h = size.height * p.revenue / maxV;
      final dim = selected != null && selected != i;
      final r = RRect.fromRectAndCorners(
        Rect.fromLTWH(x, size.height - h, barW, h),
        topLeft: Radius.circular(barW / 3),
        topRight: Radius.circular(barW / 3),
      );
      canvas.drawRRect(
        r,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              AppColors.glow.withValues(alpha: dim ? 0.35 : 1),
              AppColors.leaf.withValues(alpha: dim ? 0.35 : 1),
            ],
          ).createShader(r.outerRect),
      );
      if (p.grossProfit > 0) {
        final ph = size.height * p.grossProfit / maxV;
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            Rect.fromLTWH(x + barW * 0.25, size.height - ph, barW * 0.5, ph),
            topLeft: Radius.circular(barW / 5),
            topRight: Radius.circular(barW / 5),
          ),
          Paint()..color = AppColors.greenDark.withValues(alpha: dim ? 0.35 : 0.9),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_ChartPainter old) => old.points != points || old.selected != selected;
}
