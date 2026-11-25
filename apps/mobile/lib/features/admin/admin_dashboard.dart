import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/admin_models.dart';
import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import 'admin_widgets.dart';

/// Back office : vue d'ensemble de Sama360 (boutiques, abonnements, revenus).
class AdminDashboardScreen extends ConsumerStatefulWidget {
  const AdminDashboardScreen({super.key});
  @override
  ConsumerState<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends ConsumerState<AdminDashboardScreen> {
  int _days = 30;

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(adminOverviewProvider(_days));
    final wide = MediaQuery.sizeOf(context).width >= adminWide;
    return AdminShell(
      section: AdminSection.dashboard,
      title: 'Tableau de bord',
      subtitle: 'Toute l’activité de Sama360',
      actions: [
        IconButton(
          tooltip: 'Actualiser',
          onPressed: () => ref.invalidate(adminOverviewProvider(_days)),
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
      child: RefreshIndicator(
        onRefresh: () => ref.refresh(adminOverviewProvider(_days).future),
        child: AsyncView<AdminOverview>(
          value: data,
          onRetry: () => ref.invalidate(adminOverviewProvider(_days)),
          data: (o) => ListView(
            padding: EdgeInsets.fromLTRB(wide ? 28 : 16, 0, wide ? 28 : 16, wide ? 32 : 110),
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final (d, label) in const [(7, '7 jours'), (30, '30 jours'), (90, '3 mois'), (365, '1 an')])
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Pill(
                          key: Key('admin_days_$d'),
                          label: label,
                          selected: _days == d,
                          onTap: () => setState(() => _days = d),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              if (o.pendingPayments > 0) ...[_PendingBanner(count: o.pendingPayments), const SizedBox(height: 14)],
              if (o.newFeedback > 0) ...[
                _PendingBanner(
                  key: const Key('admin_feedback_banner'),
                  count: o.newFeedback,
                  text:
                      '${o.newFeedback} nouvelle${o.newFeedback > 1 ? 's' : ''} suggestion${o.newFeedback > 1 ? 's' : ''} de commerçants',
                  icon: Icons.lightbulb_rounded,
                  path: '/admin/feedback',
                ),
                const SizedBox(height: 14),
              ],
              _Hero(o: o),
              const SizedBox(height: 14),
              TileGrid(
                children: [
                  KpiTile(
                    key: const Key('kpi_shops'),
                    icon: Icons.storefront_rounded,
                    color: const Color(0xFF0F9D6B),
                    label: 'Boutiques',
                    value: '${o.businesses}',
                    hint: '+${o.newBusinesses} sur la période',
                    change: AdminOverview.change(o.newBusinesses, o.newPrevious),
                    onTap: () => context.pushReplacement('/admin/merchants'),
                  ),
                  KpiTile(
                    icon: Icons.bolt_rounded,
                    color: const Color(0xFFEA580C),
                    label: 'Actives (7 j)',
                    value: '${o.active7}',
                    hint: o.businesses == 0 ? '—' : '${(o.active7 * 100 / o.businesses).round()} % ont vendu',
                  ),
                  KpiTile(
                    icon: Icons.workspace_premium_rounded,
                    color: const Color(0xFFB7791F),
                    label: 'Clients Pro',
                    value: '${o.plans[AdminPlan.active]}',
                    hint: '${o.plans[AdminPlan.trial]} en essai',
                  ),
                  KpiTile(
                    icon: Icons.people_alt_rounded,
                    color: const Color(0xFF2563EB),
                    label: 'Utilisateurs',
                    value: '${o.users}',
                    hint: '${o.everSold} boutiques ont déjà vendu',
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _Columns(
                wide: wide,
                left: [
                  if (o.weeks.isNotEmpty) _Weeks(o: o),
                  AdminCard(
                    title: 'Revenus Pro',
                    trailing: Text(
                      '${o.paymentsCount} paiement${o.paymentsCount > 1 ? 's' : ''}',
                      style: TextStyle(color: AppColors.muted, fontSize: 12.5),
                    ),
                    child: DailyChart(
                      key: const Key('admin_revenue_chart'),
                      bars: true,
                      points: o.revenueByDay,
                      color: const Color(0xFFB7791F),
                      format: moneyShort,
                    ),
                  ),
                  AdminCard(
                    title: 'Nouvelles boutiques',
                    child: DailyChart(
                      points: o.signupsByDay,
                      color: AppColors.leaf,
                      format: (v) => '$v boutique${v > 1 ? 's' : ''}',
                    ),
                  ),
                  if (o.top.isNotEmpty) _TopShops(o: o),
                ],
                right: [
                  AdminCard(
                    title: 'Abonnements',
                    child: Donut(
                      center: '${o.businesses}',
                      parts: [
                        for (final p in [AdminPlan.active, AdminPlan.trial, AdminPlan.expired, AdminPlan.free])
                          (label: p.label, value: o.plans[p] ?? 0, color: PlanBadge.colorOf(p)),
                      ],
                    ),
                  ),
                  if (o.trialsEnding.isNotEmpty) _TrialsEnding(o: o),
                  AdminCard(
                    title: 'Pays',
                    child: Column(
                      children: [
                        for (final c in o.countries)
                          ShareBar(
                            leading: CountryFlag(c.country, width: 20),
                            label: c.country.name,
                            value: '${c.count}',
                            ratio: o.businesses == 0 ? 0 : c.count / o.businesses,
                            color: AppColors.leaf,
                          ),
                      ],
                    ),
                  ),
                  _Latest(o: o),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Deux colonnes sur bureau, une seule sur téléphone.
class _Columns extends StatelessWidget {
  const _Columns({required this.wide, required this.left, required this.right});
  final bool wide;
  final List<Widget> left;
  final List<Widget> right;

  List<Widget> _spaced(List<Widget> w) => [
    for (var i = 0; i < w.length; i++) ...[if (i > 0) const SizedBox(height: 14), w[i]],
  ];

  @override
  Widget build(BuildContext context) {
    if (!wide) return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _spaced([...left, ...right]));
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 3,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _spaced(left)),
        ),
        const SizedBox(width: 14),
        Expanded(
          flex: 2,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _spaced(right)),
        ),
      ],
    );
  }
}

class _PendingBanner extends StatelessWidget {
  const _PendingBanner({
    super.key = const Key('admin_pending_banner'),
    required this.count,
    this.text,
    this.icon = Icons.hourglass_top_rounded,
    this.path = '/admin/payments',
  });
  final int count;
  final String? text;
  final IconData icon;
  final String path;
  @override
  Widget build(BuildContext context) => Glass(
    radius: 20,
    tint: AppColors.orange,
    onTap: () => context.pushReplacement(path),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    child: Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: AppColors.orange.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: AppColors.warnText, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text ?? '$count paiement${count > 1 ? 's' : ''} par transfert à vérifier',
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
        Icon(Icons.chevron_right_rounded, color: AppColors.muted),
      ],
    ),
  );
}

/// Carte vert profond : ce que Sama360 encaisse.
class _Hero extends StatelessWidget {
  const _Hero({required this.o});
  final AdminOverview o;

  @override
  Widget build(BuildContext context) {
    const muted = Color(0xFFCDE9DD);
    final change = AdminOverview.change(o.revenue, o.revenuePrevious);
    Widget stat(String label, String value, {Color color = Colors.white}) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: muted, fontSize: 11.5)),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 17),
          ),
        ),
      ],
    );
    return Sheen(
      radius: 26,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: AuroraBackground(
          tone: AuroraTone.deep,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Encaissé sur ${o.days == 365 ? '1 an' : '${o.days} jours'}',
                  style: const TextStyle(color: muted, fontSize: 12.5),
                ),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    moneyShort(o.revenue),
                    key: const Key('admin_revenue'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 36,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -1,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    if (change != null) ...[TrendChip(pct: change, onDark: true), const SizedBox(width: 8)],
                    Flexible(
                      child: Text(
                        'vs ${moneyShort(o.revenuePrevious)} la période précédente',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: muted, fontSize: 12),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: LayoutBuilder(
                    builder: (context, c) {
                      final cells = [
                        stat('Revenu mensuel', moneyShort(o.mrr), color: AppColors.glow),
                        stat('En ligne', compactMoney(o.revenueOnline)),
                        stat('Transfert', compactMoney(o.revenueManual)),
                        stat('Depuis le début', compactMoney(o.revenueAllTime)),
                      ];
                      final cols = c.maxWidth >= 520 ? 4 : 2;
                      final w = (c.maxWidth - 12 * (cols - 1)) / cols;
                      return Wrap(
                        spacing: 12,
                        runSpacing: 10,
                        children: [for (final cell in cells) SizedBox(width: w, child: cell)],
                      );
                    },
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Les commerçants ont vendu pour ${moneyShort(o.gmv30)} en 30 jours (${o.sales30} ventes).',
                  style: const TextStyle(color: muted, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TopShops extends StatelessWidget {
  const _TopShops({required this.o});
  final AdminOverview o;
  @override
  Widget build(BuildContext context) {
    final best = o.top.first.revenue30;
    return AdminCard(
      title: 'Boutiques les plus actives',
      trailing: Text('30 jours', style: TextStyle(color: AppColors.muted, fontSize: 12.5)),
      child: Column(
        children: [
          for (final (i, t) in o.top.indexed)
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => context.push('/admin/merchants/${t.id}'),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: ShareBar(
                  leading: Text(
                    '${i + 1}',
                    style: TextStyle(color: AppColors.muted, fontWeight: FontWeight.w900),
                  ),
                  label: t.name,
                  value: moneyShort(t.revenue30),
                  ratio: best == 0 ? 0 : t.revenue30 / best,
                  color: const Color(0xFF0F9D6B),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TrialsEnding extends StatelessWidget {
  const _TrialsEnding({required this.o});
  final AdminOverview o;
  @override
  Widget build(BuildContext context) => AdminCard(
    title: 'Essais qui se terminent',
    trailing: Text('à relancer', style: TextStyle(color: AppColors.muted, fontSize: 12.5)),
    child: Column(
      children: [
        for (final t in o.trialsEnding)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            onTap: () => context.push('/admin/merchants/${t.id}'),
            leading: ShopAvatar(t.name, size: 36),
            title: Text(t.name, style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(intlPhone(t.ownerPhone)),
            trailing: Text(
              t.daysLeft <= 0 ? 'aujourd’hui' : '${t.daysLeft} j',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: t.daysLeft <= 2 ? AppColors.danger : AppColors.warnText,
              ),
            ),
          ),
      ],
    ),
  );
}

class _Latest extends StatelessWidget {
  const _Latest({required this.o});
  final AdminOverview o;
  @override
  Widget build(BuildContext context) => AdminCard(
    title: 'Dernières inscriptions',
    trailing: TextButton(
      style: TextButton.styleFrom(minimumSize: const Size(0, 36)),
      onPressed: () => context.pushReplacement('/admin/merchants'),
      child: const Text('Tout voir'),
    ),
    child: o.latest.isEmpty
        ? Text('Aucune boutique', style: TextStyle(color: AppColors.muted))
        : Column(
            children: [
              for (final b in o.latest)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  onTap: () => context.push('/admin/merchants/${b.id}'),
                  leading: ShopAvatar(b.name, size: 36),
                  title: Text(
                    b.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text([b.country.name, DateFormat('d MMM', 'fr').format(b.createdAt)].join(' · ')),
                  trailing: PlanBadge(b.plan),
                ),
            ],
          ),
  );
}

/// Semaine par semaine : est-ce que Sama360 prend ? Inscrits → ont vendu → Pro, et les départs.
class _Weeks extends StatelessWidget {
  const _Weeks({required this.o});
  final AdminOverview o;

  @override
  Widget build(BuildContext context) {
    final head = TextStyle(color: AppColors.muted, fontSize: 11.5, fontWeight: FontWeight.w700);
    String pct(int part, int of) => of == 0 ? '' : ' (${(part * 100 / of).round()} %)';
    Widget cell(String text, {TextStyle? style, int flex = 2}) => Expanded(
      flex: flex,
      child: Text(text, textAlign: flex == 3 ? TextAlign.start : TextAlign.end, style: style),
    );
    final total = o.weeks.fold((0, 0, 0), (t, w) => (t.$1 + w.signups, t.$2 + w.sold, t.$3 + w.paid));
    return AdminCard(
      key: const Key('admin_weeks'),
      title: 'Semaine par semaine',
      child: Column(
        children: [
          Text(
            'Sur 8 semaines : ${total.$1} inscrits, ${total.$2} vendent${pct(total.$2, total.$1)}, '
            '${total.$3} passés à Pro${pct(total.$3, total.$1)}',
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              cell('Semaine', style: head, flex: 3),
              cell('Inscrits', style: head),
              cell('Vendent', style: head),
              cell('Pro', style: head),
              cell('Arrêts', style: head),
            ],
          ),
          const SizedBox(height: 4),
          for (final w in o.weeks.reversed)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  cell('du ${DateFormat('d MMM', 'fr').format(w.week)}', flex: 3),
                  cell('${w.signups}', style: const TextStyle(fontWeight: FontWeight.w800)),
                  cell(
                    '${w.sold}',
                    style: TextStyle(color: AppColors.green, fontWeight: FontWeight.w700),
                  ),
                  cell(
                    '${w.paid}',
                    style: const TextStyle(color: Color(0xFFB7791F), fontWeight: FontWeight.w800),
                  ),
                  cell(
                    '${w.stopped + w.trialsLost}',
                    style: TextStyle(
                      color: w.stopped > 0 ? AppColors.danger : AppColors.muted,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 6),
          Text(
            'Vendent et Pro : parmi les inscrits de la semaine. Arrêts : abonnés non renouvelés '
            '(en rouge) et essais finis sans payer, pendant la semaine.',
            style: TextStyle(color: AppColors.muted, fontSize: 11.5),
          ),
        ],
      ),
    );
  }
}
