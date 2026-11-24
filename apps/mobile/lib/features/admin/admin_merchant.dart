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
import '../auth/pin_screen.dart' show confirmSensitive;
import '../team/team_screen.dart' show openUrlProvider;
import 'admin_payments.dart' show PaymentTile;
import 'admin_widgets.dart';

/// Back office : fiche d'une boutique, et les gestes de l'équipe (offrir du Pro, suspendre…).
class AdminMerchantScreen extends ConsumerStatefulWidget {
  const AdminMerchantScreen({super.key, required this.id});
  final String id;
  @override
  ConsumerState<AdminMerchantScreen> createState() => _AdminMerchantScreenState();
}

class _AdminMerchantScreenState extends ConsumerState<AdminMerchantScreen> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() op, String done) async {
    setState(() => _busy = true);
    try {
      await op();
      ref.invalidate(adminBusinessProvider(widget.id));
      ref.invalidate(adminBusinessesProvider);
      ref.invalidate(adminOverviewProvider);
      if (mounted) showInfo(context, done);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _gift(AdminBusiness b) async {
    final r = await showDialog<(int, String?)>(
      context: context,
      builder: (_) => _GiftDialog(name: b.name),
    );
    if (r == null) return;
    await _run(
      () => ref.read(repoProvider).adminGift(b.id, r.$1, r.$2),
      '${r.$1} jour${r.$1 > 1 ? 's' : ''} de Pro offert${r.$1 > 1 ? 's' : ''} à ${b.name}',
    );
  }

  Future<void> _suspend(AdminBusiness b) async {
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text('Suspendre ${b.name} ?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Plus personne ne pourra ouvrir la boutique, et sa boutique en ligne sera fermée. '
                'Rien n’est effacé : vous pourrez la réactiver.',
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('suspend_reason'),
                controller: reason,
                autofocus: true,
                maxLines: 2,
                onChanged: (_) => set(() {}),
                decoration: const InputDecoration(labelText: 'Raison (gardée dans l’historique)'),
              ),
            ],
          ),
          actions: dialogActions([
            CancelButton(onPressed: () => Navigator.pop(ctx, false)),
            ConfirmButton(
              danger: true,
              label: 'Suspendre',
              onPressed: reason.text.trim().length < 3 ? null : () => Navigator.pop(ctx, true),
            ),
          ]),
        ),
      ),
    );
    if (ok != true || !mounted) return;
    if (!await confirmSensitive(context, ref, action: 'Suspendre ${b.name}')) return;
    await _run(() => ref.read(repoProvider).adminSuspend(b.id, reason.text.trim()), '${b.name} est suspendue');
  }

  Future<void> _unsuspend(AdminBusiness b) =>
      _run(() => ref.read(repoProvider).adminUnsuspend(b.id), '${b.name} est réactivée');

  Future<void> _restore(AdminBusiness b) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Restaurer ${b.name} ?'),
        content: const Text('À faire seulement si le propriétaire le demande. Toutes ses données reviennent.'),
        actions: dialogActions([
          CancelButton(onPressed: () => Navigator.pop(ctx, false)),
          ConfirmButton(label: 'Restaurer', onPressed: () => Navigator.pop(ctx, true)),
        ]),
      ),
    );
    if (ok == true) await _run(() => ref.read(repoProvider).adminRestore(b.id), '${b.name} est restaurée');
  }

  void _whatsApp(AdminBusiness b) {
    final digits = b.ownerPhone.replaceAll(RegExp(r'\D'), '');
    final hello = 'Bonjour${b.ownerName == null ? '' : ' ${b.ownerName!.split(' ').first}'}, c’est l’équipe Sama360. ';
    ref.read(openUrlProvider)(Uri.parse('https://wa.me/$digits?text=${Uri.encodeComponent(hello)}'));
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(adminBusinessProvider(widget.id));
    final wide = MediaQuery.sizeOf(context).width >= adminWide;
    final d = data.value;
    return AdminShell(
      section: AdminSection.merchants,
      back: true,
      title: d?.business.name ?? 'Boutique',
      subtitle: d == null
          ? null
          : '${d.business.country.name} · inscrite le ${DateFormat('d MMMM y', 'fr').format(d.business.createdAt)}',
      child: AsyncView<AdminBusinessDetail>(
        value: data,
        onRetry: () => ref.invalidate(adminBusinessProvider(widget.id)),
        data: (d) {
          final b = d.business;
          final left = <Widget>[
            _Header(
              d: d,
              busy: _busy,
              onWhatsApp: () => _whatsApp(b),
              onCall: () => ref.read(openUrlProvider)(Uri.parse('tel:${b.ownerPhone}')),
            ),
            TileGrid(
              max: 4,
              minTile: 150,
              height: 132,
              children: [
                KpiTile(
                  icon: Icons.point_of_sale_rounded,
                  color: const Color(0xFF0F9D6B),
                  label: 'Ventes 30 j',
                  value: compactMoney(b.revenue30),
                  hint: '${b.sales30} vente${b.sales30 > 1 ? 's' : ''}',
                ),
                KpiTile(
                  icon: Icons.schedule_rounded,
                  color: const Color(0xFFEA580C),
                  label: 'Dernière vente',
                  value: sinceLabel(b.lastSaleAt),
                  hint: '${b.sales7} cette semaine',
                ),
                KpiTile(
                  icon: Icons.inventory_2_rounded,
                  color: const Color(0xFF7C3AED),
                  label: 'Produits',
                  value: '${b.products}',
                ),
                KpiTile(
                  icon: Icons.people_alt_rounded,
                  color: const Color(0xFF2563EB),
                  label: 'Clients',
                  value: '${b.customers}',
                ),
              ],
            ),
            AdminCard(
              title: 'Paiements Pro',
              child: d.payments.isEmpty
                  ? Text('Aucun paiement', style: TextStyle(color: AppColors.muted))
                  : Column(children: [for (final p in d.payments) PaymentTile(p: p, showBusiness: false)]),
            ),
            AdminCard(
              title: 'Historique de l’équipe',
              child: d.actions.isEmpty
                  ? Text('Aucune action pour l’instant', style: TextStyle(color: AppColors.muted))
                  : Column(
                      children: [
                        for (final a in d.actions)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            leading: Icon(switch (a.action) {
                              'gift' => Icons.card_giftcard_rounded,
                              'suspend' => Icons.block_rounded,
                              'unsuspend' => Icons.play_circle_outline_rounded,
                              _ => Icons.restore_rounded,
                            }, color: AppColors.muted),
                            title: Text(a.label, style: const TextStyle(fontWeight: FontWeight.w700)),
                            subtitle: Text('${a.by} · ${DateFormat('d MMM y, HH:mm', 'fr').format(a.at)}'),
                          ),
                      ],
                    ),
            ),
          ];
          final right = <Widget>[
            _Actions(
              d: d,
              busy: _busy,
              onGift: () => _gift(b),
              onSuspend: () => _suspend(b),
              onUnsuspend: () => _unsuspend(b),
              onRestore: () => _restore(b),
            ),
            AdminCard(
              title: 'Équipe (${d.members.length})',
              child: Column(
                children: [
                  for (final m in d.members)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      leading: CircleAvatar(
                        backgroundColor: AppColors.greenSoft,
                        child: Icon(
                          m.roleKey == 'owner' ? Icons.star_rounded : Icons.person_rounded,
                          color: AppColors.green,
                          size: 20,
                        ),
                      ),
                      title: Text(m.name ?? intlPhone(m.phone), style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text('${m.role} · ${intlPhone(m.phone)}'),
                    ),
                ],
              ),
            ),
            AdminCard(
              title: 'Points de vente (${d.locations.length})',
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final l in d.locations)
                    Chip(
                      avatar: Icon(l.main ? Icons.home_work_rounded : Icons.store_rounded, size: 16),
                      label: Text(l.name),
                    ),
                  if (d.locations.isEmpty) Text('—', style: TextStyle(color: AppColors.muted)),
                ],
              ),
            ),
            AdminCard(
              title: 'Parrainage',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (d.referralCode != null)
                    Text('Code : ${d.referralCode}', style: const TextStyle(fontWeight: FontWeight.w700)),
                  if (d.referredBy != null)
                    TextButton.icon(
                      style: TextButton.styleFrom(minimumSize: const Size(0, 40), padding: EdgeInsets.zero),
                      onPressed: () => context.push('/admin/merchants/${d.referredBy!.id}'),
                      icon: const Icon(Icons.call_received_rounded, size: 18),
                      label: Text('Parrainée par ${d.referredBy!.name}'),
                    ),
                  Text(
                    d.referrals.isEmpty
                        ? 'N’a encore parrainé personne'
                        : 'A parrainé ${d.referrals.length} boutique${d.referrals.length > 1 ? 's' : ''}',
                    style: TextStyle(color: AppColors.muted),
                  ),
                  for (final r in d.referrals)
                    TextButton(
                      style: TextButton.styleFrom(minimumSize: const Size(0, 36), padding: EdgeInsets.zero),
                      onPressed: () => context.push('/admin/merchants/${r.id}'),
                      child: Text(r.name),
                    ),
                ],
              ),
            ),
          ];
          List<Widget> spaced(List<Widget> w) => [
            for (var i = 0; i < w.length; i++) ...[if (i > 0) const SizedBox(height: 14), w[i]],
          ];
          final pad = wide ? 28.0 : 16.0;
          return RefreshIndicator(
            onRefresh: () => ref.refresh(adminBusinessProvider(widget.id).future),
            child: ListView(
              padding: EdgeInsets.fromLTRB(pad, 0, pad, 32),
              children: wide
                  ? [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            flex: 3,
                            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: spaced(left)),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            flex: 2,
                            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: spaced(right)),
                          ),
                        ],
                      ),
                    ]
                  : spaced([left.first, right.first, ...left.skip(1), ...right.skip(1)]),
            ),
          );
        },
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.d, required this.busy, required this.onWhatsApp, required this.onCall});
  final AdminBusinessDetail d;
  final bool busy;
  final VoidCallback onWhatsApp;
  final VoidCallback onCall;

  @override
  Widget build(BuildContext context) {
    final b = d.business;
    const muted = Color(0xFFCDE9DD);
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
                Row(
                  children: [
                    ShopAvatar(b.name, size: 54),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            b.name,
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 20),
                          ),
                          Text('sama360.com/${b.slug}', style: const TextStyle(color: muted, fontSize: 12.5)),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              PlanBadge(b.plan, daysLeft: b.daysLeft),
                              StatusBadge(b.status),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (d.suspendedReason != null) ...[
                  const SizedBox(height: 12),
                  _Note(icon: Icons.block_rounded, text: 'Suspendue : ${d.suspendedReason}'),
                ],
                if (d.purgeAt != null) ...[
                  const SizedBox(height: 12),
                  _Note(
                    icon: Icons.delete_outline_rounded,
                    text: 'Supprimée par le propriétaire · effacée le ${DateFormat('d MMMM', 'fr').format(d.purgeAt!)}',
                  ),
                ],
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.person_rounded, color: muted, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              b.ownerName ?? 'Propriétaire',
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
                            ),
                            Text(intlPhone(b.ownerPhone), style: const TextStyle(color: muted, fontSize: 12.5)),
                          ],
                        ),
                      ),
                      IconButton(
                        key: const Key('admin_call'),
                        tooltip: 'Appeler',
                        onPressed: onCall,
                        icon: const Icon(Icons.call_rounded, color: Colors.white),
                      ),
                      IconButton(
                        key: const Key('admin_whatsapp'),
                        tooltip: 'Écrire sur WhatsApp',
                        onPressed: onWhatsApp,
                        icon: const Icon(Icons.chat_rounded, color: AppColors.whatsapp),
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

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: const Color(0xFFFFB4A8).withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        Icon(icon, color: const Color(0xFFFFD2CB), size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
          ),
        ),
      ],
    ),
  );
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.d,
    required this.busy,
    required this.onGift,
    required this.onSuspend,
    required this.onUnsuspend,
    required this.onRestore,
  });
  final AdminBusinessDetail d;
  final bool busy;
  final VoidCallback onGift, onSuspend, onUnsuspend, onRestore;

  @override
  Widget build(BuildContext context) {
    final s = d.business.status;
    final b = d.business;
    final plan = b.plan;
    final end = b.planEndsAt;
    return AdminCard(
      title: 'Abonnement',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(switch (plan) {
            AdminPlan.active => 'Pro jusqu’au ${end == null ? '—' : DateFormat('d MMMM y', 'fr').format(end)}',
            AdminPlan.trial => 'Essai gratuit, encore ${b.daysLeft} jour${b.daysLeft > 1 ? 's' : ''}',
            AdminPlan.expired => 'Pro expiré${end == null ? '' : ' le ${DateFormat('d MMMM', 'fr').format(end)}'}',
            AdminPlan.free => 'Version gratuite',
          }, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          Text(
            b.everPaid ? 'A déjà payé Sama360 Pro' : 'N’a jamais payé',
            style: TextStyle(color: AppColors.muted, fontSize: 12.5),
          ),
          const SizedBox(height: 14),
          if (s == AdminStatus.deleted)
            FilledButton.icon(
              key: const Key('admin_restore'),
              onPressed: busy ? null : onRestore,
              icon: const Icon(Icons.restore_rounded),
              label: const Text('Restaurer la boutique'),
            )
          else ...[
            FilledButton.icon(
              key: const Key('admin_gift'),
              onPressed: busy ? null : onGift,
              icon: const Icon(Icons.card_giftcard_rounded),
              label: const Text('Offrir des jours de Pro'),
            ),
            const SizedBox(height: 8),
            if (s == AdminStatus.suspended)
              OutlinedButton.icon(
                key: const Key('admin_unsuspend'),
                onPressed: busy ? null : onUnsuspend,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('Réactiver la boutique'),
              )
            else
              OutlinedButton.icon(
                key: const Key('admin_suspend'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.danger,
                  side: BorderSide(color: AppColors.danger.withValues(alpha: 0.5)),
                ),
                onPressed: busy ? null : onSuspend,
                icon: const Icon(Icons.block_rounded),
                label: const Text('Suspendre'),
              ),
          ],
        ],
      ),
    );
  }
}

class _GiftDialog extends StatefulWidget {
  const _GiftDialog({required this.name});
  final String name;
  @override
  State<_GiftDialog> createState() => _GiftDialogState();
}

class _GiftDialogState extends State<_GiftDialog> {
  int _days = 30;
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Offrir du Pro à ${widget.name}'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Ajouté à la fin de son abonnement ou de son essai. Le commerçant est prévenu.'),
        const SizedBox(height: 12),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final (d, label) in const [
              (7, '7 jours'),
              (15, '15 jours'),
              (30, '1 mois'),
              (90, '3 mois'),
              (365, '1 an'),
            ])
              Pill(key: Key('gift_$d'), label: label, selected: _days == d, onTap: () => setState(() => _days = d)),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('gift_reason'),
          controller: _reason,
          maxLength: 200,
          decoration: const InputDecoration(labelText: 'Message (facultatif)', hintText: 'Ex. Désolé pour la coupure'),
        ),
      ],
    ),
    actions: dialogActions([
      CancelButton(onPressed: () => Navigator.pop(context)),
      ConfirmButton(
        label: 'Offrir',
        onPressed: () => Navigator.pop(context, (_days, _reason.text.trim().isEmpty ? null : _reason.text.trim())),
      ),
    ]),
  );
}
