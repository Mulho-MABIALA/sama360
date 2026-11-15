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

class _Service {
  const _Service(this.name, this.icon, {this.route, this.soon = false});
  final String name;
  final IconData icon;
  final String? route;
  final bool soon;
}

const _services = [
  _Service('Ventes', Icons.point_of_sale_rounded, route: '/pos'),
  _Service('Stock', Icons.inventory_2_outlined, route: '/stock'),
  _Service('Clients', Icons.people_alt_outlined, route: '/customers'),
  _Service('Dépenses', Icons.payments_outlined, route: 'expense'),
  _Service('Factures', Icons.description_outlined, soon: true),
  _Service('Boutique', Icons.storefront_outlined, soon: true),
  _Service('Paiements', Icons.qr_code_2_rounded, soon: true),
  _Service('Documents', Icons.folder_outlined, soon: true),
  _Service('Livraison', Icons.local_shipping_outlined, soon: true),
  _Service('Réservation', Icons.event_outlined, soon: true),
  _Service('Assistant IA', Icons.auto_awesome_outlined, soon: true),
  _Service('Projets', Icons.task_alt_rounded, soon: true),
];

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider).value;
    final canReports = ref.can('reports:read');
    final canStock = ref.can('inventory:read');
    final lowStock = canStock ? ref.watch(stockProvider).value?.lowStock ?? 0 : 0;

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            refreshBusinessData(ref);
            ref.invalidate(currentBusinessProvider);
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            children: [
              _Header(name: auth?.me?.fullName, business: auth?.business?.name),
              const SizedBox(height: 18),
              if (canReports) ...[const _SummaryCard(), const SizedBox(height: 18)],
              _QuickActions(onExpense: () => _addExpense(context, ref)),
              if (lowStock > 0) ...[
                const SizedBox(height: 16),
                _LowStockBanner(count: lowStock),
              ],
              const SizedBox(height: 22),
              const Text('Mes services', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
              const SizedBox(height: 12),
              GridView.count(
                crossAxisCount: 4,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 14,
                crossAxisSpacing: 8,
                childAspectRatio: 0.9,
                children: [
                  for (final s in _services)
                    _ServiceTile(
                      service: s,
                      onTap: () {
                        if (s.soon) {
                          showInfo(context, '${s.name} arrive bientôt sur Sama360');
                        } else if (s.route == 'expense') {
                          _addExpense(context, ref);
                        } else {
                          context.go(s.route!);
                        }
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

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

class _Header extends ConsumerWidget {
  const _Header({this.name, this.business});
  final String? name;
  final String? business;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Row(
    children: [
      Avatar(name: name),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Bonjour ${firstName(name)}', style: const TextStyle(fontSize: 13, color: AppColors.muted)),
            InkWell(
              onTap: () => context.push('/business'),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      business ?? '',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                    ),
                  ),
                  const Icon(Icons.expand_more, size: 20),
                ],
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

class _SummaryCard extends ConsumerWidget {
  const _SummaryCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(summaryProvider);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: AppColors.green, borderRadius: BorderRadius.circular(22)),
      child: DefaultTextStyle.merge(
        style: const TextStyle(color: Colors.white),
        child: AsyncView<DaySummary>(
          value: summary,
          onRetry: () => ref.invalidate(summaryProvider),
          loading: const SizedBox(height: 132, child: Center(child: CircularProgressIndicator(color: Colors.white))),
          data: (s) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("Aujourd'hui · ${longDate(DateTime.now())}", style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              const Text("Chiffre d'affaires", style: TextStyle(fontSize: 12)),
              Text(money(s.revenue), style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: Colors.white)),
              const SizedBox(height: 12),
              Row(
                children: [
                  _Mini(label: 'Ventes', value: '${s.salesCount}'),
                  const SizedBox(width: 8),
                  _Mini(label: 'Bénéfice', value: moneyShort(s.netProfit)),
                  const SizedBox(width: 8),
                  _Mini(label: 'À encaisser', value: moneyShort(s.receivables), highlight: true),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Mini extends StatelessWidget {
  const _Mini({required this.label, required this.value, this.highlight = false});
  final String label;
  final String value;
  final bool highlight;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: highlight ? AppColors.saffron : Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: highlight ? const Color(0xFF2A1A00) : Colors.white)),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: highlight ? const Color(0xFF2A1A00) : Colors.white),
            ),
          ),
        ],
      ),
    ),
  );
}

class _QuickActions extends StatelessWidget {
  const _QuickActions({required this.onExpense});
  final VoidCallback onExpense;

  @override
  Widget build(BuildContext context) {
    Widget action(String label, IconData icon, VoidCallback onTap, {bool primary = false}) => Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Column(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: primary ? AppColors.ink : Colors.white,
                border: primary ? null : Border.all(color: AppColors.line),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Icon(icon, color: primary ? Colors.white : AppColors.green),
            ),
            const SizedBox(height: 6),
            Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );

    return Row(
      children: [
        action('Nouvelle vente', Icons.add, () => context.go('/pos'), primary: true),
        action('Stock', Icons.inventory_2_outlined, () => context.go('/stock')),
        action('Crédits', Icons.menu_book_outlined, () => context.go('/customers')),
        action('Dépense', Icons.payments_outlined, onExpense),
      ],
    );
  }
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
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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

class _ServiceTile extends StatelessWidget {
  const _ServiceTile({required this.service, required this.onTap});
  final _Service service;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final soon = service.soon;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Column(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: soon ? const Color(0xFFECEAE4) : AppColors.greenSoft,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(service.icon, color: soon ? const Color(0xFF7A847F) : AppColors.green),
              ),
              const SizedBox(height: 6),
              Text(
                service.name,
                textAlign: TextAlign.center,
                maxLines: 2,
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: soon ? AppColors.muted : AppColors.ink),
              ),
            ],
          ),
          if (soon)
            Positioned(
              top: -6,
              right: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(color: AppColors.ink, borderRadius: BorderRadius.circular(6)),
                child: const Text('Bientôt', style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w700)),
              ),
            ),
        ],
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
