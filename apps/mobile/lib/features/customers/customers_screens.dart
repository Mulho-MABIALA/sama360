import 'dart:async';

import 'package:flutter/services.dart';
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
import '../sales/receipt_screen.dart' show receiptActionsProvider, whatsAppUri;
import 'statement_pdf.dart';

/// « aujourd'hui », « hier », « il y a 5 j »
String sinceText(DateTime d, [DateTime? now]) {
  final n = now ?? DateTime.now();
  final days = DateTime(
    n.year,
    n.month,
    n.day,
  ).difference(DateTime(d.toLocal().year, d.toLocal().month, d.toLocal().day)).inDays;
  if (days <= 0) return 'aujourd’hui';
  if (days == 1) return 'hier';
  return 'il y a $days j';
}

enum ReminderTone {
  gentle('Aimable'),
  firm('Ferme'),
  detailed('Avec le détail');

  const ReminderTone(this.label);
  final String label;
}

/// Message de rappel de paiement, prêt à envoyer par WhatsApp ou SMS.
String reminderText(CustomerOverview o, String business, {ReminderTone tone = ReminderTone.gentle, DateTime? now}) {
  final name = firstName(o.customer.name);
  final due = moneyShort(o.balance);
  final since = o.oldestUnpaidAt == null ? null : DateFormat('d MMMM', 'fr').format(o.oldestUnpaidAt!.toLocal());
  switch (tone) {
    case ReminderTone.gentle:
      return 'Bonjour $name, c’est $business. Petit rappel : il vous reste $due à régler. '
          'Vous pouvez payer en boutique, par Wave ou Orange Money. Merci et bonne journée !';
    case ReminderTone.firm:
      final age = o.debtAgeDays(now);
      return 'Bonjour $name, $business vous rappelle que votre solde de $due est en attente'
          '${since == null ? '' : ' depuis le $since${age != null && age > 1 ? ' ($age jours)' : ''}'}. '
          'Merci de le régler au plus vite.';
    case ReminderTone.detailed:
      final debts = o.entries.where((e) => e.type == 'debt').take(5).toList();
      final lines = [
        for (final e in debts) '• ${DateFormat('d MMM', 'fr').format(e.at.toLocal())} : ${moneyShort(e.amount)}',
      ];
      return [
        'Bonjour $name, voici votre compte chez $business :',
        ...lines,
        'Reste à payer : $due.',
        'Merci de régler dès que possible.',
      ].join('\n');
  }
}

// =====================================================================
// Annuaire clients
// =====================================================================

/// Clients : tout l'annuaire, ceux qui doivent de l'argent, ceux qui dépassent leur plafond.
class CustomersScreen extends ConsumerStatefulWidget {
  const CustomersScreen({super.key, this.initialFilter = CustomerFilter.all});
  final CustomerFilter initialFilter;
  @override
  ConsumerState<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends ConsumerState<CustomersScreen> {
  late CustomerFilter _filter = widget.initialFilter;
  CustomerSort _sort = CustomerSort.name;
  String _search = '';
  Timer? _debounce;

  CustomerQuery get _query => (search: _search, filter: _filter, sort: _sort);

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _setFilter(CustomerFilter f) => setState(() {
    _filter = f;
    // Le tri par dette a du sens dès qu'on regarde les débiteurs
    if (f != CustomerFilter.all && _sort == CustomerSort.name) _sort = CustomerSort.balance;
    if (f == CustomerFilter.all && _sort == CustomerSort.balance) _sort = CustomerSort.name;
  });

  @override
  Widget build(BuildContext context) {
    final list = ref.watch(customerListProvider(_query));
    final canWrite = ref.watch(canProvider('contacts:write'));
    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Clients', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          PopupMenuButton<CustomerSort>(
            tooltip: 'Trier',
            icon: const Icon(Icons.sort_rounded),
            initialValue: _sort,
            onSelected: (s) => setState(() => _sort = s),
            itemBuilder: (_) => [
              for (final s in CustomerSort.values)
                CheckedPopupMenuItem(value: s, checked: s == _sort, child: Text(s.label)),
            ],
          ),
        ],
      ),
      floatingActionButton: canWrite
          ? FloatingActionButton.extended(
              heroTag: 'newCustomer',
              onPressed: () => context.push('/customers/new'),
              icon: const Icon(Icons.person_add_alt_1_rounded),
              label: const Text('Nouveau client'),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(customerListProvider),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
          children: [
            _TotalsCard(totals: list.value?.totals, onFilter: _setFilter),
            const SizedBox(height: 12),
            TextField(
              key: const Key('customerSearch'),
              decoration: const InputDecoration(
                hintText: 'Rechercher un nom ou un numéro',
                prefixIcon: Icon(Icons.search),
                isDense: true,
              ),
              onChanged: (v) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 300), () {
                  if (mounted) setState(() => _search = v.trim());
                });
              },
            ),
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final f in CustomerFilter.values) ...[
                    Pill(label: f.label, selected: _filter == f, onTap: () => _setFilter(f)),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 10),
            AsyncView<CustomerList>(
              value: list,
              onRetry: () => ref.invalidate(customerListProvider(_query)),
              data: (l) {
                if (l.data.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 40),
                    child: Column(
                      children: [
                        Icon(Icons.people_outline_rounded, size: 44, color: AppColors.muted),
                        const SizedBox(height: 8),
                        Text(
                          _search.isNotEmpty
                              ? 'Aucun client ne correspond à « $_search »'
                              : switch (_filter) {
                                  CustomerFilter.debt => 'Personne ne vous doit d’argent',
                                  CustomerFilter.overLimit => 'Aucun client au-dessus de son plafond',
                                  CustomerFilter.all => 'Ajoutez votre premier client',
                                },
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppColors.muted),
                        ),
                      ],
                    ),
                  );
                }
                return Column(
                  children: [
                    for (final c in l.data)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _CustomerTile(c: c),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _TotalsCard extends StatelessWidget {
  const _TotalsCard({required this.totals, required this.onFilter});
  final CustomerTotals? totals;
  final ValueChanged<CustomerFilter> onFilter;

  static const _muted = Color(0xFFCDE9DD);

  @override
  Widget build(BuildContext context) {
    final t = totals ?? const CustomerTotals();
    return Sheen(
      radius: 26,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: AuroraBackground(
          tone: AuroraTone.deep,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const LabelWithEye('Total à encaisser', style: TextStyle(color: _muted, fontSize: 12.5)),
                MaskedText(
                  money(t.totalDue),
                  style: const TextStyle(
                    color: Color(0xFFFFC28F),
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.6,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _Mini(label: 'Clients', value: '${t.customers}', onTap: () => onFilter(CustomerFilter.all)),
                    _Mini(label: 'Doivent', value: '${t.debtors}', onTap: () => onFilter(CustomerFilter.debt)),
                    _Mini(
                      label: 'Plafond dépassé',
                      value: '${t.overLimit}',
                      alert: t.overLimit > 0,
                      onTap: () => onFilter(CustomerFilter.overLimit),
                    ),
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

class _Mini extends StatelessWidget {
  const _Mini({required this.label, required this.value, required this.onTap, this.alert = false});
  final String label;
  final String value;
  final VoidCallback onTap;
  final bool alert;

  @override
  Widget build(BuildContext context) => Expanded(
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              value,
              style: TextStyle(
                color: alert ? const Color(0xFFFFC28F) : Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            Text(label, style: const TextStyle(color: _TotalsCard._muted, fontSize: 11.5)),
          ],
        ),
      ),
    ),
  );
}

class _CustomerTile extends StatelessWidget {
  const _CustomerTile({required this.c});
  final CustomerRow c;

  @override
  Widget build(BuildContext context) {
    final owes = c.balance > 0;
    final subtitle = owes && c.firstDebtAt != null
        ? 'Doit depuis le ${shortDate(c.firstDebtAt!)}'
        : c.salesCount == 0
        ? (c.phone == null ? 'Aucun achat' : displayPhone(c.phone!))
        : '${c.salesCount} achat${c.salesCount > 1 ? 's' : ''} · dernier ${sinceText(c.lastPurchaseAt!)}';
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        leading: Avatar(
          name: c.name,
          size: 42,
          bg: owes ? AppColors.warnBg : AppColors.greenSoft,
          fg: owes ? AppColors.warnText : AppColors.green,
        ),
        title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              owes ? money(c.balance) : (c.totalSpent > 0 ? moneyShort(c.totalSpent) : ''),
              style: TextStyle(
                fontWeight: owes ? FontWeight.w800 : FontWeight.w600,
                color: owes ? AppColors.warn : AppColors.muted,
              ),
            ),
            if (c.overLimit)
              Text(
                'Plafond dépassé',
                style: TextStyle(fontSize: 11, color: AppColors.danger, fontWeight: FontWeight.w700),
              ),
          ],
        ),
        onTap: () => context.push('/customers/${c.id}'),
      ),
    );
  }
}

// =====================================================================
// Fiche client
// =====================================================================

/// Fiche client : coordonnées, solde et plafond, achats, carnet de crédit et actions.
class CustomerScreen extends ConsumerStatefulWidget {
  const CustomerScreen({super.key, required this.customerId});
  final String customerId;
  @override
  ConsumerState<CustomerScreen> createState() => _CustomerScreenState();
}

class _CustomerScreenState extends ConsumerState<CustomerScreen> {
  bool _purchases = false; // onglet : carnet de crédit / achats
  bool _exporting = false;

  Future<bool> _open(Uri uri) async {
    final ok = await ref.read(receiptActionsProvider).openWhatsApp(uri);
    if (!ok && mounted) showInfo(context, 'Impossible d’ouvrir l’application');
    return ok;
  }

  Future<void> _statement(CustomerOverview o) async {
    setState(() => _exporting = true);
    try {
      final b = await ref.read(currentBusinessProvider.future);
      final logo = b.logoFileId == null ? null : await ref.read(repoProvider).fileBytes(b.logoFileId!);
      final bytes = await buildStatementPdf(o, b, logo: logo);
      await ref.read(receiptActionsProvider).sharePdf(bytes, statementFileName(o));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _repay(CustomerOverview o) async {
    final done = await showModalBottomSheet<bool>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _RepaySheet(customerId: o.customer.id, balance: o.balance),
    );
    if (done == true && mounted) {
      refreshBusinessData(ref);
      showInfo(context, 'Remboursement enregistré');
    }
  }

  Future<void> _remind(CustomerOverview o) async {
    final business = (await ref.read(currentBusinessProvider.future)).name;
    if (!mounted) return;
    final sent = await showModalBottomSheet<bool>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ReminderSheet(overview: o, business: business, open: _open),
    );
    if (sent == true && mounted) ref.invalidate(customerOverviewProvider(o.customer.id));
  }

  Future<void> _adjust(CustomerOverview o) async {
    final done = await showModalBottomSheet<bool>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _AdjustSheet(customerId: o.customer.id, balance: o.balance),
    );
    if (done == true && mounted) {
      refreshBusinessData(ref);
      showInfo(context, 'Solde mis à jour');
    }
  }

  @override
  Widget build(BuildContext context) {
    final overview = ref.watch(customerOverviewProvider(widget.customerId));
    final canWrite = ref.watch(canProvider('contacts:write'));
    final canAdjust = ref.watch(canProvider('sales:void'));
    final canRepay = ref.watch(canProvider('sales:create'));
    final o = overview.value;
    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Fiche client', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          if (canWrite && o != null)
            IconButton(
              tooltip: 'Modifier',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => context.push('/customers/${widget.customerId}/edit'),
            ),
          if (o != null)
            PopupMenuButton<String>(
              tooltip: 'Plus d’actions',
              onSelected: (v) => switch (v) {
                'statement' => _statement(o),
                'adjust' => _adjust(o),
                _ => null,
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'statement',
                  enabled: !_exporting,
                  child: const ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.picture_as_pdf_outlined),
                    title: Text('Relevé de compte (PDF)'),
                  ),
                ),
                if (canAdjust)
                  const PopupMenuItem(
                    value: 'adjust',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.tune_rounded),
                      title: Text('Ajuster le solde'),
                    ),
                  ),
              ],
            ),
        ],
      ),
      body: AsyncView<CustomerOverview>(
        value: overview,
        onRetry: () => ref.invalidate(customerOverviewProvider(widget.customerId)),
        data: (o) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(customerOverviewProvider(widget.customerId)),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
            children: [
              _Header(o: o, open: _open),
              const SizedBox(height: 14),
              _BalanceCard(
                o: o,
                onRepay: canRepay && o.balance > 0 ? () => _repay(o) : null,
                onRemind: o.balance > 0 && o.customer.phone != null ? () => _remind(o) : null,
              ),
              LoyaltyCardTile(customer: o.customer),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: StatTile(label: 'Total acheté', value: money(o.stats.totalSpent)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: StatTile(label: 'Nombre d’achats', value: '${o.stats.salesCount}'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: StatTile(label: 'Panier moyen', value: money(o.stats.averageBasket)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: StatTile(
                      label: 'Dernier achat',
                      value: o.stats.lastPurchaseAt == null ? '—' : sinceText(o.stats.lastPurchaseAt!),
                    ),
                  ),
                ],
              ),
              if (o.stats.openInvoices > 0) ...[
                const SizedBox(height: 10),
                Glass(
                  radius: 18,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  onTap: () => context.push('/invoices'),
                  child: Row(
                    children: [
                      Icon(Icons.receipt_long_rounded, color: AppColors.warn),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '${o.stats.openInvoices} facture${o.stats.openInvoices > 1 ? 's' : ''} à encaisser : '
                          '${money(o.stats.openInvoicesDue)}',
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                        ),
                      ),
                      Icon(Icons.chevron_right_rounded, color: AppColors.muted),
                    ],
                  ),
                ),
              ],
              if (o.customer.notes != null) ...[
                const SizedBox(height: 10),
                Glass(
                  radius: 18,
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.sticky_note_2_outlined, size: 20, color: AppColors.muted),
                      const SizedBox(width: 10),
                      Expanded(child: Text(o.customer.notes!, style: const TextStyle(fontSize: 13.5))),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 18),
              Row(
                children: [
                  Pill(
                    label: 'Carnet de crédit',
                    selected: !_purchases,
                    onTap: () => setState(() => _purchases = false),
                  ),
                  const SizedBox(width: 8),
                  Pill(label: 'Achats', selected: _purchases, onTap: () => setState(() => _purchases = true)),
                ],
              ),
              const SizedBox(height: 10),
              if (_purchases) ..._purchasesTab(o) else ..._ledgerTab(o),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _ledgerTab(CustomerOverview o) => [
    if (o.entries.isEmpty)
      Padding(
        padding: EdgeInsets.all(16),
        child: Text('Aucun mouvement au carnet de crédit', style: TextStyle(color: AppColors.muted)),
      )
    else
      Card(
        child: Column(
          children: [
            for (final (i, e) in o.entries.indexed) ...[
              _EntryTile(entry: e),
              if (i < o.entries.length - 1) const Divider(height: 1, indent: 14, endIndent: 14),
            ],
          ],
        ),
      ),
  ];

  List<Widget> _purchasesTab(CustomerOverview o) => [
    if (o.recentSales.isEmpty)
      Padding(
        padding: EdgeInsets.all(16),
        child: Text('Aucun achat pour l’instant', style: TextStyle(color: AppColors.muted)),
      )
    else
      Card(
        child: Column(
          children: [
            for (final (i, s) in o.recentSales.indexed) ...[
              ListTile(
                onTap: () => context.push('/sales/${s.id}'),
                leading: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(color: AppColors.greenSoft, borderRadius: BorderRadius.circular(12)),
                  child: Icon(Icons.shopping_bag_outlined, size: 18, color: AppColors.green),
                ),
                title: Text(
                  s.number,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    decoration: s.status == 'voided' ? TextDecoration.lineThrough : null,
                  ),
                ),
                subtitle: Text(
                  '${dateTime(s.soldAt)} · ${s.itemCount} article${s.itemCount > 1 ? 's' : ''}'
                  '${s.status == 'voided'
                      ? ' · annulée'
                      : s.due > 0
                      ? ' · ${moneyShort(s.due)} à crédit'
                      : ''}',
                  style: const TextStyle(fontSize: 12),
                ),
                trailing: Text(moneyShort(s.total), style: const TextStyle(fontWeight: FontWeight.w800)),
              ),
              if (i < o.recentSales.length - 1) const Divider(height: 1, indent: 14, endIndent: 14),
            ],
          ],
        ),
      ),
    if (o.topProducts.isNotEmpty) ...[
      const SizedBox(height: 16),
      const Text('Ce qu’il achète le plus', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      Glass(
        radius: 18,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Column(
          children: [
            for (final p in o.topProducts)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
                    ),
                    Text('× ${qty(p.quantity)}', style: TextStyle(color: AppColors.muted, fontSize: 13)),
                    const SizedBox(width: 12),
                    Text(moneyShort(p.total), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                  ],
                ),
              ),
          ],
        ),
      ),
    ],
  ];
}

class _Header extends StatelessWidget {
  const _Header({required this.o, required this.open});
  final CustomerOverview o;
  final Future<bool> Function(Uri) open;

  @override
  Widget build(BuildContext context) {
    final c = o.customer;
    final owes = o.balance > 0;
    return Glass(
      radius: 24,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      child: Column(
        children: [
          Avatar(
            name: c.name,
            size: 64,
            bg: owes ? AppColors.warnBg : AppColors.greenSoft,
            fg: owes ? AppColors.warnText : AppColors.green,
          ),
          const SizedBox(height: 8),
          Text(
            c.name,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
          ),
          if (c.phone != null) Text('+221 ${displayPhone(c.phone!)}', style: TextStyle(color: AppColors.muted)),
          if (c.address != null)
            Text(
              c.address!,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.muted, fontSize: 12.5),
            ),
          if (o.stats.firstPurchaseAt != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                'Client depuis ${DateFormat('MMMM yyyy', 'fr').format(o.stats.firstPurchaseAt!.toLocal())}',
                style: TextStyle(color: AppColors.muted, fontSize: 12),
              ),
            ),
          if (c.phone != null) ...[
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _QuickAction(
                  icon: Icons.call_rounded,
                  label: 'Appeler',
                  color: AppColors.green,
                  onTap: () => open(Uri(scheme: 'tel', path: c.phone)),
                ),
                const SizedBox(width: 18),
                _QuickAction(
                  icon: Icons.chat_rounded,
                  label: 'WhatsApp',
                  color: const Color(0xFF128C4A),
                  onTap: () => open(whatsAppUri('Bonjour ${firstName(c.name)}, ', phone: c.phone)),
                ),
                const SizedBox(width: 18),
                _QuickAction(
                  icon: Icons.sms_outlined,
                  label: 'SMS',
                  color: const Color(0xFF2F6FDB),
                  onTap: () => open(Uri(scheme: 'sms', path: c.phone)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({required this.icon, required this.label, required this.color, required this.onTap});
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(color: color.withValues(alpha: 0.12), shape: BoxShape.circle),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(height: 4),
            ExcludeSemantics(
              child: Text(label, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    ),
  );
}

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({required this.o, this.onRepay, this.onRemind});
  final CustomerOverview o;
  final VoidCallback? onRepay;
  final VoidCallback? onRemind;

  static const _muted = Color(0xFFCDE9DD);

  @override
  Widget build(BuildContext context) {
    final limit = o.creditLimit;
    final age = o.debtAgeDays();
    final used = limit == null || limit == 0 ? 0.0 : (o.balance / limit).clamp(0.0, 1.0);
    final over = limit != null && o.balance > limit;
    final buttonText = Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 14, fontWeight: FontWeight.w800);
    return Sheen(
      radius: 26,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: AuroraBackground(
          tone: AuroraTone.deep,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  o.balance >= 0 ? 'Solde dû' : 'Avoir du client',
                  style: const TextStyle(color: _muted, fontSize: 12),
                ),
                Text(
                  money(o.balance.abs()),
                  style: TextStyle(
                    color: o.balance > 0 ? const Color(0xFFFFC28F) : AppColors.glow,
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.6,
                  ),
                ),
                if (o.balance > 0 && o.oldestUnpaidAt != null)
                  Text(
                    age == null || age < 1
                        ? 'Dette du jour'
                        : 'Doit depuis $age jour${age > 1 ? 's' : ''} (le ${shortDate(o.oldestUnpaidAt!)})',
                    style: const TextStyle(color: _muted, fontSize: 12.5),
                  ),
                if (o.balance <= 0) const Text('Compte à jour', style: TextStyle(color: _muted, fontSize: 12.5)),
                if (limit != null) ...[
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: used,
                      minHeight: 7,
                      backgroundColor: Colors.white.withValues(alpha: 0.15),
                      color: over
                          ? const Color(0xFFFF8A65)
                          : used > 0.8
                          ? const Color(0xFFFFC28F)
                          : AppColors.glow,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    over
                        ? 'Plafond de ${moneyShort(limit)} dépassé de ${moneyShort(o.balance - limit)}'
                        : 'Plafond ${moneyShort(limit)} · encore ${moneyShort(o.availableCredit ?? 0)} possible',
                    style: TextStyle(
                      color: over ? const Color(0xFFFFB199) : _muted,
                      fontSize: 12,
                      fontWeight: over ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ],
                if (o.customer.lastRemindedAt != null && o.balance > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Dernier rappel ${sinceText(o.customer.lastRemindedAt!)}',
                      style: const TextStyle(color: _muted, fontSize: 12),
                    ),
                  ),
                if (onRepay != null) ...[
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: const Color(0xFF13241C), // bouton blanc sur carte verte : texte toujours foncé
                      minimumSize: const Size.fromHeight(46),
                      textStyle: buttonText,
                    ),
                    onPressed: onRepay,
                    icon: const Icon(Icons.check, size: 18),
                    label: const Text('Encaisser un remboursement'),
                  ),
                ],
                if (onRemind != null) ...[
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.whatsapp,
                      foregroundColor: const Color(0xFF08361A),
                      minimumSize: const Size.fromHeight(46),
                      textStyle: buttonText,
                    ),
                    onPressed: onRemind,
                    icon: const Icon(Icons.notifications_active_outlined, size: 18),
                    label: const Text('Envoyer un rappel'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry});
  final LedgerEntry entry;

  @override
  Widget build(BuildContext context) {
    final debt = entry.amount > 0;
    return ListTile(
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: debt ? AppColors.warnBg : AppColors.greenSoft,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(
          debt ? Icons.arrow_downward : Icons.check,
          size: 18,
          color: debt ? AppColors.warn : AppColors.green,
        ),
      ),
      title: Text(entry.label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
      subtitle: Text(
        entry.balanceAfter == null
            ? dateTime(entry.at)
            : '${dateTime(entry.at)} · solde ${moneyShort(entry.balanceAfter!)}',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Text(
        '${debt ? '+' : '−'} ${moneyShort(entry.amount.abs())}',
        style: TextStyle(fontWeight: FontWeight.w800, color: debt ? AppColors.warn : AppColors.green),
      ),
    );
  }
}

// =====================================================================
// Feuilles d'action
// =====================================================================

class _ReminderSheet extends ConsumerStatefulWidget {
  const _ReminderSheet({required this.overview, required this.business, required this.open});
  final CustomerOverview overview;
  final String business;
  final Future<bool> Function(Uri) open;
  @override
  ConsumerState<_ReminderSheet> createState() => _ReminderSheetState();
}

class _ReminderSheetState extends ConsumerState<_ReminderSheet> {
  ReminderTone _tone = ReminderTone.gentle;
  late final _text = TextEditingController(text: reminderText(widget.overview, widget.business));

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send(String channel) async {
    final phone = widget.overview.customer.phone!;
    final uri = channel == 'sms'
        ? Uri(scheme: 'sms', path: phone, queryParameters: {'body': _text.text})
        : whatsAppUri(_text.text, phone: phone);
    final ok = await widget.open(uri);
    if (!ok) return;
    try {
      await ref.read(repoProvider).markReminded(widget.overview.customer.id, channel);
    } catch (_) {
      // Le rappel est parti ; ne pas bloquer si l'enregistrement de la date échoue
    }
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Rappel de paiement', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        Text(
          '${widget.overview.customer.name} · ${money(widget.overview.balance)}',
          style: TextStyle(color: AppColors.muted),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final t in ReminderTone.values)
              Pill(
                label: t.label,
                selected: _tone == t,
                onTap: () => setState(() {
                  _tone = t;
                  _text.text = reminderText(widget.overview, widget.business, tone: t);
                }),
              ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('reminderText'),
          controller: _text,
          minLines: 3,
          maxLines: 8,
          decoration: const InputDecoration(labelText: 'Message (modifiable)'),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.whatsapp,
                  foregroundColor: const Color(0xFF08361A),
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: () => _send('whatsapp'),
                icon: const Icon(Icons.chat_rounded, size: 18),
                label: const Text('WhatsApp'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                onPressed: () => _send('sms'),
                icon: const Icon(Icons.sms_outlined, size: 18),
                label: const Text('SMS'),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class _AdjustSheet extends ConsumerStatefulWidget {
  const _AdjustSheet({required this.customerId, required this.balance});
  final String customerId;
  final int balance;
  @override
  ConsumerState<_AdjustSheet> createState() => _AdjustSheetState();
}

class _AdjustSheetState extends ConsumerState<_AdjustSheet> {
  final _amount = TextEditingController();
  final _reason = TextEditingController();
  bool _increase = true; // reprise d'ancienne dette / remise de dette
  bool _busy = false;

  @override
  void dispose() {
    _amount.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final a = int.tryParse(_amount.text) ?? 0;
    if (a <= 0) return showInfo(context, 'Indiquez un montant');
    if (_reason.text.trim().length < 3) return showInfo(context, 'Indiquez la raison');
    if (!_increase && a > widget.balance) {
      return showInfo(context, 'La remise dépasse la dette (${money(widget.balance)})');
    }
    setState(() => _busy = true);
    try {
      await ref
          .read(repoProvider)
          .adjustBalance(widget.customerId, amount: _increase ? a : -a, reason: _reason.text.trim());
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Ajuster le solde', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        Text('Solde actuel : ${money(widget.balance)}', style: TextStyle(color: AppColors.muted)),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            Pill(
              label: 'Ajouter une ancienne dette',
              selected: _increase,
              onTap: () => setState(() => _increase = true),
            ),
            if (widget.balance > 0)
              Pill(label: 'Remise de dette', selected: !_increase, onTap: () => setState(() => _increase = false)),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          _increase
              ? 'Pour reprendre une dette notée dans votre ancien cahier.'
              : 'Efface une partie de la dette (geste commercial, erreur de saisie).',
          style: TextStyle(color: AppColors.muted, fontSize: 12.5),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('adjustAmount'),
          controller: _amount,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(labelText: 'Montant', suffixText: 'FCFA'),
        ),
        const SizedBox(height: 10),
        TextField(
          key: const Key('adjustReason'),
          controller: _reason,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: 'Raison',
            hintText: _increase ? 'Ex. reprise du cahier papier' : 'Ex. geste commercial',
          ),
        ),
        const SizedBox(height: 16),
        BusyButton(label: 'Enregistrer', busy: _busy, onPressed: _save),
      ],
    ),
  );
}

class _RepaySheet extends ConsumerStatefulWidget {
  const _RepaySheet({required this.customerId, required this.balance});
  final String customerId;
  final int balance;
  @override
  ConsumerState<_RepaySheet> createState() => _RepaySheetState();
}

class _RepaySheetState extends ConsumerState<_RepaySheet> {
  late final _amount = TextEditingController(text: '${widget.balance}');
  PayMethod _method = PayMethod.cash;
  bool _busy = false;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final a = int.tryParse(_amount.text) ?? 0;
    if (a <= 0) return;
    if (a > widget.balance) return showInfo(context, 'Le montant dépasse la dette (${money(widget.balance)})');
    setState(() => _busy = true);
    try {
      await ref.read(repoProvider).repay(widget.customerId, a, _method);
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
        const Text('Remboursement', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        Text('Dette actuelle : ${money(widget.balance)}', style: TextStyle(color: AppColors.muted)),
        const SizedBox(height: 14),
        TextField(
          key: const Key('repayAmount'),
          controller: _amount,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(labelText: 'Montant reçu', suffixText: 'FCFA'),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final m in [PayMethod.cash, PayMethod.wave, PayMethod.orangeMoney, PayMethod.freeMoney])
              Pill(label: m.label, selected: _method == m, onTap: () => setState(() => _method = m)),
          ],
        ),
        const SizedBox(height: 16),
        BusyButton(label: 'Enregistrer', busy: _busy, onPressed: _save),
      ],
    ),
  );
}

/// Carte de fidélité du client : points, progression vers la récompense, anniversaire, cadeau.
class LoyaltyCardTile extends ConsumerWidget {
  const LoyaltyCardTile({super.key, required this.customer});
  final Contact customer;

  Future<void> _gift(BuildContext context, WidgetRef ref) async {
    final ctrl = TextEditingController(text: '10');
    final points = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Offrir des points'),
        content: TextField(
          key: const Key('gift_points'),
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(labelText: 'Nombre de points', suffixText: 'pts'),
        ),
        actions: [
          CancelButton(onPressed: () => Navigator.pop(ctx)),
          ConfirmButton(label: 'Offrir', onPressed: () => Navigator.pop(ctx, int.tryParse(ctrl.text))),
        ],
      ),
    );
    if (points == null || points <= 0 || !context.mounted) return;
    try {
      final balance = await ref.read(repoProvider).adjustLoyalty(customer.id, points, 'Cadeau');
      ref.invalidate(loyaltyCardProvider(customer.id));
      ref.invalidate(loyaltyDashboardProvider);
      if (context.mounted) showInfo(context, '$points points offerts · solde $balance');
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(loyaltySettingsProvider).value;
    if (settings == null || !settings.enabled) return const SizedBox.shrink();
    final card = ref.watch(loyaltyCardProvider(customer.id)).value;
    if (card == null) return const SizedBox.shrink();
    final (soft, strong) = AppColors.tone(const Color(0xFFFFF4E2), const Color(0xFF9A5B00));
    final birthday = customer.birthDay != null && customer.birthMonth != null
        ? DateFormat('d MMMM', 'fr').format(DateTime(2000, customer.birthMonth!, customer.birthDay!))
        : null;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Glass(
        key: const Key('loyalty_card'),
        radius: 22,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: soft, borderRadius: BorderRadius.circular(12)),
                  child: Icon(Icons.stars_rounded, color: strong),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${card.balance} points', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                      Text(
                        card.rewardsAvailable > 0
                            ? '${card.rewardsAvailable} récompense${card.rewardsAvailable > 1 ? 's' : ''} disponible'
                                  '${card.rewardsAvailable > 1 ? 's' : ''} · ${moneyShort(settings.rewardValue)} chacune'
                            : 'Encore ${card.pointsToNextReward} points pour ${moneyShort(settings.rewardValue)} de remise',
                        style: TextStyle(color: AppColors.muted, fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
                if (ref.can('sales:void'))
                  IconButton(
                    tooltip: 'Offrir des points',
                    onPressed: () => _gift(context, ref),
                    icon: const Icon(Icons.card_giftcard_rounded),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                value: card.rewardsAvailable > 0 ? 1 : card.progress,
                minHeight: 8,
                backgroundColor: AppColors.line,
                color: strong,
              ),
            ),
            if (birthday != null) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(Icons.cake_rounded, size: 16, color: AppColors.muted),
                  const SizedBox(width: 6),
                  Text('Anniversaire : $birthday', style: TextStyle(color: AppColors.muted, fontSize: 12.5)),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
