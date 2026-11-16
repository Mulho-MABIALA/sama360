import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

String hourOf(DateTime d) => DateFormat('HH:mm', 'fr').format(d.toLocal());

/// Ma caisse : ouverture avec fond de caisse, attendu en direct, entrées et sorties, clôture.
class CashScreen extends ConsumerWidget {
  const CashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(cashCurrentProvider);
    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Ma caisse', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
            tooltip: 'Historique des caisses',
            icon: const Icon(Icons.history_rounded),
            onPressed: () => context.push('/cash/history'),
          ),
        ],
      ),
      body: AsyncView<CashSession?>(
        value: current,
        onRetry: () => ref.invalidate(cashCurrentProvider),
        data: (s) => s == null ? const _OpenForm() : _OpenSession(session: s),
      ),
    );
  }
}

class _OpenForm extends ConsumerStatefulWidget {
  const _OpenForm();
  @override
  ConsumerState<_OpenForm> createState() => _OpenFormState();
}

class _OpenFormState extends ConsumerState<_OpenForm> {
  final _float = TextEditingController();
  final _note = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _float.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    setState(() => _busy = true);
    try {
      await ref.read(repoProvider).openCash(openingFloat: int.tryParse(_float.text) ?? 0, note: _note.text);
      refreshCash(ref);
      if (mounted) showInfo(context, 'Caisse ouverte : bonnes ventes !');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
    children: [
      Glass(
        radius: 26,
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Center(
              child: GlossyOrb(icon: Icons.point_of_sale_rounded, color: AppColors.green, size: 68),
            ),
            const SizedBox(height: 14),
            const Text(
              'Ouvrir la caisse',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            const Text(
              'Comptez la monnaie de départ. Le soir, Sama360 vous dira combien vous devez avoir '
              'en espèces, Wave et Orange Money.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.muted, height: 1.4),
            ),
            const SizedBox(height: 18),
            TextField(
              key: const Key('openingFloat'),
              controller: _float,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'Fond de caisse (espèces)', suffixText: 'FCFA'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final v in const [0, 5000, 10000, 20000, 50000])
                  Pill(
                    label: v == 0 ? 'Aucun' : moneyShort(v),
                    selected: (int.tryParse(_float.text) ?? 0) == v,
                    onTap: () => setState(() => _float.text = v == 0 ? '' : '$v'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('openingNote'),
              controller: _note,
              decoration: const InputDecoration(labelText: 'Note (facultatif)'),
            ),
            const SizedBox(height: 18),
            BusyButton(label: 'Ouvrir ma caisse', busy: _busy, onPressed: _open),
          ],
        ),
      ),
    ],
  );
}

class _OpenSession extends ConsumerWidget {
  const _OpenSession({required this.session});
  final CashSession session;

  Future<void> _movement(BuildContext context, WidgetRef ref, bool isIn) async {
    final done = await showModalBottomSheet<bool>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _MovementSheet(isIn: isIn, cash: session.report.expectedCash),
    );
    if (done == true && context.mounted) {
      refreshCash(ref);
      showInfo(context, isIn ? 'Entrée enregistrée' : 'Sortie enregistrée');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = session.report;
    return Column(
      children: [
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async => refreshCash(ref),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              children: [
                Sheen(
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
                            Row(
                              children: [
                                const Icon(Icons.circle, size: 10, color: AppColors.glow),
                                const SizedBox(width: 6),
                                Text(
                                  'Ouverte à ${hourOf(session.openedAt)} · ${session.number}',
                                  style: const TextStyle(color: Color(0xFFCDE9DD), fontSize: 12.5),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            const Text('Espèces attendues', style: TextStyle(color: Color(0xFFCDE9DD), fontSize: 12.5)),
                            Text(
                              money(r.expectedCash),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 32,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.6,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 16,
                              runSpacing: 4,
                              children: [
                                _kv('Ventes', '${r.salesCount} · ${moneyShort(r.salesTotal)}'),
                                if (r.creditTotal > 0) _kv('À crédit', moneyShort(r.creditTotal)),
                                _kv('Fond', moneyShort(session.openingFloat)),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                const Text('Ce que vous devez avoir', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                for (final m in r.methods)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: CashMethodTile(line: m),
                  ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _movement(context, ref, true),
                        icon: const Icon(Icons.add_circle_outline_rounded),
                        label: const Text('Entrée'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _movement(context, ref, false),
                        icon: const Icon(Icons.remove_circle_outline_rounded),
                        label: const Text('Sortie'),
                      ),
                    ),
                  ],
                ),
                if (session.movements.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Text('Entrées et sorties', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 8),
                  CashMovementsCard(movements: session.movements),
                ],
              ],
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(10, 4, 10, 8 + MediaQuery.paddingOf(context).bottom),
          child: Glass(
            radius: 28,
            padding: const EdgeInsets.all(12),
            child: FilledButton.icon(
              onPressed: () => context.push('/cash/close'),
              icon: const Icon(Icons.lock_clock_rounded),
              label: const Text('Clôturer la caisse'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _kv(String k, String v) => Text.rich(
    TextSpan(
      children: [
        TextSpan(
          text: '$k ',
          style: const TextStyle(color: Color(0xFFCDE9DD), fontSize: 12.5),
        ),
        TextSpan(
          text: v,
          style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w700),
        ),
      ],
    ),
  );
}

/// Attendu d'un moyen de paiement, avec le détail (fond, ventes, dépenses…) à déplier.
class CashMethodTile extends StatelessWidget {
  const CashMethodTile({super.key, required this.line});
  final CashMethodLine line;

  static IconData iconOf(PayMethod m) => switch (m) {
    PayMethod.cash => Icons.payments_rounded,
    PayMethod.card => Icons.credit_card_rounded,
    PayMethod.transfer => Icons.account_balance_rounded,
    PayMethod.cheque => Icons.receipt_rounded,
    _ => Icons.phone_android_rounded,
  };

  @override
  Widget build(BuildContext context) => Glass(
    radius: 18,
    padding: EdgeInsets.zero,
    child: Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        shape: const RoundedRectangleBorder(),
        leading: Icon(iconOf(line.method), color: AppColors.green),
        title: Text(line.method.label, style: const TextStyle(fontWeight: FontWeight.w700)),
        trailing: Text(money(line.expected), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          for (final (label, amount) in line.breakdown)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Expanded(
                    child: Text(label, style: const TextStyle(color: AppColors.muted, fontSize: 13)),
                  ),
                  Text(
                    '${amount < 0 ? '−' : '+'} ${moneyShort(amount.abs())}',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: amount < 0 ? AppColors.danger : AppColors.ink,
                    ),
                  ),
                ],
              ),
            ),
          if (line.breakdown.isEmpty)
            const Text('Aucun mouvement', style: TextStyle(color: AppColors.muted, fontSize: 13)),
        ],
      ),
    ),
  );
}

class CashMovementsCard extends StatelessWidget {
  const CashMovementsCard({super.key, required this.movements});
  final List<CashMovement> movements;

  @override
  Widget build(BuildContext context) => Card(
    child: Column(
      children: [
        for (final (i, m) in movements.indexed) ...[
          ListTile(
            leading: Icon(
              m.isIn ? Icons.south_west_rounded : Icons.north_east_rounded,
              color: m.isIn ? AppColors.green : AppColors.danger,
            ),
            title: Text(m.reason, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            subtitle: Text(
              '${hourOf(m.createdAt)}${m.createdByName == null ? '' : ' · ${m.createdByName}'}',
              style: const TextStyle(fontSize: 12),
            ),
            trailing: Text(
              '${m.isIn ? '+' : '−'} ${moneyShort(m.amount)}',
              style: TextStyle(fontWeight: FontWeight.w800, color: m.isIn ? AppColors.green : AppColors.danger),
            ),
          ),
          if (i < movements.length - 1) const Divider(height: 1, indent: 14, endIndent: 14),
        ],
      ],
    ),
  );
}

class _MovementSheet extends ConsumerStatefulWidget {
  const _MovementSheet({required this.isIn, required this.cash});
  final bool isIn;
  final int cash;
  @override
  ConsumerState<_MovementSheet> createState() => _MovementSheetState();
}

class _MovementSheetState extends ConsumerState<_MovementSheet> {
  final _amount = TextEditingController();
  final _reason = TextEditingController();
  bool _busy = false;

  List<String> get _presets => widget.isIn
      ? const ['Appoint du gérant', 'Monnaie ajoutée']
      : const ['Dépôt à la banque', 'Remis au gérant', 'Monnaie rendue'];

  @override
  void dispose() {
    _amount.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final a = int.tryParse(_amount.text) ?? 0;
    if (a <= 0) return showInfo(context, 'Indiquez le montant');
    if (_reason.text.trim().length < 3) return showInfo(context, 'Indiquez la raison');
    if (!widget.isIn && a > widget.cash) {
      return showInfo(context, 'Il n’y a que ${money(widget.cash)} en espèces dans la caisse');
    }
    setState(() => _busy = true);
    try {
      await ref.read(repoProvider).cashMovement(isIn: widget.isIn, amount: a, reason: _reason.text);
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
        Text(
          widget.isIn ? 'Entrée d’argent' : 'Sortie d’argent',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        Text(
          widget.isIn
              ? 'Espèces ajoutées dans la caisse (hors ventes)'
              : 'Espèces retirées de la caisse (hors dépenses : utilisez « Dépense »)',
          style: const TextStyle(color: AppColors.muted, fontSize: 13),
        ),
        const SizedBox(height: 14),
        TextField(
          key: const Key('movementAmount'),
          controller: _amount,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(labelText: 'Montant', suffixText: 'FCFA'),
        ),
        const SizedBox(height: 10),
        TextField(
          key: const Key('movementReason'),
          controller: _reason,
          decoration: const InputDecoration(labelText: 'Raison'),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final p in _presets)
              Pill(label: p, selected: _reason.text == p, onTap: () => setState(() => _reason.text = p)),
          ],
        ),
        const SizedBox(height: 16),
        BusyButton(label: 'Enregistrer', busy: _busy, onPressed: _save),
      ],
    ),
  );
}
