import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../auth/auth_controller.dart';
import 'city_illustration.dart';

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
  _Service('Crédits', Icons.menu_book_rounded, Color(0xFF2F6FDB), route: '/customers'),
  _Service('Dépenses', Icons.account_balance_wallet_rounded, Color(0xFFE0533D), route: 'expense'),
  _Service('Factures', Icons.receipt_long_rounded, Color(0xFF7A5AF8), soon: true),
  _Service('Boutique', Icons.storefront_rounded, Color(0xFF0E9384), soon: true),
  _Service('Paiements', Icons.qr_code_2_rounded, Color(0xFF1D7AF0), soon: true),
];

/// Services des vagues 2 et 3, listés derrière « Plus ».
const _moreServices = [
  _Service('Documents', Icons.folder_rounded, Color(0xFF6B7280), soon: true),
  _Service('Livraison', Icons.local_shipping_rounded, Color(0xFFD9822B), soon: true),
  _Service('Réservation', Icons.event_available_rounded, Color(0xFF2F6FDB), soon: true),
  _Service('Assistant IA', Icons.auto_awesome_rounded, Color(0xFF7A5AF8), soon: true),
  _Service('Projets', Icons.task_alt_rounded, Color(0xFF0A8453), soon: true),
  _Service('Éducation', Icons.school_rounded, Color(0xFFE0533D), soon: true),
  _Service('Finances perso', Icons.savings_rounded, Color(0xFF0E9384), soon: true),
];

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider).value;
    final canReports = ref.can('reports:read');
    final canStock = ref.can('inventory:read');
    final lowStock = canStock ? ref.watch(stockProvider).value?.lowStock ?? 0 : 0;

    void open(_Service s) {
      if (s.soon) {
        showInfo(context, '${s.name} arrive bientôt sur Sama360');
      } else if (s.route == 'expense') {
        _addExpense(context, ref);
      } else {
        context.go(s.route!);
      }
    }

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async {
          refreshBusinessData(ref);
          ref.invalidate(currentBusinessProvider);
        },
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            _Hero(name: auth?.me?.fullName, business: auth?.business?.name),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _CashCard(showFigures: canReports, onExpense: () => _addExpense(context, ref)),
                  if (lowStock > 0) ...[const SizedBox(height: 12), _LowStockBanner(count: lowStock)],
                  const SizedBox(height: 14),
                  GridView.count(
                    crossAxisCount: 4,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 0.82,
                    children: [
                      for (final s in _mainServices) _ServiceTile(service: s, onTap: () => open(s)),
                      _ServiceTile(
                        service: const _Service('Plus', Icons.apps_rounded, Color(0xFF0A8453)),
                        onTap: () => _showMore(context, open),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const _ProBanner(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showMore(BuildContext context, void Function(_Service) open) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Tous les services', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          const Text('De nouveaux services arrivent régulièrement.', style: TextStyle(color: AppColors.muted)),
          const SizedBox(height: 14),
          GridView.count(
            crossAxisCount: 4,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 0.82,
            children: [
              for (final s in _moreServices)
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

/// Logo : pastille dégradée + mot « Sama360 ».
class _Brand extends StatelessWidget {
  const _Brand();
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 30,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [AppColors.leaf, AppColors.green], begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Text('S', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 17)),
      ),
      const SizedBox(width: 8),
      const SamaLogo(size: 22),
    ],
  );
}

/// En-tête : dégradé clair, logo, entreprise, avatar, illustration, recherche qui chevauche.
class _Hero extends StatelessWidget {
  const _Hero({this.name, this.business});
  final String? name;
  final String? business;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          padding: EdgeInsets.only(top: top + 12),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFFD3F0E1), Color(0xFFEAF8F0), AppColors.ground],
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    const _Brand(),
                    const Spacer(),
                    IconButton.filledTonal(
                      tooltip: 'Notifications',
                      style: IconButton.styleFrom(backgroundColor: Colors.white.withValues(alpha: 0.8)),
                      onPressed: () => showInfo(context, 'Notifications bientôt disponibles'),
                      icon: const Icon(Icons.notifications_none_rounded, color: AppColors.ink),
                    ),
                    const SizedBox(width: 6),
                    InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => context.go('/account'),
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                        child: Avatar(name: name, size: 38),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Material(
                    color: Colors.white.withValues(alpha: 0.85),
                    shape: const StadiumBorder(),
                    child: InkWell(
                      customBorder: const StadiumBorder(),
                      onTap: () => context.push('/business'),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.storefront_rounded, size: 16, color: AppColors.green),
                            const SizedBox(width: 6),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 220),
                              child: Text(
                                business ?? '',
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
                              ),
                            ),
                            const Icon(Icons.expand_more_rounded, size: 18),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              const CityIllustration(height: 132),
              const SizedBox(height: 22),
            ],
          ),
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: -6,
          child: Material(
            color: Colors.white,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: AppColors.line),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => context.go('/pos'),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                child: Row(
                  children: [
                    Icon(Icons.search_rounded, color: AppColors.ink),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text('Rechercher un produit, un service…', style: TextStyle(color: AppColors.muted, fontSize: 14)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Carte « Caisse du jour », façon portefeuille : montant + actions rondes.
class _CashCard extends ConsumerWidget {
  const _CashCard({required this.showFigures, required this.onExpense});
  final bool showFigures;
  final VoidCallback onExpense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _RoundAction(icon: Icons.add_rounded, label: 'Vendre', filled: true, onTap: () => context.go('/pos')),
        const SizedBox(width: 12),
        _RoundAction(icon: Icons.menu_book_rounded, label: 'Crédits', onTap: () => context.go('/customers')),
        const SizedBox(width: 12),
        _RoundAction(icon: Icons.more_horiz_rounded, label: 'Dépense', onTap: onExpense),
      ],
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppColors.line),
        gradient: const LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [Colors.white, Colors.white, Color(0xFFE2F6EB)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.point_of_sale_rounded, size: 18, color: AppColors.green),
              const SizedBox(width: 6),
              const Text('Caisse du jour', style: TextStyle(fontWeight: FontWeight.w800, color: AppColors.green)),
              const Spacer(),
              Text(shortDate(DateTime.now()), style: const TextStyle(fontSize: 12, color: AppColors.muted)),
            ],
          ),
          const SizedBox(height: 10),
          if (!showFigures)
            Row(
              children: [
                const Expanded(
                  child: Text('Prêt à encaisser ?', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                ),
                actions,
              ],
            )
          else
            AsyncView<DaySummary>(
              value: ref.watch(summaryProvider),
              onRetry: () => ref.invalidate(summaryProvider),
              loading: const SizedBox(height: 96, child: Center(child: CircularProgressIndicator())),
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
                              child: Text.rich(
                                TextSpan(
                                  children: [
                                    TextSpan(text: moneyShort(s.revenue).replaceAll(' F', '')),
                                    const TextSpan(text: ' F', style: TextStyle(fontSize: 16, color: AppColors.muted)),
                                  ],
                                ),
                                style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -0.5),
                              ),
                            ),
                            Text('${s.salesCount} vente${s.salesCount > 1 ? 's' : ''} aujourd’hui',
                                style: const TextStyle(fontSize: 12, color: AppColors.muted)),
                          ],
                        ),
                      ),
                      actions,
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(child: _Figure(label: 'Bénéfice', value: moneyShort(s.netProfit))),
                      Container(width: 1, height: 28, color: AppColors.line),
                      Expanded(
                        child: _Figure(label: 'À encaisser', value: moneyShort(s.receivables), color: const Color(0xFFB54A00)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({required this.label, required this.value, this.color = AppColors.ink});
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: Column(
      children: [
        Text(label, style: const TextStyle(fontSize: 11, color: AppColors.muted, fontWeight: FontWeight.w600)),
        const SizedBox(height: 2),
        Text(value, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: color)),
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
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: filled ? AppColors.green : Colors.white,
              border: filled ? null : Border.all(color: AppColors.line),
            ),
            child: Icon(icon, size: 22, color: filled ? Colors.white : AppColors.ink),
          ),
          const SizedBox(height: 4),
          ExcludeSemantics(child: Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700))),
        ],
      ),
    ),
  );
}

class _LowStockBanner extends StatelessWidget {
  const _LowStockBanner({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) => Material(
    color: AppColors.warnBg,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
      side: const BorderSide(color: AppColors.warnLine),
    ),
    child: InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => context.go('/stock?low=1'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: AppColors.warn, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                count == 1 ? '1 produit en stock bas' : '$count produits en stock bas',
                style: const TextStyle(color: AppColors.warnText, fontWeight: FontWeight.w700),
              ),
            ),
            const Text('Voir', style: TextStyle(color: AppColors.warnText, fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    ),
  );
}

/// Tuile de service : carte blanche, pastille d'icône colorée, libellé.
class _ServiceTile extends StatelessWidget {
  const _ServiceTile({required this.service, required this.onTap});
  final _Service service;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = service.color;
    return Semantics(
      button: true,
      label: service.soon ? '${service.name}, bientôt disponible' : service.name,
      child: Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: AppColors.line),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Stack(
            children: [
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [c.withValues(alpha: 0.10), c.withValues(alpha: 0.24)],
                        ),
                      ),
                      child: Icon(service.icon, color: c, size: 24),
                    ),
                    const SizedBox(height: 8),
                    ExcludeSemantics(
                      child: Text(
                        service.name,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              ),
              if (service.soon)
                Positioned(
                  top: 6,
                  right: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(color: AppColors.ink, borderRadius: BorderRadius.circular(6)),
                    child: const ExcludeSemantics(
                      child: Text('Bientôt', style: TextStyle(color: Colors.white, fontSize: 8.5, fontWeight: FontWeight.w700)),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bannière promotionnelle (offre Pro).
class _ProBanner extends StatelessWidget {
  const _ProBanner();

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => showInfo(context, 'Les offres Sama360 Pro arrivent bientôt'),
      child: Ink(
        padding: const EdgeInsets.fromLTRB(16, 16, 12, 16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: const LinearGradient(colors: [Color(0xFFFFF1E2), Color(0xFFFFDDBF)]),
        ),
        child: Row(
          children: [
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Passez à Sama360 Pro', style: TextStyle(color: Color(0xFF8A3A00), fontSize: 16, fontWeight: FontWeight.w800)),
                  SizedBox(height: 4),
                  Text(
                    'Plusieurs vendeurs, factures illimitées et rapports détaillés.',
                    style: TextStyle(color: Color(0xFF5C2E0B), fontSize: 12.5, height: 1.3),
                  ),
                  SizedBox(height: 10),
                  Text('Découvrir →', style: TextStyle(color: Color(0xFF8A3A00), fontWeight: FontWeight.w800, fontSize: 13)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0x33FF8A3D)),
              child: const Icon(Icons.rocket_launch_rounded, size: 38, color: AppColors.orange),
            ),
          ],
        ),
      ),
    ),
  );
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
            for (final c in _expenseCategories) Pill(label: c, selected: _category == c, onTap: () => setState(() => _category = c)),
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
