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
import '../customers/customers_screens.dart' show sinceText;
import '../sales/receipt_screen.dart' show receiptActionsProvider, whatsAppUri;

String purchaseDay(DateTime d) => DateFormat('d MMM yyyy', 'fr').format(d);

/// Pastille de statut d'un bon de commande.
class PurchaseStatusChip extends StatelessWidget {
  const PurchaseStatusChip({super.key, required this.status, this.late = false});
  final PurchaseStatus status;
  final bool late;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = late
        ? AppColors.tone(const Color(0xFFFDE7E4), AppColors.danger)
        : switch (status) {
            PurchaseStatus.draft => AppColors.tone(const Color(0xFFEFF1F0), AppColors.muted),
            PurchaseStatus.ordered => AppColors.tone(const Color(0xFFE6EFFC), const Color(0xFF1F5BB8)),
            PurchaseStatus.partial => AppColors.tone(AppColors.warnBg, AppColors.warnText),
            PurchaseStatus.received => AppColors.tone(AppColors.greenSoft, AppColors.greenDark),
            PurchaseStatus.cancelled => AppColors.tone(const Color(0xFFEFF1F0), AppColors.muted),
          };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(
        late ? 'En retard' : status.label,
        style: TextStyle(color: fg, fontSize: 11.5, fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// Carte d'un bon dans une liste.
class PurchaseTile extends StatelessWidget {
  const PurchaseTile({super.key, required this.p, this.showSupplier = true});
  final PurchaseSummary p;
  final bool showSupplier;

  @override
  Widget build(BuildContext context) {
    final cancelled = p.status == PurchaseStatus.cancelled;
    final sub = [
      if (showSupplier) p.supplierName,
      purchaseDay(p.orderDate),
      '${p.lineCount} article${p.lineCount > 1 ? 's' : ''}',
    ].join(' · ');
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
        onTap: () => context.push('/purchases/${p.id}'),
        title: Row(
          children: [
            Flexible(
              child: Text(
                p.number,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  decoration: cancelled ? TextDecoration.lineThrough : null,
                ),
              ),
            ),
            const SizedBox(width: 8),
            PurchaseStatusChip(status: p.status, late: p.late()),
          ],
        ),
        subtitle: Text(sub, style: const TextStyle(fontSize: 12)),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(moneyShort(p.total), style: const TextStyle(fontWeight: FontWeight.w800)),
            if (p.due > 0)
              Text(
                'à payer ${moneyShort(p.due)}',
                style: TextStyle(fontSize: 11.5, color: AppColors.warn, fontWeight: FontWeight.w700),
              )
            else if (p.status == PurchaseStatus.received && p.paid >= p.receivedTotal)
              Text(
                'payé',
                style: TextStyle(fontSize: 11.5, color: AppColors.green, fontWeight: FontWeight.w700),
              ),
          ],
        ),
      ),
    );
  }
}

/// Achats : bons de commande et fournisseurs.
class PurchasesScreen extends ConsumerStatefulWidget {
  const PurchasesScreen({super.key, this.suppliersTab = false});
  final bool suppliersTab;
  @override
  ConsumerState<PurchasesScreen> createState() => _PurchasesScreenState();
}

class _PurchasesScreenState extends ConsumerState<PurchasesScreen> {
  late bool _suppliers = widget.suppliersTab;
  PurchaseFilter _filter = PurchaseFilter.open;
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final list = ref.watch(purchasesProvider((filter: _filter, supplierId: null)));
    final canWrite = ref.watch(canProvider('inventory:write'));
    final canContacts = ref.watch(canProvider('contacts:write'));
    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Achats', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      floatingActionButton: _suppliers
          ? (canContacts
                ? FloatingActionButton.extended(
                    heroTag: 'newSupplier',
                    onPressed: () => context.push('/suppliers/new'),
                    icon: const Icon(Icons.add_business_rounded),
                    label: const Text('Nouveau fournisseur'),
                  )
                : null)
          : (canWrite
                ? FloatingActionButton.extended(
                    heroTag: 'newPurchase',
                    onPressed: () => context.push('/purchases/new'),
                    icon: const Icon(Icons.add_shopping_cart_rounded),
                    label: const Text('Nouvel achat'),
                  )
                : null),
      body: RefreshIndicator(
        onRefresh: () async => refreshPurchasing(ref),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
          children: [
            _Totals(
              totals: list.value?.totals,
              onFilter: (f) => setState(() {
                _suppliers = false;
                _filter = f;
              }),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Pill(label: 'Commandes', selected: !_suppliers, onTap: () => setState(() => _suppliers = false)),
                const SizedBox(width: 8),
                Pill(label: 'Fournisseurs', selected: _suppliers, onTap: () => setState(() => _suppliers = true)),
              ],
            ),
            const SizedBox(height: 12),
            if (_suppliers) ..._supplierList() else ..._orderList(list),
          ],
        ),
      ),
    );
  }

  List<Widget> _orderList(AsyncValue<PurchaseList> list) => [
    SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final f in PurchaseFilter.values) ...[
            Pill(label: f.label, selected: _filter == f, onTap: () => setState(() => _filter = f)),
            const SizedBox(width: 8),
          ],
        ],
      ),
    ),
    const SizedBox(height: 10),
    AsyncView<PurchaseList>(
      value: list,
      onRetry: () => ref.invalidate(purchasesProvider),
      data: (l) => l.data.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Column(
                children: [
                  Icon(Icons.local_shipping_outlined, size: 44, color: AppColors.muted),
                  const SizedBox(height: 8),
                  Text(switch (_filter) {
                    PurchaseFilter.open => 'Aucune commande en cours',
                    PurchaseFilter.unpaid => 'Vous ne devez rien à vos fournisseurs',
                    PurchaseFilter.received => 'Aucune commande reçue',
                    PurchaseFilter.all => 'Enregistrez votre premier achat',
                  }, style: TextStyle(color: AppColors.muted)),
                ],
              ),
            )
          : Column(
              children: [
                for (final p in l.data)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: PurchaseTile(p: p),
                  ),
              ],
            ),
    ),
  ];

  List<Widget> _supplierList() {
    final suppliers = ref.watch(suppliersProvider(_search));
    return [
      TextField(
        key: const Key('supplierSearch'),
        decoration: const InputDecoration(
          hintText: 'Rechercher un fournisseur',
          prefixIcon: Icon(Icons.search),
          isDense: true,
        ),
        onChanged: (v) => setState(() => _search = v.trim()),
      ),
      const SizedBox(height: 10),
      AsyncView<List<SupplierRow>>(
        value: suppliers,
        onRetry: () => ref.invalidate(suppliersProvider(_search)),
        data: (list) => list.isEmpty
            ? Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: Text('Ajoutez vos grossistes et fournisseurs', style: TextStyle(color: AppColors.muted)),
                ),
              )
            : Column(
                children: [
                  for (final s in list)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Card(
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                          onTap: () => context.push('/suppliers/${s.id}'),
                          leading: Avatar(
                            name: s.name,
                            size: 42,
                            bg: const Color(0xFFE6EFFC),
                            fg: const Color(0xFF1F5BB8),
                          ),
                          title: Text(s.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                          subtitle: Text(
                            s.ordersCount == 0
                                ? (s.phone == null ? 'Aucune commande' : displayPhone(s.phone!))
                                : '${s.ordersCount} commande${s.ordersCount > 1 ? 's' : ''}'
                                      '${s.lastOrderAt == null ? '' : ' · dernière ${sinceText(s.lastOrderAt!)}'}',
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: Text(
                            s.due > 0 ? money(s.due) : moneyShort(s.purchased),
                            style: TextStyle(
                              fontWeight: s.due > 0 ? FontWeight.w800 : FontWeight.w600,
                              color: s.due > 0 ? AppColors.warn : AppColors.muted,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
      ),
    ];
  }
}

class _Totals extends StatelessWidget {
  const _Totals({required this.totals, required this.onFilter});
  final PurchaseTotals? totals;
  final ValueChanged<PurchaseFilter> onFilter;

  static const _muted = Color(0xFFCDE9DD);

  @override
  Widget build(BuildContext context) {
    final t = totals ?? const PurchaseTotals();
    Widget mini(String label, String value, PurchaseFilter f) => Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => onFilter(f),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800),
              ),
              Text(label, style: const TextStyle(color: _muted, fontSize: 11.5)),
            ],
          ),
        ),
      ),
    );
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
                const LabelWithEye('À payer aux fournisseurs', style: TextStyle(color: _muted, fontSize: 12.5)),
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
                    mini('En cours', '${t.openOrders}', PurchaseFilter.open),
                    mini('À recevoir', moneyShort(t.toReceive), PurchaseFilter.open),
                    mini('Fournisseurs à payer', '${t.suppliersOwed}', PurchaseFilter.unpaid),
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

// =====================================================================
// Fiche fournisseur
// =====================================================================

class SupplierScreen extends ConsumerWidget {
  const SupplierScreen({super.key, required this.supplierId});
  final String supplierId;

  Future<void> _pay(BuildContext context, WidgetRef ref, SupplierOverview o) async {
    final done = await showModalBottomSheet<bool>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => PaySheet(
        title: 'Payer ${o.supplier.name}',
        subtitle: 'Vous lui devez ${money(o.due)} · réparti sur les bons les plus anciens',
        max: o.due,
        onPay: (amount, method) => ref.read(repoProvider).paySupplier(o.supplier.id, amount: amount, method: method),
      ),
    );
    if (done == true && context.mounted) {
      refreshPurchasing(ref);
      showInfo(context, 'Paiement enregistré');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overview = ref.watch(supplierProvider(supplierId));
    final canWrite = ref.watch(canProvider('inventory:write'));
    final canContacts = ref.watch(canProvider('contacts:write'));
    final actions = ref.read(receiptActionsProvider);
    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Fournisseur', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          if (canContacts && overview.value != null)
            IconButton(
              tooltip: 'Modifier',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => context.push('/suppliers/$supplierId/edit'),
            ),
        ],
      ),
      body: AsyncView<SupplierOverview>(
        value: overview,
        onRetry: () => ref.invalidate(supplierProvider(supplierId)),
        data: (o) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(supplierProvider(supplierId)),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
            children: [
              Glass(
                radius: 24,
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
                child: Column(
                  children: [
                    Avatar(name: o.supplier.name, size: 60, bg: const Color(0xFFE6EFFC), fg: const Color(0xFF1F5BB8)),
                    const SizedBox(height: 8),
                    Text(
                      o.supplier.name,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
                    ),
                    if (o.supplier.phone != null)
                      Text('+221 ${displayPhone(o.supplier.phone!)}', style: TextStyle(color: AppColors.muted)),
                    if (o.supplier.address != null)
                      Text(o.supplier.address!, style: TextStyle(color: AppColors.muted, fontSize: 12.5)),
                    if (o.supplier.phone != null) ...[
                      const SizedBox(height: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          TextButton.icon(
                            onPressed: () => actions.openWhatsApp(Uri(scheme: 'tel', path: o.supplier.phone)),
                            icon: const Icon(Icons.call_rounded),
                            label: const Text('Appeler'),
                          ),
                          const SizedBox(width: 8),
                          TextButton.icon(
                            onPressed: () => actions.openWhatsApp(
                              whatsAppUri('Bonjour ${o.supplier.name}, ', phone: o.supplier.phone),
                            ),
                            icon: const Icon(Icons.chat_rounded),
                            label: const Text('WhatsApp'),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Sheen(
                radius: 24,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: AuroraBackground(
                    tone: AuroraTone.deep,
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text('Vous lui devez', style: TextStyle(color: Color(0xFFCDE9DD), fontSize: 12)),
                          Text(
                            money(o.due),
                            style: TextStyle(
                              color: o.due > 0 ? const Color(0xFFFFC28F) : AppColors.glow,
                              fontSize: 28,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          if (o.openOrders > 0)
                            Text(
                              '${o.openOrders} commande${o.openOrders > 1 ? 's' : ''} en cours',
                              style: const TextStyle(color: Color(0xFFCDE9DD), fontSize: 12.5),
                            ),
                          if (canWrite) ...[
                            const SizedBox(height: 14),
                            Row(
                              children: [
                                if (o.due > 0) ...[
                                  Expanded(
                                    child: FilledButton.icon(
                                      style: FilledButton.styleFrom(
                                        backgroundColor: Colors.white,
                                        foregroundColor: const Color(
                                          0xFF13241C,
                                        ), // bouton blanc sur carte verte : texte toujours foncé
                                        minimumSize: const Size.fromHeight(46),
                                      ),
                                      onPressed: () => _pay(context, ref, o),
                                      icon: const Icon(Icons.payments_outlined, size: 18),
                                      label: const Text('Payer'),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                ],
                                Expanded(
                                  child: FilledButton.icon(
                                    style: FilledButton.styleFrom(
                                      backgroundColor: AppColors.glow,
                                      foregroundColor: AppColors.deep,
                                      minimumSize: const Size.fromHeight(46),
                                    ),
                                    onPressed: () => context.push('/purchases/new?supplierId=${o.supplier.id}'),
                                    icon: const Icon(Icons.add_shopping_cart_rounded, size: 18),
                                    label: const Text('Commander'),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: StatTile(label: 'Total acheté', value: money(o.purchased)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: StatTile(label: 'Déjà payé', value: money(o.paid)),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: StatTile(label: 'Commandes', value: '${o.ordersCount}'),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: StatTile(
                      label: 'Dernière commande',
                      value: o.lastOrderAt == null ? '—' : sinceText(o.lastOrderAt!),
                    ),
                  ),
                ],
              ),
              if (o.supplier.notes != null) ...[
                const SizedBox(height: 10),
                Glass(
                  radius: 18,
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      Icon(Icons.sticky_note_2_outlined, size: 20, color: AppColors.muted),
                      const SizedBox(width: 10),
                      Expanded(child: Text(o.supplier.notes!, style: const TextStyle(fontSize: 13.5))),
                    ],
                  ),
                ),
              ],
              if (o.products.isNotEmpty) ...[
                const SizedBox(height: 18),
                const Text('Ce que vous lui achetez', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                Glass(
                  radius: 18,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  child: Column(
                    children: [
                      for (final p in o.products)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  p.name,
                                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
                                ),
                              ),
                              Text('× ${qty(p.quantity)}', style: TextStyle(color: AppColors.muted, fontSize: 13)),
                              const SizedBox(width: 12),
                              Text(
                                'dernier prix ${moneyShort(p.lastCost)}',
                                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 18),
              const Text('Commandes', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              if (o.orders.isEmpty)
                Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('Aucune commande pour l’instant', style: TextStyle(color: AppColors.muted)),
                ),
              for (final p in o.orders)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: PurchaseTile(p: p, showSupplier: false),
                ),
              if (o.payments.isNotEmpty) ...[
                const SizedBox(height: 10),
                const Text('Paiements', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                Card(
                  child: Column(
                    children: [
                      for (final (i, p) in o.payments.indexed) ...[
                        ListTile(
                          leading: Icon(Icons.check_circle_outline_rounded, color: AppColors.green),
                          title: Text(
                            '${p.method?.label ?? 'Paiement'} · ${p.number ?? ''}',
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                          ),
                          subtitle: Text(dateTime(p.paidAt), style: const TextStyle(fontSize: 12)),
                          trailing: Text(
                            '− ${moneyShort(p.amount)}',
                            style: TextStyle(color: AppColors.green, fontWeight: FontWeight.w800),
                          ),
                        ),
                        if (i < o.payments.length - 1) const Divider(height: 1, indent: 14, endIndent: 14),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Paiement à un fournisseur (un bon ou tous ses bons). [onPay] lance l'appel à l'API.
class PaySheet extends StatefulWidget {
  const PaySheet({super.key, required this.title, required this.subtitle, required this.max, required this.onPay});
  final String title;
  final String subtitle;
  final int max;
  final Future<void> Function(int amount, PayMethod method) onPay;
  @override
  State<PaySheet> createState() => _PaySheetState();
}

class _PaySheetState extends State<PaySheet> {
  late final _amount = TextEditingController(text: widget.max > 0 ? '${widget.max}' : '');
  PayMethod _method = PayMethod.cash;
  bool _busy = false;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final a = int.tryParse(_amount.text) ?? 0;
    if (a <= 0) return showInfo(context, 'Indiquez le montant payé');
    if (a > widget.max) return showInfo(context, 'Le montant dépasse ${money(widget.max)}');
    setState(() => _busy = true);
    try {
      await widget.onPay(a, _method);
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
        Text(widget.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        Text(widget.subtitle, style: TextStyle(color: AppColors.muted)),
        const SizedBox(height: 14),
        TextField(
          key: const Key('payAmount'),
          controller: _amount,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(labelText: 'Montant payé', suffixText: 'FCFA'),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final m in const [
              PayMethod.cash,
              PayMethod.wave,
              PayMethod.orangeMoney,
              PayMethod.transfer,
              PayMethod.cheque,
            ])
              Pill(label: m.label, selected: _method == m, onTap: () => setState(() => _method = m)),
          ],
        ),
        const SizedBox(height: 16),
        BusyButton(label: 'Enregistrer le paiement', busy: _busy, onPressed: _save),
      ],
    ),
  );
}
