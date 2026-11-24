import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/admin_models.dart';
import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import 'admin_widgets.dart';

/// Back office : paiements Pro. « À vérifier » : transferts déclarés par les commerçants ;
/// « Historique » : tous les paiements, en ligne (Chariow) et par transfert.
class AdminPaymentsScreen extends ConsumerStatefulWidget {
  const AdminPaymentsScreen({super.key});
  @override
  ConsumerState<AdminPaymentsScreen> createState() => _AdminPaymentsScreenState();
}

class _AdminPaymentsScreenState extends ConsumerState<AdminPaymentsScreen> {
  bool _history = false;
  AdminPayStatus? _status;
  bool? _online;

  void _refresh() {
    ref.invalidate(adminPaymentsProvider);
    ref.invalidate(adminAllPaymentsProvider);
    ref.invalidate(adminOverviewProvider);
    ref.invalidate(adminBusinessesProvider);
  }

  Future<void> _approve(PaymentRequest r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Valider le paiement ?'),
        content: Text(
          '${r.businessName} · ${moneyShort(r.amount)} par ${r.method.label}, réf. ${r.reference}.\n'
          'Vérifiez d’abord que l’argent est bien arrivé.',
        ),
        actions: dialogActions([
          CancelButton(onPressed: () => Navigator.pop(ctx, false)),
          ConfirmButton(label: 'Valider', onPressed: () => Navigator.pop(ctx, true)),
        ]),
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(repoProvider).approvePayment(r.id);
      _refresh();
      if (mounted) showInfo(context, 'Pro activé pour ${r.businessName}');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _reject(PaymentRequest r) async {
    final note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Refuser le paiement'),
        content: TextField(
          key: const Key('reject_note'),
          controller: note,
          maxLines: 2,
          decoration: const InputDecoration(labelText: 'Raison (vue par le commerçant)'),
        ),
        actions: dialogActions([
          CancelButton(onPressed: () => Navigator.pop(ctx, false)),
          ConfirmButton(danger: true, label: 'Refuser', onPressed: () => Navigator.pop(ctx, true)),
        ]),
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(repoProvider).rejectPayment(r.id, note.text.trim().isEmpty ? null : note.text.trim());
      _refresh();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= adminWide;
    final pad = wide ? 28.0 : 16.0;
    final pending = ref.watch(adminPaymentsProvider('pending'));
    final count = pending.value?.length ?? 0;
    return AdminShell(
      section: AdminSection.payments,
      title: 'Paiements',
      subtitle: 'Abonnements Sama360 Pro',
      actions: dialogActions([
        IconButton(tooltip: 'Actualiser', onPressed: _refresh, icon: const Icon(Icons.refresh_rounded)),
      ]),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: pad),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(
                    value: false,
                    label: Text(count > 0 ? 'À vérifier ($count)' : 'À vérifier', key: const Key('pay_tab_check')),
                    icon: const Icon(Icons.fact_check_rounded),
                  ),
                  const ButtonSegment(
                    value: true,
                    label: Text('Historique', key: Key('pay_tab_history')),
                    icon: Icon(Icons.receipt_long_rounded),
                  ),
                ],
                selected: {_history},
                onSelectionChanged: (s) => setState(() => _history = s.first),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(child: _history ? _historyView(pad, wide) : _queue(pad, wide, pending)),
        ],
      ),
    );
  }

  Widget _queue(double pad, bool wide, AsyncValue<List<PaymentRequest>> pending) => AsyncView<List<PaymentRequest>>(
    value: pending,
    onRetry: () => ref.invalidate(adminPaymentsProvider('pending')),
    data: (items) => items.isEmpty
        ? Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.task_alt_rounded, size: 48, color: AppColors.leaf),
                const SizedBox(height: 8),
                const Text('Tout est à jour', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                Text('Aucun transfert à vérifier', style: TextStyle(color: AppColors.muted)),
              ],
            ),
          )
        : ListView(
            padding: EdgeInsets.fromLTRB(pad, 0, pad, wide ? 32 : 110),
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final r in items)
                    SizedBox(
                      width: wide ? 420 : double.infinity,
                      child: _RequestCard(r: r, onApprove: () => _approve(r), onReject: () => _reject(r)),
                    ),
                ],
              ),
            ],
          ),
  );

  Widget _historyView(double pad, bool wide) {
    final f = (status: _status, online: _online);
    final data = ref.watch(adminAllPaymentsProvider(f));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(horizontal: pad),
          child: Row(
            children: [
              for (final (s, label) in [
                (null, 'Tous'),
                (AdminPayStatus.paid, 'Payés'),
                (AdminPayStatus.toCheck, 'À vérifier'),
                (AdminPayStatus.rejected, 'Refusés'),
                (AdminPayStatus.failed, 'Échoués'),
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Pill(label: label, selected: _status == s, onTap: () => setState(() => _status = s)),
                ),
              const SizedBox(width: 10),
              for (final (o, label) in [(true, 'En ligne'), (false, 'Transfert')])
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: FilterChip(
                    label: Text(label),
                    selected: _online == o,
                    onSelected: (_) => setState(() => _online = _online == o ? null : o),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: AsyncView<({List<AdminPayment> items, bool hasMore})>(
            value: data,
            onRetry: () => ref.invalidate(adminAllPaymentsProvider(f)),
            data: (page) {
              final paid = page.items
                  .where((p) => p.status == AdminPayStatus.paid)
                  .fold<int>(0, (s, p) => s + p.amount);
              return page.items.isEmpty
                  ? Center(
                      child: Text('Aucun paiement', style: TextStyle(color: AppColors.muted)),
                    )
                  : ListView(
                      padding: EdgeInsets.fromLTRB(pad, 0, pad, wide ? 32 : 110),
                      children: [
                        Glass(
                          radius: 22,
                          padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
                          child: Column(
                            children: [
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        '${page.items.length}${page.hasMore ? '+' : ''} paiement${page.items.length > 1 ? 's' : ''}',
                                        style: const TextStyle(fontWeight: FontWeight.w800),
                                      ),
                                    ),
                                    Flexible(
                                      child: Text(
                                        'Encaissé : ${moneyShort(paid)}',
                                        textAlign: TextAlign.end,
                                        style: TextStyle(color: AppColors.greenDark, fontWeight: FontWeight.w800),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              for (final p in page.items) PaymentTile(p: p),
                            ],
                          ),
                        ),
                      ],
                    );
            },
          ),
        ),
      ],
    );
  }
}

class _RequestCard extends StatelessWidget {
  const _RequestCard({required this.r, required this.onApprove, required this.onReject});
  final PaymentRequest r;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) => Glass(
    radius: 22,
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            ShopAvatar(r.businessName ?? '?', size: 40),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          r.businessName ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                        ),
                      ),
                      if (r.businessCountry != null) ...[
                        const SizedBox(width: 6),
                        CountryFlag(r.businessCountry!, width: 16),
                      ],
                    ],
                  ),
                  Text(
                    [
                      if (r.businessCity != null) r.businessCity!,
                      DateFormat('d MMM HH:mm', 'fr').format(r.createdAt.toLocal()),
                    ].join(' · '),
                    style: TextStyle(color: AppColors.muted, fontSize: 12.5),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(moneyShort(r.amount), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
                Text(cycleLabel(r.cycle), style: TextStyle(color: AppColors.muted, fontSize: 12)),
              ],
            ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(color: AppColors.surface(0.6), borderRadius: BorderRadius.circular(14)),
          child: Row(
            children: [
              PayLogo(r.method),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(
                      'Réf. ${r.reference}',
                      style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 0.3),
                    ),
                    Text(
                      [r.method.label, if (r.payerPhone != null) 'depuis ${intlPhone(r.payerPhone!)}'].join(' · '),
                      style: TextStyle(color: AppColors.muted, fontSize: 12.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                key: Key('reject_${r.id}'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 46)),
                onPressed: onReject,
                child: const Text('Refuser'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton(
                key: Key('approve_${r.id}'),
                style: FilledButton.styleFrom(minimumSize: const Size(0, 46)),
                onPressed: onApprove,
                child: const Text('Valider'),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

/// Une ligne de paiement (historique, fiche boutique).
class PaymentTile extends StatelessWidget {
  const PaymentTile({super.key, required this.p, this.showBusiness = true});
  final AdminPayment p;
  final bool showBusiness;

  @override
  Widget build(BuildContext context) {
    final (Color c, IconData icon) = switch (p.status) {
      AdminPayStatus.paid => (const Color(0xFF16A34A), Icons.check_circle_rounded),
      AdminPayStatus.toCheck => (AppColors.orange, Icons.hourglass_top_rounded),
      AdminPayStatus.pending => (const Color(0xFF64748B), Icons.more_horiz_rounded),
      AdminPayStatus.rejected || AdminPayStatus.failed => (AppColors.danger, Icons.cancel_rounded),
    };
    final method = p.online ? 'En ligne' : (PayMethod.fromApi(p.method)?.label ?? p.method);
    final date = p.settledAt ?? p.createdAt;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: showBusiness ? () => context.push('/admin/merchants/${p.businessId}') : null,
      leading: p.online || PayMethod.fromApi(p.method) == null
          ? CircleAvatar(
              backgroundColor: AppColors.greenSoft,
              child: Icon(p.online ? Icons.language_rounded : Icons.payments_rounded, color: AppColors.green, size: 20),
            )
          : SizedBox(width: 40, child: Center(child: PayLogo(PayMethod.fromApi(p.method), size: 28))),
      title: Text(
        showBusiness ? p.businessName : '${cycleLabel(p.cycle)} · $method',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      subtitle: Text(
        [
          if (showBusiness) '${cycleLabel(p.cycle)} · $method',
          DateFormat('d MMM y', 'fr').format(date),
          if (p.reference != null && !p.online) 'réf. ${p.reference}',
          if (p.note != null) p.note!,
        ].join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(moneyShort(p.amount), style: const TextStyle(fontWeight: FontWeight.w900)),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13, color: c),
              const SizedBox(width: 3),
              Text(
                p.status.label,
                style: TextStyle(
                  color: AppColors.strongOf(c.withValues(alpha: 0.1), Color.lerp(c, Colors.black, 0.25)!),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
