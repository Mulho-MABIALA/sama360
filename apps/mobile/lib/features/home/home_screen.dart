import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../auth/auth_controller.dart';
import '../../core/offline/pending_sales.dart';
import '../offline/offline_ui.dart';
import '../profile/profile_screen.dart';
import '../notifications/notifications_screen.dart' show tabRoutes;
import '../../core/charts.dart';
import '../../core/privacy.dart';
import '../../core/skeleton.dart';
import '../catalog/scan_lookup.dart';
import 'monument.dart';
import 'promo_carousel.dart';

class _Service {
  const _Service(this.name, this.icon, this.color, {this.route, this.soon = false});
  final String name;
  final IconData icon;
  final Color color;
  final String? route;
  final bool soon;
}

/// Tuiles principales de l'accueil (7 + « Plus »).
const _mainServices = [
  _Service('Ventes', Icons.point_of_sale_rounded, Color(0xFF0A8453), route: '/pos'),
  _Service('Stock', Icons.inventory_2_rounded, Color(0xFFD9822B), route: '/stock'),
  _Service('Clients', Icons.people_alt_rounded, Color(0xFF2F6FDB), route: '/customers'),
  _Service('Dépenses', Icons.account_balance_wallet_rounded, Color(0xFFE0533D), route: 'expense'),
  _Service('Factures', Icons.receipt_long_rounded, Color(0xFF7A5AF8), route: '/invoices'),
];

/// 6e tuile : les rapports pour qui peut les voir, sinon la boutique (bientôt).
const _reportsService = _Service('Rapports', Icons.insights_rounded, Color(0xFF0E9384), route: '/reports');
const _shopService = _Service('Boutique', Icons.storefront_rounded, Color(0xFF0E9384), route: '/shop');

/// 7e tuile : l'équipe pour qui peut la voir, sinon les paiements (bientôt).
const _teamService = _Service('Équipe', Icons.groups_rounded, Color(0xFFDB2777), route: '/team');
const _purchasesService = _Service('Achats', Icons.local_shipping_rounded, Color(0xFF8A5A2B), route: '/purchases');
const _paymentsService = _Service('Paiements', Icons.qr_code_2_rounded, Color(0xFF1D7AF0), soon: true);

/// Services des vagues 2 et 3, listés derrière « Plus ».
const _cashService = _Service('Caisse', Icons.point_of_sale_rounded, Color(0xFF13241C), route: '/cash');
const _moreServices = [
  _cashService,
  _Service('Relances', Icons.campaign_rounded, Color(0xFFE5484D), route: '/reminders'),
  _Service('Fidélité', Icons.stars_rounded, Color(0xFFE0A100), route: '/loyalty'),
  _purchasesService,
  _paymentsService,
  _shopService,
  _Service('Documents', Icons.folder_rounded, Color(0xFF6B7280), route: '/documents'),
  _Service('Livraison', Icons.local_shipping_rounded, Color(0xFFD9822B), soon: true),
  _Service('Réservation', Icons.event_available_rounded, Color(0xFF2F6FDB), soon: true),
  _Service('Assistant IA', Icons.auto_awesome_rounded, Color(0xFF7A5AF8), route: '/assistant'),
  _Service('Projets', Icons.task_alt_rounded, Color(0xFF0A8453), soon: true),
];

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider).value;
    final canReports = ref.can('reports:read');
    final canStock = ref.can('inventory:read');
    final lowStock = canStock ? ref.watch(stockProvider).value?.lowStock ?? 0 : 0;
    final hasShop = ref.watch(currentBusinessProvider).value?.modules.contains('shop') ?? false;
    final newShopOrders = hasShop && ref.can('sales:read') ? ref.watch(shopProvider).value?.newOrders ?? 0 : 0;

    final shown = [
      ..._mainServices,
      if (canReports) _reportsService else _shopService,
      if (ref.can('members:read'))
        _teamService
      else if (ref.can('inventory:read'))
        _purchasesService
      else
        _paymentsService,
    ];

    void open(_Service s) {
      if (s.soon) {
        showInfo(context, '${s.name} arrive bientôt sur Sama360');
      } else if (s.route == '/documents' && !ref.can('documents:read')) {
        showInfo(context, 'Documents : réservé au propriétaire, au gérant et au comptable');
      } else if (s.route == 'expense') {
        _addExpense(context, ref);
      } else if (tabRoutes.contains(s.route)) {
        context.go(s.route!); // onglet de la barre du bas
      } else {
        context.push(s.route!); // écran empilé : retour à l'accueil possible
      }
    }

    return AuroraScaffold(
      body: RefreshIndicator(
        onRefresh: () async {
          refreshBusinessData(ref);
          ref.invalidate(currentBusinessProvider);
        },
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            _Hero(
              name: auth?.me?.fullName,
              business: auth?.business?.name,
              card: _CashCard(showFigures: canReports, onExpense: () => _addExpense(context, ref)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 40, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SyncBanner(padding: EdgeInsets.only(bottom: 14)),
                  if (newShopOrders > 0) ...[_ShopOrdersBanner(count: newShopOrders), const SizedBox(height: 12)],
                  if (lowStock > 0) ...[_LowStockBanner(count: lowStock), const SizedBox(height: 18)],
                  const _SectionTitle('Vos services'),
                  const SizedBox(height: 10),
                  // Comme Wave : une seule carte, des icônes dans des carrés doux, sans tuile autour.
                  Glass(
                    radius: 24,
                    blur: 14,
                    padding: const EdgeInsets.fromLTRB(6, 14, 6, 6),
                    child: GridView.count(
                      crossAxisCount: 4,
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      physics: const NeverScrollableScrollPhysics(),
                      mainAxisSpacing: 6,
                      crossAxisSpacing: 4,
                      childAspectRatio: 1.0,
                      children: [
                        for (final s in shown) _ServiceTile(service: s, onTap: () => open(s)),
                        _ServiceTile(
                          service: const _Service('Plus', Icons.apps_rounded, Color(0xFF5E6E66)),
                          onTap: () => _showMore(context, open, shown),
                        ),
                      ],
                    ),
                  ),
                  if (canReports) const _SellersOfDay(),
                  const SizedBox(height: 22),
                  const _SectionTitle('À la une'),
                  const SizedBox(height: 10),
                  const PromoCarousel(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showMore(BuildContext context, void Function(_Service) open, List<_Service> shown) =>
      showModalBottomSheet<void>(
        useRootNavigator: true,
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (ctx) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Tous les services', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text('De nouveaux services arrivent régulièrement.', style: TextStyle(color: AppColors.muted)),
              const SizedBox(height: 14),
              GridView.count(
                crossAxisCount: 4,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 10,
                crossAxisSpacing: 4,
                childAspectRatio: 0.95,
                children: [
                  // Sans répéter les tuiles déjà sur l'accueil
                  for (final s in _moreServices.where((m) => !shown.any((x) => x.name == m.name)))
                    _ServiceTile(
                      service: s,
                      onTap: () {
                        Navigator.pop(ctx);
                        open(s);
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      );

  Future<void> _addExpense(BuildContext context, WidgetRef ref) async {
    final saved = await showModalBottomSheet<bool>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _ExpenseSheet(),
    );
    if (saved == true && context.mounted) {
      ref.invalidate(summaryProvider);
      showInfo(context, 'Dépense enregistrée');
    }
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Text(text, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, letterSpacing: -0.2)),
  );
}

/// En-tête : photo du monument du jour (repli : aurora émeraude), salutation,
/// caisse du jour en verre et barre de recherche qui chevauche le bas.
class _Hero extends StatelessWidget {
  const _Hero({this.name, this.business, required this.card});
  final String? name;
  final String? business;
  final Widget card;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    const onDarkMuted = Color(0xFFCDE9DD);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        ClipRRect(
          borderRadius: const BorderRadius.vertical(bottom: Radius.circular(36)),
          child: AuroraBackground(
            tone: AuroraTone.deep,
            child: Stack(
              children: [
                const Positioned.fill(child: MonumentBackdrop()),
                Padding(
                  padding: EdgeInsets.fromLTRB(16, top + 12, 16, 50),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          // Pas de logo ici : la photo du monument occupe l'en-tête.
                          const Spacer(),
                          const _Bell(),
                          const SizedBox(width: 8),
                          InkWell(
                            customBorder: const CircleBorder(),
                            onTap: () => context.push('/account'),
                            child: Container(
                              padding: const EdgeInsets.all(2.5),
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: LinearGradient(colors: [AppColors.glow, Color(0xFFFFC08A)]),
                              ),
                              child: const MeAvatar(size: 38),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              name == null ? 'Bonjour' : 'Bonjour, ${firstName(name!)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: onDarkMuted,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                shadows: [Shadow(color: Color(0x99000000), blurRadius: 8)],
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          const MonumentChip(),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Glass(
                          tone: GlassTone.dark,
                          radius: 30,
                          blur: 12,
                          shadow: false,
                          onTap: () => context.push('/business'),
                          padding: const EdgeInsets.fromLTRB(12, 7, 8, 7),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.storefront_rounded, size: 17, color: AppColors.glow),
                              const SizedBox(width: 7),
                              ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 220),
                                child: Text(
                                  business ?? '',
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 15,
                                  ),
                                ),
                              ),
                              const Icon(Icons.expand_more_rounded, size: 19, color: Colors.white),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      card,
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: -27,
          child: Glass(
            radius: 20,
            onTap: () => context.go('/pos'),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
            child: Row(
              children: [
                Icon(Icons.search_rounded, color: AppColors.green),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Rechercher un produit, un service…',
                    style: TextStyle(color: AppColors.muted, fontSize: 14),
                  ),
                ),
                const _ScanButton(),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Scanner un article depuis l'accueil : prix, stock, vendre ou ouvrir la fiche.
class _ScanButton extends ConsumerWidget {
  const _ScanButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) => Tooltip(
    message: 'Scanner un article',
    child: InkResponse(
      radius: 22,
      onTap: () => scanAndShowProduct(context, ref),
      child: Padding(
        padding: EdgeInsets.all(4),
        child: Icon(Icons.qr_code_scanner_rounded, color: AppColors.ink, size: 22),
      ),
    ),
  );
}

/// Cloche avec pastille du nombre de notifications non lues.
class _Bell extends ConsumerWidget {
  const _Bell();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(unreadNotificationsProvider).value ?? 0;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        _GlassIcon(
          tooltip: unread == 0 ? 'Notifications' : 'Notifications : $unread non lue${unread > 1 ? 's' : ''}',
          icon: unread == 0 ? Icons.notifications_none_rounded : Icons.notifications_active_rounded,
          onTap: () async {
            await context.push('/notifications');
            if (context.mounted) ref.invalidate(unreadNotificationsProvider);
          },
        ),
        if (unread > 0)
          Positioned(
            right: -3,
            top: -3,
            child: IgnorePointer(
              child: Container(
                constraints: const BoxConstraints(minWidth: 20),
                height: 20,
                padding: const EdgeInsets.symmetric(horizontal: 5),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xFFE5484D),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white, width: 1.6),
                ),
                child: Text(
                  unread > 99 ? '99+' : '$unread',
                  style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800, height: 1.1),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _GlassIcon extends StatelessWidget {
  const _GlassIcon({required this.tooltip, required this.icon, required this.onTap});
  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Semantics(
      button: true,
      label: tooltip,
      excludeSemantics: true,
      child: Glass(
        tone: GlassTone.dark,
        radius: 22,
        blur: 10,
        shadow: false,
        onTap: onTap,
        child: SizedBox(width: 44, height: 44, child: Icon(icon, color: Colors.white, size: 22)),
      ),
    ),
  );
}

/// Courbe des ventes des 7 derniers jours et tendance par rapport à la semaine d'avant.
class _WeekCurve extends StatelessWidget {
  const _WeekCurve({required this.summary});
  final DaySummary summary;

  @override
  Widget build(BuildContext context) {
    final t = weekTrend(summary.last7Days, summary.previous7DaysRevenue);
    final up = (t ?? 0) >= 0;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: SalesSparkline(values: summary.last7Days, color: AppColors.glow, height: 38),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            const Text('7 jours', style: TextStyle(fontSize: 11.5, color: _CashCard._muted)),
            const SizedBox(height: 2),
            Container(
              key: const Key('week_trend'),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: (t == null ? Colors.white : (up ? AppColors.glow : const Color(0xFFFFB4A8))).withValues(
                  alpha: 0.18,
                ),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (t != null)
                    Icon(
                      up ? Icons.trending_up_rounded : Icons.trending_down_rounded,
                      size: 14,
                      color: up ? AppColors.glow : const Color(0xFFFFB4A8),
                    ),
                  if (t != null) const SizedBox(width: 3),
                  Text(
                    t == null ? 'Nouveau' : trendLabel(t),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: t == null ? Colors.white : (up ? AppColors.glow : const Color(0xFFFFB4A8)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Carte « Caisse du jour » en verre sombre, avec reflet miroir qui la traverse.
class _CashCard extends ConsumerWidget {
  const _CashCard({required this.showFigures, required this.onExpense});
  final bool showFigures;
  final VoidCallback onExpense;

  static const _muted = Color(0xFFCDE9DD);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hidden = ref.watch(amountsHiddenProvider);
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _RoundAction(icon: Icons.add_rounded, label: 'Vendre', filled: true, onTap: () => context.go('/pos')),
        const SizedBox(width: 12),
        _RoundAction(icon: Icons.menu_book_rounded, label: 'Crédits', onTap: () => context.go('/customers?debt=1')),
        const SizedBox(width: 12),
        _RoundAction(icon: Icons.south_west_rounded, label: 'Dépense', onTap: onExpense),
      ],
    );

    return Sheen(
      radius: 28,
      child: Glass(
        tone: GlassTone.dark,
        radius: 28,
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(color: AppColors.glow.withValues(alpha: 0.18), shape: BoxShape.circle),
                  child: const Icon(Icons.point_of_sale_rounded, size: 15, color: AppColors.glow),
                ),
                const SizedBox(width: 8),
                const Flexible(
                  child: Text(
                    'Caisse du jour',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.w800, color: Colors.white),
                  ),
                ),
                const SizedBox(width: 4),
                const AmountsEye(color: _muted, size: 19),
                const Spacer(),
                Text(shortDate(DateTime.now()), style: const TextStyle(fontSize: 12, color: _muted)),
              ],
            ),
            const SizedBox(height: 12),
            if (!showFigures)
              // Vendeur : sa propre journée, sans coûts ni bénéfices
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: switch (ref.watch(myDayProvider)) {
                      AsyncData(:final value) => Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Mes ventes', style: TextStyle(fontSize: 12.5, color: _muted)),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              maskMoney(hidden, moneyShort(value.revenue)),
                              style: const TextStyle(
                                fontSize: 30,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.8,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          Text(
                            '${value.salesCount} vente${value.salesCount > 1 ? 's' : ''} aujourd’hui',
                            style: const TextStyle(fontSize: 12.5, color: _muted),
                          ),
                          const _PendingNote(),
                        ],
                      ),
                      _ => const Text(
                        'Prêt à encaisser ?',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Colors.white),
                      ),
                    },
                  ),
                  actions,
                ],
              )
            else
              AsyncView<DaySummary>(
                value: ref.watch(summaryProvider),
                onRetry: () => ref.invalidate(summaryProvider),
                loading: SizedBox(
                  height: 96,
                  child: Shimmer(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        Bone(width: 150, height: 30),
                        SizedBox(height: 10),
                        Bone(width: 110, height: 12),
                        SizedBox(height: 14),
                        Bone(height: 36, width: double.infinity, radius: 14),
                      ],
                    ),
                  ),
                ),
                data: (s) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: CountUp(
                                  value: s.revenue,
                                  builder: (context, shown) => Text.rich(
                                    TextSpan(
                                      children: [
                                        TextSpan(text: hidden ? hiddenAmount : moneyShort(shown).replaceAll(' F', '')),
                                        const TextSpan(
                                          text: ' F',
                                          style: TextStyle(fontSize: 17, color: _muted),
                                        ),
                                      ],
                                    ),
                                    style: const TextStyle(
                                      fontSize: 32,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: -0.8,
                                      color: Colors.white,
                                      fontFeatures: [FontFeature.tabularFigures()],
                                    ),
                                  ),
                                ),
                              ),
                              Text(
                                '${s.salesCount} vente${s.salesCount > 1 ? 's' : ''} aujourd’hui',
                                style: const TextStyle(fontSize: 12.5, color: _muted),
                              ),
                              const _PendingNote(),
                            ],
                          ),
                        ),
                        actions,
                      ],
                    ),
                    if (s.last7Days.length >= 2) ...[const SizedBox(height: 10), _WeekCurve(summary: s)],
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: _Figure(
                              label: 'Bénéfice',
                              value: maskMoney(hidden, moneyShort(s.netProfit)),
                              color: AppColors.glow,
                            ),
                          ),
                          Container(width: 1, height: 28, color: Colors.white.withValues(alpha: 0.18)),
                          Expanded(
                            child: _Figure(
                              label: 'À encaisser',
                              value: maskMoney(hidden, moneyShort(s.receivables)),
                              color: const Color(0xFFFFC28F),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Classement des vendeurs du jour (dès qu'au moins deux personnes ont vendu).
class _SellersOfDay extends ConsumerWidget {
  const _SellersOfDay();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sellers = ref.watch(summaryProvider).value?.bySeller ?? const [];
    if (sellers.length < 2) return const SizedBox.shrink();
    final best = sellers.first.revenue == 0 ? 1 : sellers.first.revenue;
    final repo = ref.read(repoProvider);
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(child: _SectionTitle('Vendeurs du jour')),
              TextButton(onPressed: () => context.push('/team'), child: const Text('Équipe')),
            ],
          ),
          const SizedBox(height: 6),
          Glass(
            radius: 22,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(
              children: [
                for (final (i, v) in sellers.take(4).indexed)
                  Padding(
                    padding: EdgeInsets.only(top: i == 0 ? 0 : 12),
                    child: Row(
                      children: [
                        Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Avatar(
                              name: v.name,
                              size: 40,
                              imageUrl: v.avatarFileId == null ? null : repo.fileUrl(v.avatarFileId!),
                            ),
                            if (i == 0)
                              const Positioned(
                                right: -4,
                                top: -6,
                                child: Icon(Icons.emoji_events_rounded, size: 18, color: AppColors.saffron),
                              ),
                          ],
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      v.name.startsWith('+221') ? '+221 ${displayPhone(v.name)}' : v.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontWeight: FontWeight.w800),
                                    ),
                                  ),
                                  Text(moneyShort(v.revenue), style: const TextStyle(fontWeight: FontWeight.w800)),
                                ],
                              ),
                              const SizedBox(height: 5),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: LinearProgressIndicator(
                                  value: v.revenue / best,
                                  minHeight: 6,
                                  backgroundColor: AppColors.line,
                                  color: i == 0 ? AppColors.green : AppColors.leaf.withValues(alpha: 0.7),
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                '${v.salesCount} vente${v.salesCount > 1 ? 's' : ''}',
                                style: TextStyle(fontSize: 12, color: AppColors.muted),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// « + 7 500 F en attente d'envoi » : ventes faites hors ligne, pas encore dans le total du serveur.
class _PendingNote extends ConsumerWidget {
  const _PendingNote();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final waiting = ref.watch(pendingForBusinessProvider).where((p) => !p.failed);
    if (waiting.isEmpty) return const SizedBox.shrink();
    final total = waiting.fold(0, (s, p) => s + p.total);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_upload_rounded, size: 14, color: Color(0xFFFFC28F)),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              '+ ${moneyShort(total)} en attente d’envoi',
              style: const TextStyle(fontSize: 12, color: Color(0xFFFFC28F), fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({required this.label, required this.value, required this.color});
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: Column(
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 11.5, color: _CashCard._muted, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: color),
        ),
      ],
    ),
  );
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({required this.icon, required this.label, required this.onTap, this.filled = false});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: InkWell(
      borderRadius: BorderRadius.circular(24),
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: filled
                  ? const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFFB4F8D6), AppColors.glow, Color(0xFF34C987)],
                    )
                  : null,
              color: filled ? null : Colors.white.withValues(alpha: 0.14),
              border: Border.all(color: Colors.white.withValues(alpha: filled ? 0.7 : 0.3)),
              boxShadow: filled
                  ? [
                      BoxShadow(
                        color: AppColors.glow.withValues(alpha: 0.45),
                        blurRadius: 16,
                        offset: const Offset(0, 5),
                      ),
                    ]
                  : null,
            ),
            child: Icon(icon, size: 23, color: filled ? AppColors.deep : Colors.white),
          ),
          const SizedBox(height: 5),
          ExcludeSemantics(
            child: Text(
              label,
              style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: Colors.white),
            ),
          ),
        ],
      ),
    ),
  );
}

class _ShopOrdersBanner extends StatelessWidget {
  const _ShopOrdersBanner({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) => Glass(
    radius: 18,
    tint: AppColors.leaf,
    onTap: () => context.push('/shop'),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    child: Row(
      children: [
        const GlossyOrb(icon: Icons.shopping_bag_rounded, color: Color(0xFF0E9384), size: 34),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            count == 1 ? '1 nouvelle commande en ligne' : '$count nouvelles commandes en ligne',
            style: TextStyle(color: AppColors.greenDark, fontWeight: FontWeight.w800),
          ),
        ),
        Text(
          'Voir',
          style: TextStyle(color: AppColors.greenDark, fontWeight: FontWeight.w800),
        ),
        Icon(Icons.chevron_right_rounded, color: AppColors.greenDark),
      ],
    ),
  );
}

class _LowStockBanner extends StatelessWidget {
  const _LowStockBanner({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) => Glass(
    radius: 18,
    tint: AppColors.saffron,
    onTap: () => context.go('/stock?low=1'),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    child: Row(
      children: [
        const GlossyOrb(icon: Icons.warning_amber_rounded, color: Color(0xFFE08A12), size: 34),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            count == 1 ? '1 produit en stock bas' : '$count produits en stock bas',
            style: TextStyle(color: AppColors.warnText, fontWeight: FontWeight.w800),
          ),
        ),
        Text(
          'Voir',
          style: TextStyle(color: AppColors.warnText, fontWeight: FontWeight.w800),
        ),
        Icon(Icons.chevron_right_rounded, color: AppColors.warnText),
      ],
    ),
  );
}

/// Tuile de service : verre givré, pastille brillante, libellé.
class _ServiceTile extends StatelessWidget {
  const _ServiceTile({required this.service, required this.onTap});
  final _Service service;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = AppColors.tone(
      Color.alphaBlend(service.color.withValues(alpha: 0.14), Colors.white),
      service.color,
    );
    return Semantics(
      button: true,
      label: service.soon ? '${service.name}, bientôt disponible' : service.name,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(17)),
                  child: Icon(service.icon, color: AppColors.isDark ? fg : service.color, size: 26),
                ),
                if (service.soon)
                  Positioned(
                    top: -6,
                    right: -10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                      decoration: BoxDecoration(color: AppColors.ink, borderRadius: BorderRadius.circular(6)),
                      child: Text(
                        'Bientôt',
                        style: TextStyle(color: AppColors.ground, fontSize: 8.5, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Text(
                service.name,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

const _expenseCategories = ['Transport', 'Loyer', 'Électricité', 'Salaire', 'Achat divers', 'Autre'];

class _ExpenseSheet extends ConsumerStatefulWidget {
  const _ExpenseSheet();
  @override
  ConsumerState<_ExpenseSheet> createState() => _ExpenseSheetState();
}

class _ExpenseSheetState extends ConsumerState<_ExpenseSheet> {
  final _amount = TextEditingController();
  String _category = _expenseCategories.first;
  bool _busy = false;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final amount = int.tryParse(_amount.text.replaceAll(' ', '')) ?? 0;
    if (amount <= 0) return;
    setState(() => _busy = true);
    try {
      await ref.read(repoProvider).addExpense(category: _category.toLowerCase(), amount: amount);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e);
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Nouvelle dépense', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final c in _expenseCategories)
              Pill(label: c, selected: _category == c, onTap: () => setState(() => _category = c)),
          ],
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _amount,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(labelText: 'Montant', suffixText: 'FCFA'),
        ),
        const SizedBox(height: 16),
        BusyButton(label: 'Enregistrer', busy: _busy, onPressed: _save),
      ],
    ),
  );
}
