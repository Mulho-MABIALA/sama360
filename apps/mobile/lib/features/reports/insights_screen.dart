import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/privacy.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../sales/receipt_screen.dart' show receiptActionsProvider, whatsAppUri;

const weekdayNames = ['lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi', 'dimanche'];
const _weekdayLetters = ['L', 'M', 'M', 'J', 'V', 'S', 'D'];
const insightRanges = [7, 30, 90];

/// « 12,5 % » (une décimale, virgule).
String percent(double v) => '${v.toStringAsFixed(v.truncateToDouble() == v ? 0 : 1).replaceAll('.', ',')} %';

/// Phrase d'en-tête des heures de pointe.
String peakSentence(Insights i) {
  final p = i.peak;
  if (p == null) return 'Pas encore de ventes sur la période.';
  final day = i.bestWeekday == null ? '' : ' Le ${weekdayNames[i.bestWeekday! - 1]} est votre meilleur jour.';
  return 'Vos clients viennent surtout de ${p.from}\u00a0h à ${p.to}\u00a0h (${p.share}\u00a0% des ventes).$day';
}

/// « Jamais vendu » / « Dernière vente il y a 45 j ».
String dormantWhen(DormantProduct d) =>
    d.daysSinceSale == null ? 'Jamais vendu' : 'Dernière vente il y a ${d.daysSinceSale} j';

String _qty(double q) => q == q.roundToDouble() ? q.round().toString() : q.toStringAsFixed(1).replaceAll('.', ',');

/// Couleur d'une marge : rouge sous le seuil, ambre jusqu'à 30 %, vert au-delà.
Color marginColor(double? rate, int threshold) {
  if (rate == null) return AppColors.muted;
  if (rate < threshold) return AppColors.danger;
  if (rate < 30) return AppColors.warn;
  return AppColors.green;
}

/// Analyses : heures de pointe, marge par produit, produits qui dorment.
class InsightsScreen extends ConsumerStatefulWidget {
  const InsightsScreen({super.key});

  @override
  ConsumerState<InsightsScreen> createState() => _InsightsScreenState();
}

class _InsightsScreenState extends ConsumerState<InsightsScreen> {
  int _days = 30;

  @override
  Widget build(BuildContext context) {
    final insights = ref.watch(insightsProvider(_days));
    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Analyses', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(insightsProvider(_days));
          await ref.read(insightsProvider(_days).future);
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
          children: [
            const _WeeklyCard(),
            const SizedBox(height: 14),
            Row(
              children: [
                for (final d in insightRanges)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Pill(label: '$d jours', selected: _days == d, onTap: () => setState(() => _days = d)),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            AsyncView<Insights>(
              value: insights,
              onRetry: () => ref.invalidate(insightsProvider(_days)),
              data: (i) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _PeakCard(insights: i),
                  const SizedBox(height: 14),
                  _MarginCard(insights: i),
                  const SizedBox(height: 14),
                  _DormantCard(insights: i),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WeeklyCard extends StatelessWidget {
  const _WeeklyCard();

  @override
  Widget build(BuildContext context) => Glass(
    key: const Key('weekly_card'),
    radius: 22,
    tint: AppColors.whatsapp,
    onTap: () => context.push('/insights/week'),
    padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
    child: Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(color: AppColors.whatsapp, borderRadius: BorderRadius.circular(14)),
          child: const Icon(Icons.chat_rounded, color: AppColors.onWhatsapp),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Rapport de la semaine', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              Text('Le résumé à envoyer sur WhatsApp', style: TextStyle(color: AppColors.muted, fontSize: 12.5)),
            ],
          ),
        ),
        Icon(Icons.chevron_right_rounded, color: AppColors.muted),
      ],
    ),
  );
}

class _Section extends StatelessWidget {
  const _Section({required this.icon, required this.color, required this.title, required this.child, this.subtitle});
  final IconData icon;
  final Color color;
  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) => Glass(
    radius: 22,
    padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(11)),
              child: Icon(icon, size: 18, color: color),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            ),
          ],
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 8),
          Text(subtitle!, style: TextStyle(color: AppColors.muted, fontSize: 13, height: 1.35)),
        ],
        const SizedBox(height: 12),
        child,
      ],
    ),
  );
}

// ---------- Heures de pointe ----------

class _PeakCard extends StatelessWidget {
  const _PeakCard({required this.insights});
  final Insights insights;

  @override
  Widget build(BuildContext context) {
    final i = insights;
    // On montre la plage utile (de la 1re à la dernière heure avec des ventes, au moins 8 h – 21 h)
    final active = i.byHour.where((h) => h.salesCount > 0).map((h) => h.key).toList();
    final first = active.isEmpty ? 8 : (active.first < 8 ? active.first : 8);
    final last = active.isEmpty ? 21 : (active.last > 21 ? active.last : 21);
    final hours = i.byHour.where((h) => h.key >= first && h.key <= last).toList();
    final p = i.peak;
    return _Section(
      icon: Icons.schedule_rounded,
      color: const Color(0xFF2F6FDB),
      title: 'Heures de pointe',
      subtitle: peakSentence(i),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Bars(
            key: const Key('hour_bars'),
            values: [for (final h in hours) h.salesCount.toDouble()],
            labels: [for (final h in hours) h.key % 3 == 0 ? '${h.key}h' : ''],
            highlight: [for (final h in hours) p != null && h.key >= p.from && h.key < p.to],
            semantics: [for (final h in hours) '${h.key} heures : ${h.salesCount} vente(s)'],
            height: 92,
          ),
          const SizedBox(height: 14),
          Text(
            'Par jour',
            style: TextStyle(color: AppColors.muted, fontWeight: FontWeight.w700, fontSize: 12.5),
          ),
          const SizedBox(height: 6),
          _Bars(
            key: const Key('weekday_bars'),
            values: [for (final d in i.byWeekday) d.revenue.toDouble()],
            labels: [for (final d in i.byWeekday) _weekdayLetters[d.key - 1]],
            highlight: [for (final d in i.byWeekday) d.key == i.bestWeekday],
            semantics: [for (final d in i.byWeekday) '${weekdayNames[d.key - 1]} : ${moneyShort(d.revenue)}'],
            height: 64,
          ),
          if (p != null) ...[
            const SizedBox(height: 12),
            _Tip(text: 'Soyez au complet et bien approvisionné entre ${p.label} : c’est là que tout se joue.'),
          ],
        ],
      ),
    );
  }
}

class _Bars extends StatelessWidget {
  const _Bars({
    super.key,
    required this.values,
    required this.labels,
    required this.highlight,
    required this.semantics,
    required this.height,
  });
  final List<double> values;
  final List<String> labels;
  final List<bool> highlight;
  final List<String> semantics;
  final double height;

  @override
  Widget build(BuildContext context) {
    final max = values.fold<double>(0, (a, b) => b > a ? b : a);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var k = 0; k < values.length; k++)
          Expanded(
            child: Semantics(
              label: semantics[k],
              excludeSemantics: true,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      height: max == 0 ? 3 : 3 + (height - 3) * values[k] / max,
                      decoration: BoxDecoration(
                        color: highlight[k] ? AppColors.green : AppColors.green.withValues(alpha: 0.22),
                        borderRadius: BorderRadius.circular(5),
                      ),
                    ),
                    const SizedBox(height: 4),
                    SizedBox(
                      height: 14,
                      child: Text(
                        labels[k],
                        maxLines: 1,
                        overflow: TextOverflow.visible,
                        softWrap: false,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: highlight[k] ? AppColors.green : AppColors.muted,
                          fontWeight: highlight[k] ? FontWeight.w800 : FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _Tip extends StatelessWidget {
  const _Tip({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
    decoration: BoxDecoration(color: AppColors.surface(0.55), borderRadius: BorderRadius.circular(12)),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.lightbulb_rounded, size: 17, color: AppColors.warn),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 12.5, height: 1.35))),
      ],
    ),
  );
}

// ---------- Marges ----------

class _MarginCard extends ConsumerWidget {
  const _MarginCard({required this.insights});
  final Insights insights;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i = insights;
    final hidden = ref.watch(amountsHiddenProvider);
    final best = i.products.where((p) => p.costKnown).take(6).toList();
    final rate = i.marginRate;
    return _Section(
      icon: Icons.trending_up_rounded,
      color: AppColors.green,
      title: 'Marge par produit',
      subtitle: rate == null
          ? 'Les marges apparaîtront avec vos premières ventes de produits dont le prix d’achat est connu.'
          : 'Sur ${i.days} jours, vous gardez ${percent(rate)} de ce que vous vendez.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (i.lowMargin.isNotEmpty) ...[
            Text(
              'Marge faible (moins de ${i.lowMarginThreshold} %)',
              style: TextStyle(color: AppColors.danger, fontWeight: FontWeight.w800, fontSize: 13),
            ),
            const SizedBox(height: 6),
            for (final p in i.lowMargin.take(5))
              _MarginRow(product: p, threshold: i.lowMarginThreshold, hidden: hidden),
            const SizedBox(height: 4),
            const _Tip(text: 'Revoyez le prix de vente ou négociez le prix d’achat de ces produits.'),
            const SizedBox(height: 14),
          ],
          if (best.isNotEmpty) ...[
            Text(
              'Ce qui vous rapporte le plus',
              style: TextStyle(color: AppColors.muted, fontWeight: FontWeight.w700, fontSize: 12.5),
            ),
            const SizedBox(height: 6),
            for (final p in best) _MarginRow(product: p, threshold: i.lowMarginThreshold, hidden: hidden),
          ],
          if (i.unknownCostCount > 0) ...[
            const SizedBox(height: 10),
            Text(
              i.unknownCostCount == 1
                  ? '1 article vendu sans prix d’achat : sa marge n’est pas comptée.'
                  : '${i.unknownCostCount} articles vendus sans prix d’achat : leur marge n’est pas comptée.',
              key: const Key('unknown_cost_hint'),
              style: TextStyle(color: AppColors.muted, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

class _MarginRow extends StatelessWidget {
  const _MarginRow({required this.product, required this.threshold, required this.hidden});
  final ProductMargin product;
  final int threshold;
  final bool hidden;

  @override
  Widget build(BuildContext context) {
    final p = product;
    final color = marginColor(p.marginRate, threshold);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: p.productId == null ? null : () => context.push('/products/${p.productId}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
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
                    '${_qty(p.quantity)} vendu(s) · bénéfice ${maskMoney(hidden, moneyShort(p.profit))}',
                    style: TextStyle(color: AppColors.muted, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(color: color.withValues(alpha: 0.13), borderRadius: BorderRadius.circular(9)),
              child: Text(
                p.marginRate == null ? '—' : percent(p.marginRate!),
                style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------- Produits qui dorment ----------

class _DormantCard extends ConsumerWidget {
  const _DormantCard({required this.insights});
  final Insights insights;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i = insights;
    final hidden = ref.watch(amountsHiddenProvider);
    return _Section(
      icon: Icons.bedtime_rounded,
      color: const Color(0xFF7A5AF8),
      title: 'Produits qui ne se vendent plus',
      subtitle: i.dormantCount == 0
          ? 'Tous vos produits en stock se sont vendus ces ${i.days} derniers jours. Bravo !'
          : '${i.dormantCount} produit${i.dormantCount > 1 ? 's' : ''} sans vente depuis ${i.days} jours : '
                '${maskMoney(hidden, moneyShort(i.dormantValue))} d’argent qui dort en rayon.',
      child: i.dormant.isEmpty
          ? const SizedBox.shrink()
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final d in i.dormant.take(8))
                  InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => context.push('/products/${d.productId}'),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  d.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontWeight: FontWeight.w700),
                                ),
                                Text(
                                  '${dormantWhen(d)} · ${_qty(d.onHand)} en stock',
                                  style: TextStyle(color: AppColors.muted, fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                          Text(
                            maskMoney(hidden, moneyShort(d.stockValue)),
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 6),
                const _Tip(
                  text: 'Faites une promo, un lot ou mettez-les en avant à la caisse pour récupérer cet argent.',
                ),
              ],
            ),
    );
  }
}

// ---------- Rapport de la semaine ----------

class WeeklyReportScreen extends ConsumerStatefulWidget {
  const WeeklyReportScreen({super.key});

  @override
  ConsumerState<WeeklyReportScreen> createState() => _WeeklyReportScreenState();
}

class _WeeklyReportScreenState extends ConsumerState<WeeklyReportScreen> {
  /// null = semaine passée ; sinon un jour de la semaine affichée.
  DateTime? _week;

  DateTime _shift(WeeklyReport r, int weeks) => r.from.add(Duration(days: 7 * weeks));

  Future<void> _send(WeeklyReport r) async {
    HapticFeedback.selectionClick();
    final ok = await ref.read(receiptActionsProvider).openWhatsApp(whatsAppUri(r.text));
    if (!ok && mounted) showInfo(context, 'Impossible d’ouvrir WhatsApp');
  }

  Future<void> _copy(WeeklyReport r) async {
    await Clipboard.setData(ClipboardData(text: r.text));
    if (mounted) showInfo(context, 'Rapport copié');
  }

  @override
  Widget build(BuildContext context) {
    final report = ref.watch(weeklyReportProvider(_week));
    final thisMonday = DateTime.now().subtract(Duration(days: DateTime.now().weekday - 1));
    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Rapport de la semaine', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: AsyncView<WeeklyReport>(
        value: report,
        onRetry: () => ref.invalidate(weeklyReportProvider(_week)),
        data: (r) {
          final isCurrent = !r.to.isBefore(DateTime(thisMonday.year, thisMonday.month, thisMonday.day));
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: 'Semaine précédente',
                    onPressed: () => setState(() => _week = _shift(r, -1)),
                    icon: const Icon(Icons.chevron_left_rounded),
                  ),
                  Expanded(
                    child: Text(
                      'Du ${shortDate(r.from)} au ${shortDate(r.to)}',
                      key: const Key('week_label'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Semaine suivante',
                    onPressed: isCurrent ? null : () => setState(() => _week = _shift(r, 1)),
                    icon: const Icon(Icons.chevron_right_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _WeekHero(report: r),
              const SizedBox(height: 14),
              Glass(
                radius: 22,
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.visibility_rounded, size: 17, color: AppColors.muted),
                        const SizedBox(width: 6),
                        Text(
                          'Aperçu du message',
                          style: TextStyle(color: AppColors.muted, fontWeight: FontWeight.w700, fontSize: 12.5),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    _WhatsAppPreview(text: r.text),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 54,
                child: FilledButton.icon(
                  key: const Key('send_weekly'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.whatsapp,
                    foregroundColor: AppColors.onWhatsapp,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: () => _send(r),
                  icon: const Icon(Icons.chat_rounded),
                  label: const Text(
                    'Envoyer sur WhatsApp',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () => _copy(r),
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: const Text('Copier le texte'),
              ),
              const SizedBox(height: 4),
              Text(
                'Chaque lundi, une notification vous rappelle que le rapport est prêt. '
                'Envoyez-le à vous-même, à un associé ou au groupe de la boutique.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.muted, fontSize: 12),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _WeekHero extends ConsumerWidget {
  const _WeekHero({required this.report});
  final WeeklyReport report;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = report;
    final hidden = ref.watch(amountsHiddenProvider);
    final change = r.revenueChange;
    return Sheen(
      radius: 24,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: AuroraBackground(
          tone: AuroraTone.deep,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LabelWithEye('Chiffre d’affaires', style: const TextStyle(color: Color(0xFFCDE9DD), fontSize: 12.5)),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          maskMoney(hidden, moneyShort(r.revenue)),
                          style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w800),
                        ),
                      ),
                    ),
                    if (change != null) ...[
                      const SizedBox(width: 10),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          '${change >= 0 ? '+' : '−'}${percent(change.abs())}',
                          style: TextStyle(
                            color: change >= 0 ? AppColors.glow : const Color(0xFFFFA48F),
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _HeroChip(icon: Icons.receipt_rounded, text: '${r.salesCount} vente${r.salesCount > 1 ? 's' : ''}'),
                    _HeroChip(
                      icon: Icons.savings_rounded,
                      text: 'Bénéfice ${maskMoney(hidden, moneyShort(r.netProfit))}',
                    ),
                    if (r.peak != null) _HeroChip(icon: Icons.schedule_rounded, text: r.peak!.label),
                    if (r.bestWeekday != null)
                      _HeroChip(icon: Icons.event_rounded, text: weekdayNames[r.bestWeekday! - 1]),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HeroChip extends StatelessWidget {
  const _HeroChip({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: AppColors.glow),
        const SizedBox(width: 6),
        Text(
          text,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12.5),
        ),
      ],
    ),
  );
}

/// Bulle façon WhatsApp : *gras* rendu en gras, _italique_ en italique.
class _WhatsAppPreview extends StatelessWidget {
  const _WhatsAppPreview({required this.text});
  final String text;

  static List<TextSpan> spans(String text) {
    final out = <TextSpan>[];
    final re = RegExp(r'\*([^*\n]+)\*|_([^_\n]+)_');
    var at = 0;
    for (final m in re.allMatches(text)) {
      if (m.start > at) out.add(TextSpan(text: text.substring(at, m.start)));
      out.add(
        m.group(1) != null
            ? TextSpan(
                text: m.group(1),
                style: const TextStyle(fontWeight: FontWeight.w800),
              )
            : TextSpan(
                text: m.group(2),
                style: const TextStyle(fontStyle: FontStyle.italic),
              ),
      );
      at = m.end;
    }
    if (at < text.length) out.add(TextSpan(text: text.substring(at)));
    return out;
  }

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('weekly_preview'),
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
    decoration: BoxDecoration(
      color: AppColors.isDark ? const Color(0xFF144D37) : const Color(0xFFDCF8C6),
      borderRadius: const BorderRadius.only(
        topLeft: Radius.circular(14),
        topRight: Radius.circular(4),
        bottomLeft: Radius.circular(14),
        bottomRight: Radius.circular(14),
      ),
    ),
    child: Text.rich(
      TextSpan(children: spans(text)),
      style: TextStyle(fontSize: 13.5, height: 1.4, color: AppColors.isDark ? Colors.white : const Color(0xFF111B21)),
    ),
  );
}
