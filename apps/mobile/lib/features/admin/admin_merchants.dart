import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/admin_models.dart';
import '../../core/countries.dart';
import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import 'admin_widgets.dart';

/// Back office : tous les commerçants, avec recherche, filtres et tri.
class AdminMerchantsScreen extends ConsumerStatefulWidget {
  const AdminMerchantsScreen({super.key, this.initial = const AdminBusinessQuery()});
  final AdminBusinessQuery initial;
  @override
  ConsumerState<AdminMerchantsScreen> createState() => _AdminMerchantsScreenState();
}

class _AdminMerchantsScreenState extends ConsumerState<AdminMerchantsScreen> {
  late AdminBusinessQuery _q = widget.initial;
  final _search = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) setState(() => _q = _q.copyWith(search: v));
    });
  }

  static const _sorts = {
    'recent': 'Plus récentes',
    'activity': 'Dernière vente',
    'revenue': 'Ventes (30 j)',
    'name': 'Nom',
  };

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= adminWide;
    final pad = wide ? 28.0 : 16.0;
    final data = ref.watch(adminBusinessesProvider(_q));
    return AdminShell(
      section: AdminSection.merchants,
      title: 'Commerçants',
      subtitle: data.value == null ? null : '${data.value!.total} boutique${data.value!.total > 1 ? 's' : ''}',
      actions: [
        PopupMenuButton<String>(
          key: const Key('admin_sort'),
          tooltip: 'Trier',
          initialValue: _q.sort,
          onSelected: (s) => setState(() => _q = _q.copyWith(sort: s)),
          itemBuilder: (_) => [for (final e in _sorts.entries) PopupMenuItem(value: e.key, child: Text(e.value))],
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.sort_rounded, size: 20),
                if (wide) ...[const SizedBox(width: 6), Text(_sorts[_q.sort]!)],
              ],
            ),
          ),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: pad),
            child: TextField(
              key: const Key('admin_search'),
              controller: _search,
              onChanged: _onSearch,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Nom de la boutique, propriétaire ou numéro',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Effacer',
                        onPressed: () {
                          _search.clear();
                          setState(() => _q = _q.copyWith(search: ''));
                        },
                        icon: const Icon(Icons.close_rounded),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: pad),
            child: Row(
              children: [
                _chip('Toutes', _q.plan == null && _q.status == null, () {
                  setState(() => _q = _q.copyWith(plan: () => null, status: () => null));
                }),
                for (final p in AdminPlan.values)
                  _chip(p.label, _q.plan == p, () {
                    setState(() => _q = _q.copyWith(plan: () => _q.plan == p ? null : p, status: () => null));
                  }, key: 'admin_plan_${p.name}'),
                for (final s in [AdminStatus.suspended, AdminStatus.deleted])
                  _chip(s == AdminStatus.suspended ? 'Suspendues' : 'Supprimées', _q.status == s, () {
                    setState(() => _q = _q.copyWith(status: () => _q.status == s ? null : s, plan: () => null));
                  }, key: 'admin_status_${s.name}'),
                const SizedBox(width: 6),
                for (final c in Country.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FilterChip(
                      key: Key('admin_country_${c.code}'),
                      avatar: CountryFlag(c, width: 18),
                      label: Text(c.code),
                      tooltip: c.name,
                      selected: _q.country == c,
                      onSelected: (_) => setState(() => _q = _q.copyWith(country: () => _q.country == c ? null : c)),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: AsyncView<AdminPage<AdminBusiness>>(
              value: data,
              onRetry: () => ref.invalidate(adminBusinessesProvider(_q)),
              data: (page) => page.items.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.storefront_outlined, size: 44, color: AppColors.muted),
                          const SizedBox(height: 8),
                          Text(
                            'Aucune boutique',
                            style: TextStyle(color: AppColors.muted, fontWeight: FontWeight.w700),
                          ),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: () => ref.refresh(adminBusinessesProvider(_q).future),
                      child: ListView(
                        padding: EdgeInsets.fromLTRB(pad, 0, pad, wide ? 32 : 110),
                        children: [
                          if (wide) const _TableHeader(),
                          for (final b in page.items)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: wide ? _Row(b: b) : _Card(b: b),
                            ),
                          if (page.total > page.pageSize)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  IconButton(
                                    tooltip: 'Page précédente',
                                    onPressed: page.page > 1
                                        ? () => setState(() => _q = _q.copyWith(page: page.page - 1))
                                        : null,
                                    icon: const Icon(Icons.chevron_left_rounded),
                                  ),
                                  Text(
                                    'Page ${page.page} / ${(page.total / page.pageSize).ceil()}',
                                    style: const TextStyle(fontWeight: FontWeight.w700),
                                  ),
                                  IconButton(
                                    tooltip: 'Page suivante',
                                    onPressed: page.hasMore
                                        ? () => setState(() => _q = _q.copyWith(page: page.page + 1))
                                        : null,
                                    icon: const Icon(Icons.chevron_right_rounded),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap, {String? key}) => Padding(
    padding: const EdgeInsets.only(right: 6),
    child: Pill(key: key == null ? null : Key(key), label: label, selected: selected, onTap: onTap),
  );
}

const _cols = [3.2, 1.6, 1.3, 1.4, 1.3];

class _TableHeader extends StatelessWidget {
  const _TableHeader();
  @override
  Widget build(BuildContext context) {
    final s = TextStyle(color: AppColors.muted, fontSize: 12, fontWeight: FontWeight.w700);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
      child: Row(
        children: [
          for (final (i, t) in ['Boutique', 'Abonnement', 'Ventes 30 j', 'Dernière vente', 'Inscrite'].indexed)
            Expanded(
              flex: (_cols[i] * 10).round(),
              child: Text(t, style: s),
            ),
          const SizedBox(width: 24),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.b});
  final AdminBusiness b;
  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(color: AppColors.muted, fontSize: 12.5);
    return Glass(
      key: Key('admin_biz_${b.id}'),
      radius: 18,
      blur: 10,
      onTap: () => context.push('/admin/merchants/${b.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            flex: (_cols[0] * 10).round(),
            child: Row(
              children: [
                ShopAvatar(b.name, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              b.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5),
                            ),
                          ),
                          const SizedBox(width: 6),
                          CountryFlag(b.country, width: 16),
                          const SizedBox(width: 6),
                          StatusBadge(b.status),
                        ],
                      ),
                      Text(
                        '${b.ownerName ?? 'Sans nom'} · ${intlPhone(b.ownerPhone)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: muted,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            flex: (_cols[1] * 10).round(),
            child: Align(
              alignment: Alignment.centerLeft,
              child: PlanBadge(b.plan, daysLeft: b.daysLeft),
            ),
          ),
          Expanded(
            flex: (_cols[2] * 10).round(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(moneyShort(b.revenue30), style: const TextStyle(fontWeight: FontWeight.w800)),
                Text('${b.sales30} vente${b.sales30 > 1 ? 's' : ''}', style: muted),
              ],
            ),
          ),
          Expanded(
            flex: (_cols[3] * 10).round(),
            child: Row(
              children: [
                _Dot(active: b.sales7 > 0),
                const SizedBox(width: 6),
                Text(sinceLabel(b.lastSaleAt), style: const TextStyle(fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          Expanded(
            flex: (_cols[4] * 10).round(),
            child: Text(DateFormat('d MMM y', 'fr').format(b.createdAt), style: muted),
          ),
          Icon(Icons.chevron_right_rounded, color: AppColors.muted),
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.active});
  final bool active;
  @override
  Widget build(BuildContext context) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: active ? const Color(0xFF16A34A) : AppColors.muted.withValues(alpha: 0.5),
    ),
  );
}

class _Card extends StatelessWidget {
  const _Card({required this.b});
  final AdminBusiness b;
  @override
  Widget build(BuildContext context) => Glass(
    key: Key('admin_biz_${b.id}'),
    radius: 20,
    blur: 10,
    onTap: () => context.push('/admin/merchants/${b.id}'),
    padding: const EdgeInsets.all(14),
    child: Row(
      children: [
        ShopAvatar(b.name),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      b.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                    ),
                  ),
                  const SizedBox(width: 6),
                  CountryFlag(b.country, width: 16),
                ],
              ),
              Text(
                [intlPhone(b.ownerPhone), ?b.ownerName].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: AppColors.muted, fontSize: 12.5),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  PlanBadge(b.plan, daysLeft: b.daysLeft),
                  StatusBadge(b.status),
                  _Dot(active: b.sales7 > 0),
                  Text('vente ${sinceLabel(b.lastSaleAt)}', style: TextStyle(color: AppColors.muted, fontSize: 12)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(compactMoney(b.revenue30), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15)),
            Text('30 jours', style: TextStyle(color: AppColors.muted, fontSize: 11.5)),
          ],
        ),
      ],
    ),
  );
}
