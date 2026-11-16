import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../auth/auth_controller.dart';
import 'customer_picker.dart';

/// Carnet de crédit : qui doit combien.
class DebtorsScreen extends ConsumerWidget {
  const DebtorsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final debtors = ref.watch(debtorsProvider);
    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Carnet de crédit', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
            tooltip: 'Nouveau client',
            icon: const Icon(Icons.person_add_alt_1),
            onPressed: () async {
              final c = await createCustomerDialog(context, ref);
              if (c != null && context.mounted) showInfo(context, '${c.name} ajouté(e)');
            },
          ),
          IconButton(
            tooltip: 'Tous les clients',
            icon: const Icon(Icons.search),
            onPressed: () async {
              final c = await pickCustomer(context);
              if (c != null && context.mounted) context.push('/customers/${c.id}');
            },
          ),
        ],
      ),
      body: AsyncView<List<Debtor>>(
        value: debtors,
        onRetry: () => ref.invalidate(debtorsProvider),
        data: (list) {
          final total = list.fold(0, (s, d) => s + d.balance);
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(debtorsProvider),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              children: [
                // Carte émeraude en verre, avec reflet miroir
                Sheen(
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
                            const Text('Total à encaisser', style: TextStyle(color: Color(0xFFCDE9DD), fontSize: 12.5)),
                            Text(
                              money(total),
                              style: const TextStyle(
                                color: Color(0xFFFFC28F),
                                fontSize: 30,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.6,
                              ),
                            ),
                            Text(
                              list.isEmpty
                                  ? 'Aucun client ne vous doit d’argent'
                                  : '${list.length} client(s) vous doivent de l’argent',
                              style: const TextStyle(color: Color(0xFFCDE9DD), fontSize: 12.5),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                for (final d in list)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Card(
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                        leading: Avatar(name: d.name, size: 42, bg: AppColors.warnBg, fg: AppColors.warnText),
                        title: Text(d.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text(
                          d.firstDebtAt == null ? '' : 'Depuis le ${shortDate(d.firstDebtAt!)}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: Text(
                          money(d.balance),
                          style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.warn),
                        ),
                        onTap: () => context.push('/customers/${d.customerId}'),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Fiche client et carnet de crédit (maquette « Fiche client »).
class LedgerScreen extends ConsumerWidget {
  const LedgerScreen({super.key, required this.customerId});
  final String customerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ledger = ref.watch(ledgerProvider(customerId));
    final business = ref.watch(authProvider).value?.business?.name ?? '';
    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Fiche client', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: AsyncView<Ledger>(
        value: ledger,
        onRetry: () => ref.invalidate(ledgerProvider(customerId)),
        data: (l) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            Center(
              child: Avatar(name: l.customer.name, size: 64, bg: AppColors.warnBg, fg: AppColors.warnText),
            ),
            const SizedBox(height: 8),
            Text(
              l.customer.name,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
            ),
            if (l.customer.phone != null)
              Text(
                '+221 ${displayPhone(l.customer.phone!)}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.muted),
              ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(color: AppColors.ink, borderRadius: BorderRadius.circular(22)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l.balance >= 0 ? 'Solde dû' : 'Avoir du client',
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  Text(
                    money(l.balance.abs()),
                    style: const TextStyle(color: AppColors.saffron, fontSize: 28, fontWeight: FontWeight.w800),
                  ),
                  if (l.balance > 0) ...[
                    const SizedBox(height: 14),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: AppColors.ink,
                        minimumSize: const Size.fromHeight(46),
                        textStyle: Theme.of(
                          context,
                        ).textTheme.labelLarge?.copyWith(fontSize: 14, fontWeight: FontWeight.w800),
                      ),
                      onPressed: () => _repay(context, ref, l),
                      icon: const Icon(Icons.check, size: 18),
                      label: const Text('Enregistrer un remboursement'),
                    ),
                    if (l.customer.phone != null) ...[
                      const SizedBox(height: 8),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.whatsapp,
                          foregroundColor: const Color(0xFF08361A),
                          minimumSize: const Size.fromHeight(46),
                          textStyle: Theme.of(
                            context,
                          ).textTheme.labelLarge?.copyWith(fontSize: 14, fontWeight: FontWeight.w800),
                        ),
                        onPressed: () => _remind(context, l, business),
                        icon: const Icon(Icons.chat_rounded, size: 18),
                        label: const Text('Envoyer un rappel WhatsApp'),
                      ),
                    ],
                  ],
                ],
              ),
            ),
            const SizedBox(height: 18),
            const Text('Historique', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            if (l.entries.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Aucun mouvement', style: TextStyle(color: AppColors.muted)),
              ),
            Card(
              child: Column(
                children: [
                  for (final (i, e) in l.entries.indexed) ...[
                    _EntryTile(entry: e),
                    if (i < l.entries.length - 1) const Divider(height: 1, indent: 14, endIndent: 14),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _remind(BuildContext context, Ledger l, String business) async {
    final phone = l.customer.phone!.replaceAll('+', '');
    final text = Uri.encodeComponent(
      'Bonjour ${firstName(l.customer.name)}, petit rappel de $business : il reste ${money(l.balance)} à régler. Merci !',
    );
    final ok = await launchUrl(Uri.parse('https://wa.me/$phone?text=$text'), mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) showInfo(context, 'WhatsApp n’a pas pu être ouvert');
  }

  Future<void> _repay(BuildContext context, WidgetRef ref, Ledger l) async {
    final done = await showModalBottomSheet<bool>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _RepaySheet(customerId: l.customer.id, balance: l.balance),
    );
    if (done == true && context.mounted) {
      refreshBusinessData(ref);
      showInfo(context, 'Remboursement enregistré');
    }
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry});
  final LedgerEntry entry;

  @override
  Widget build(BuildContext context) {
    final debt = entry.amount > 0;
    final label = switch (entry.type) {
      'debt' => 'Vente à crédit${entry.note == null ? '' : ' · ${entry.note}'}',
      'repayment' => 'Remboursement ${PayMethod.fromApi(entry.method)?.label ?? ''}'.trim(),
      _ => entry.note ?? 'Ajustement',
    };
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
      title: Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
      subtitle: Text(dateTime(entry.at), style: const TextStyle(fontSize: 12)),
      trailing: Text(
        '${debt ? '+' : '−'} ${moneyShort(entry.amount.abs())}',
        style: TextStyle(fontWeight: FontWeight.w800, color: debt ? AppColors.warn : AppColors.green),
      ),
    );
  }
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
        Text('Dette actuelle : ${money(widget.balance)}', style: const TextStyle(color: AppColors.muted)),
        const SizedBox(height: 14),
        TextField(
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
            for (final m in [PayMethod.cash, PayMethod.wave, PayMethod.orangeMoney])
              Pill(label: m.label, selected: _method == m, onTap: () => setState(() => _method = m)),
          ],
        ),
        const SizedBox(height: 16),
        BusyButton(label: 'Enregistrer', busy: _busy, onPressed: _save),
      ],
    ),
  );
}
