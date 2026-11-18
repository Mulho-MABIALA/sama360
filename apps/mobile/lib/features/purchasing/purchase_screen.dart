import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdf/pdf.dart';

import '../auth/pin_screen.dart' show confirmSensitive;
import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../sales/receipt_screen.dart' show receiptActionsProvider, whatsAppUri;
import 'purchase_pdf.dart';
import 'purchases_screen.dart';

/// Détail d'un bon de commande : lignes commandées et reçues, réceptions, paiements, actions.
class PurchaseScreen extends ConsumerStatefulWidget {
  const PurchaseScreen({super.key, required this.purchaseId});
  final String purchaseId;
  @override
  ConsumerState<PurchaseScreen> createState() => _PurchaseScreenState();
}

class _PurchaseScreenState extends ConsumerState<PurchaseScreen> {
  String? _busy;

  Future<void> _run(String key, Future<void> Function() task, {String? done}) async {
    setState(() => _busy = key);
    try {
      await task();
      refreshPurchasing(ref);
      if (done != null && mounted) showInfo(context, done);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<List<int>> _pdf(PurchaseDetail d) async {
    final b = await ref.read(currentBusinessProvider.future);
    final logo = b.logoFileId == null ? null : await ref.read(repoProvider).fileBytes(b.logoFileId!);
    return buildPurchasePdf(d, b, logo: logo);
  }

  Future<void> _receive(PurchaseDetail d) async {
    final done = await showModalBottomSheet<bool>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ReceiveSheet(detail: d),
    );
    if (done == true && mounted) {
      refreshPurchasing(ref);
      showInfo(context, 'Marchandise reçue : le stock est à jour');
    }
  }

  Future<void> _pay(PurchaseDetail d) async {
    final done = await showModalBottomSheet<bool>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => PaySheet(
        title: 'Payer ${d.supplier.name}',
        subtitle: d.summary.due > 0
            ? 'Reste à payer sur ${d.number} : ${money(d.summary.due)}'
            : 'Paiement d’avance sur ${d.number}',
        max: d.summary.due > 0 ? d.summary.due : d.payable,
        onPay: (amount, method) => ref.read(repoProvider).payPurchase(d.id, amount: amount, method: method),
      ),
    );
    if (done == true && mounted) {
      refreshPurchasing(ref);
      showInfo(context, 'Paiement enregistré');
    }
  }

  Future<void> _cancel(PurchaseDetail d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Annuler ${d.number} ?'),
        content: const Text('La commande reste dans l’historique, marquée « Annulé ».'),
        actions: [
          CancelButton(label: 'Retour', onPressed: () => Navigator.pop(ctx, false)),
          ConfirmButton(danger: true, label: 'Oui, annuler', onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (!await confirmSensitive(context, ref, action: 'Annuler la commande ${d.number}')) return;
    await _run('cancel', () => ref.read(repoProvider).cancelPurchase(d.id), done: 'Commande annulée');
  }

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(purchaseProvider(widget.purchaseId));
    final canWrite = ref.watch(canProvider('inventory:write'));
    final d = detail.value;
    return AuroraScaffold(
      appBar: AppBar(
        title: Text(d?.number ?? 'Bon de commande', style: const TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          if (d != null)
            PopupMenuButton<String>(
              tooltip: 'Plus d’actions',
              onSelected: (v) async {
                final actions = ref.read(receiptActionsProvider);
                switch (v) {
                  case 'whatsapp':
                    final b = await ref.read(currentBusinessProvider.future);
                    await actions.openWhatsApp(whatsAppUri(purchaseText(d, b), phone: d.supplier.phone));
                  case 'pdf':
                    await _run('pdf', () async => actions.sharePdf(await _pdf(d), purchaseFileName(d)));
                  case 'print':
                    await _run(
                      'print',
                      () async => actions.printPdf(await _pdf(d), d.number, format: PdfPageFormat.a4),
                    );
                  case 'edit':
                    if (context.mounted) context.push('/purchases/${d.id}/edit');
                  case 'cancel':
                    await _cancel(d);
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'whatsapp',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.chat_rounded),
                    title: Text('Envoyer au fournisseur'),
                  ),
                ),
                const PopupMenuItem(
                  value: 'pdf',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.picture_as_pdf_outlined),
                    title: Text('Bon de commande (PDF)'),
                  ),
                ),
                const PopupMenuItem(
                  value: 'print',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.print_rounded),
                    title: Text('Imprimer'),
                  ),
                ),
                if (canWrite && d.editable)
                  const PopupMenuItem(
                    value: 'edit',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.edit_outlined),
                      title: Text('Modifier'),
                    ),
                  ),
                if (canWrite && d.status.open && d.summary.receivedTotal == 0 && d.summary.paid == 0)
                  PopupMenuItem(
                    value: 'cancel',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.block_rounded, color: AppColors.danger),
                      title: Text('Annuler la commande'),
                    ),
                  ),
              ],
            ),
        ],
      ),
      body: AsyncView<PurchaseDetail>(
        value: detail,
        onRetry: () => ref.invalidate(purchaseProvider(widget.purchaseId)),
        data: (d) => Column(
          children: [
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async => ref.invalidate(purchaseProvider(widget.purchaseId)),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: [
                    _Header(d: d),
                    const SizedBox(height: 12),
                    _Amounts(d: d),
                    const SizedBox(height: 16),
                    const Text('Produits', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    Card(
                      child: Column(
                        children: [
                          for (final (i, l) in d.lines.indexed) ...[
                            _LineRow(line: l, showReceived: d.status != PurchaseStatus.draft),
                            if (i < d.lines.length - 1) const Divider(height: 1, indent: 14, endIndent: 14),
                          ],
                        ],
                      ),
                    ),
                    if ((d.note ?? '').isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Glass(
                        radius: 18,
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          children: [
                            Icon(Icons.sticky_note_2_outlined, size: 20, color: AppColors.muted),
                            const SizedBox(width: 10),
                            Expanded(child: Text(d.note!, style: const TextStyle(fontSize: 13.5))),
                          ],
                        ),
                      ),
                    ],
                    if (d.receipts.isNotEmpty || d.payments.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      const Text('Historique', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 8),
                      Card(child: Column(children: [for (final e in _history(d)) e])),
                    ],
                  ],
                ),
              ),
            ),
            if (canWrite) _ActionBar(d: d, busy: _busy, onReceive: _receive, onPay: _pay, run: _run),
          ],
        ),
      ),
    );
  }

  List<Widget> _history(PurchaseDetail d) {
    final items = <(DateTime, Widget)>[
      for (final r in d.receipts)
        (
          r.receivedAt,
          ListTile(
            leading: Icon(Icons.inventory_rounded, color: AppColors.green),
            title: Text(
              'Marchandise reçue${r.note == null ? '' : ' · ${r.note}'}',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
            ),
            subtitle: Text(
              '${dateTime(r.receivedAt)}${r.receivedBy == null ? '' : ' · ${r.receivedBy}'}',
              style: const TextStyle(fontSize: 12),
            ),
            trailing: Text(moneyShort(r.total), style: const TextStyle(fontWeight: FontWeight.w800)),
          ),
        ),
      for (final p in d.payments)
        (
          p.paidAt,
          ListTile(
            leading: const Icon(Icons.payments_outlined, color: Color(0xFF1F5BB8)),
            title: Text(
              'Paiement ${p.method?.label ?? ''}'.trim(),
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
            ),
            subtitle: Text(dateTime(p.paidAt), style: const TextStyle(fontSize: 12)),
            trailing: Text(
              '− ${moneyShort(p.amount)}',
              style: TextStyle(fontWeight: FontWeight.w800, color: AppColors.green),
            ),
          ),
        ),
    ]..sort((a, b) => b.$1.compareTo(a.$1));
    return [
      for (final (i, e) in items.indexed) ...[
        e.$2,
        if (i < items.length - 1) const Divider(height: 1, indent: 14, endIndent: 14),
      ],
    ];
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.d});
  final PurchaseDetail d;

  @override
  Widget build(BuildContext context) => Glass(
    radius: 22,
    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
    onTap: () => context.push('/suppliers/${d.supplier.id}'),
    child: Row(
      children: [
        Avatar(
          name: d.supplier.name,
          size: 46,
          bg: AppColors.softOf(const Color(0xFFE6EFFC), const Color(0xFF1F5BB8)),
          fg: AppColors.strongOf(const Color(0xFFE6EFFC), const Color(0xFF1F5BB8)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(d.supplier.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              Text(
                'Commandé le ${purchaseDay(d.summary.orderDate)}'
                '${d.summary.expectedDate == null || !d.status.open ? '' : ' · livraison ${purchaseDay(d.summary.expectedDate!)}'}',
                style: TextStyle(color: AppColors.muted, fontSize: 12.5),
              ),
            ],
          ),
        ),
        PurchaseStatusChip(status: d.status, late: d.summary.late()),
      ],
    ),
  );
}

class _Amounts extends StatelessWidget {
  const _Amounts({required this.d});
  final PurchaseDetail d;

  @override
  Widget build(BuildContext context) {
    final s = d.summary;
    final receivedPart = s.total == 0 ? 0.0 : (s.receivedTotal / s.total).clamp(0.0, 1.0);
    return Sheen(
      radius: 24,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: AuroraBackground(
          tone: AuroraTone.deep,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.receivedTotal > 0 ? 'Reste à payer' : 'Total commandé',
                  style: const TextStyle(color: Color(0xFFCDE9DD), fontSize: 12),
                ),
                Text(
                  money(s.receivedTotal > 0 ? s.due : s.total),
                  style: TextStyle(
                    color: s.receivedTotal > 0 && s.due == 0 ? AppColors.glow : const Color(0xFFFFC28F),
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (s.status != PurchaseStatus.draft && s.status != PurchaseStatus.cancelled) ...[
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: receivedPart,
                      minHeight: 7,
                      backgroundColor: Colors.white.withValues(alpha: 0.15),
                      color: AppColors.glow,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 16,
                    runSpacing: 4,
                    children: [
                      _kv('Commandé', moneyShort(s.total)),
                      _kv('Reçu', moneyShort(s.receivedTotal)),
                      _kv('Payé', moneyShort(s.paid)),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
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

class _LineRow extends StatelessWidget {
  const _LineRow({required this.line, required this.showReceived});
  final PurchaseLine line;
  final bool showReceived;

  @override
  Widget build(BuildContext context) {
    final complete = line.receivedQty >= line.quantity;
    final unit = line.unit == 'pièce' ? '' : ' ${line.unit}';
    return ListTile(
      title: Text(line.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
      subtitle: Text(
        '${qty(line.quantity)}$unit × ${moneyShort(line.unitCost)}'
        '${showReceived ? ' · reçu ${qty(line.receivedQty)}/${qty(line.quantity)}' : ''}',
        style: TextStyle(
          fontSize: 12.5,
          color: showReceived && complete ? AppColors.green : AppColors.muted,
          fontWeight: showReceived && complete ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      trailing: Text(moneyShort(line.total), style: const TextStyle(fontWeight: FontWeight.w800)),
    );
  }
}

class _ActionBar extends ConsumerWidget {
  const _ActionBar({
    required this.d,
    required this.busy,
    required this.onReceive,
    required this.onPay,
    required this.run,
  });
  final PurchaseDetail d;
  final String? busy;
  final Future<void> Function(PurchaseDetail) onReceive;
  final Future<void> Function(PurchaseDetail) onPay;
  final Future<void> Function(String, Future<void> Function(), {String? done}) run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final buttons = <Widget>[
      if (d.status == PurchaseStatus.draft)
        Expanded(
          child: BusyButton(
            label: 'Passer la commande',
            busy: busy == 'confirm',
            onPressed: () =>
                run('confirm', () => ref.read(repoProvider).confirmPurchase(d.id), done: 'Commande passée'),
          ),
        ),
      if (d.status.canReceive)
        Expanded(
          child: BusyButton(label: 'Réceptionner', busy: false, onPressed: () => onReceive(d)),
        ),
      if (d.payable > 0 && d.status != PurchaseStatus.draft)
        Expanded(
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: () => onPay(d),
            icon: const Icon(Icons.payments_outlined, size: 18),
            label: const Text('Payer'),
          ),
        ),
    ];
    if (buttons.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.fromLTRB(10, 4, 10, 8 + MediaQuery.paddingOf(context).bottom),
      child: Glass(
        radius: 28,
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            for (final (i, b) in buttons.indexed) ...[b, if (i < buttons.length - 1) const SizedBox(width: 10)],
          ],
        ),
      ),
    );
  }
}

/// Réception : quantités arrivées (tout le reste par défaut), prix réel, paiement au livreur.
class _ReceiveSheet extends ConsumerStatefulWidget {
  const _ReceiveSheet({required this.detail});
  final PurchaseDetail detail;
  @override
  ConsumerState<_ReceiveSheet> createState() => _ReceiveSheetState();
}

class _ReceiveSheetState extends ConsumerState<_ReceiveSheet> {
  late final _open = widget.detail.lines.where((l) => l.remaining > 0).toList();
  late final _qty = {for (final l in _open) l.id: TextEditingController(text: qty(l.remaining))};
  late final _cost = {for (final l in _open) l.id: TextEditingController(text: '${l.unitCost}')};
  final _note = TextEditingController();
  final _paid = TextEditingController();
  PayMethod _method = PayMethod.cash;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [..._qty.values, ..._cost.values, _note, _paid]) {
      c.dispose();
    }
    super.dispose();
  }

  double _q(String id) => double.tryParse(_qty[id]!.text.replaceAll(',', '.').replaceAll(RegExp(r'\s'), '')) ?? -1;
  int _c(String id) => int.tryParse(_cost[id]!.text.replaceAll(RegExp(r'\s'), '')) ?? -1;

  int get _value => _open.fold(0, (s, l) {
    final q = _q(l.id);
    final c = _c(l.id);
    return s + (q > 0 && c >= 0 ? (q * c).round() : 0);
  });

  Future<void> _save() async {
    final lines = <({String lineId, double quantity, int unitCost})>[];
    for (final l in _open) {
      final q = _q(l.id);
      final c = _c(l.id);
      if (q < 0 || c < 0) return showInfo(context, 'Vérifiez la quantité et le prix de « ${l.name} »');
      if (q > l.remaining) {
        return showInfo(context, '« ${l.name} » : ${qty(l.remaining)} au maximum restent à recevoir');
      }
      if (q > 0) lines.add((lineId: l.id, quantity: q, unitCost: c));
    }
    if (lines.isEmpty) return showInfo(context, 'Indiquez au moins une quantité reçue');
    final paid = int.tryParse(_paid.text) ?? 0;
    setState(() => _busy = true);
    try {
      await ref
          .read(repoProvider)
          .receivePurchase(
            widget.detail.id,
            lines: lines,
            note: _note.text,
            payment: paid > 0 ? (amount: paid, method: _method) : null,
          );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: MediaQuery.sizeOf(context).height * 0.85,
    child: Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Réceptionner la marchandise', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          Text(
            'Corrigez les quantités arrivées et le prix s’il a changé. Le stock et le coût d’achat moyen sont mis à jour.',
            style: TextStyle(color: AppColors.muted, fontSize: 12.5),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ListView(
              children: [
                for (final l in _open)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                        Text(
                          'Reste à recevoir : ${qty(l.remaining)}${l.unit == 'pièce' ? '' : ' ${l.unit}'}',
                          style: TextStyle(color: AppColors.muted, fontSize: 12),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                key: Key('rq_${l.id}'),
                                controller: _qty[l.id],
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                decoration: const InputDecoration(labelText: 'Reçu', isDense: true),
                                onChanged: (_) => setState(() {}),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              flex: 2,
                              child: TextField(
                                key: Key('rc_${l.id}'),
                                controller: _cost[l.id],
                                keyboardType: TextInputType.number,
                                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                                decoration: const InputDecoration(
                                  labelText: 'Prix unitaire',
                                  suffixText: 'FCFA',
                                  isDense: true,
                                ),
                                onChanged: (_) => setState(() {}),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                TextField(
                  key: const Key('receiveNote'),
                  controller: _note,
                  decoration: const InputDecoration(labelText: 'Note (facultatif)', hintText: 'Ex. 2 cartons abîmés'),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('receivePaid'),
                  controller: _paid,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(labelText: 'Payé au livreur (facultatif)', suffixText: 'FCFA'),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final m in [PayMethod.cash, ...ref.watch(countryProvider).mobileMoney])
                      Pill(label: m.label, selected: _method == m, onTap: () => setState(() => _method = m)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          BusyButton(label: 'Valider la réception · ${moneyShort(_value)}', busy: _busy, onPressed: _save),
        ],
      ),
    ),
  );
}
