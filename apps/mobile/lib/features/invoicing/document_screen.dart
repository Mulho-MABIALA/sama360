import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdf/pdf.dart';
import 'package:uuid/uuid.dart';

import '../auth/pin_screen.dart' show confirmSensitive;
import '../../core/api/api_client.dart';
import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../sales/receipt_screen.dart' show receiptActionsProvider, whatsAppUri;
import '../business/business_logo.dart';
import 'invoice_pdf.dart';
import 'invoices_screen.dart' show DocStatusPill;

class DocumentScreen extends ConsumerStatefulWidget {
  const DocumentScreen({super.key, required this.id});
  final String id;
  @override
  ConsumerState<DocumentScreen> createState() => _DocumentScreenState();
}

class _DocumentScreenState extends ConsumerState<DocumentScreen> {
  String? _busy;

  Future<void> _run(String key, Future<void> Function() task, {String? done}) async {
    setState(() => _busy = key);
    try {
      await task();
      if (mounted && done != null) showInfo(context, done);
    } catch (e) {
      if (mounted) showError(context, e is ApiException ? e : 'Action impossible : $e');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  /// PDF avec le logo de l'entreprise s'il est disponible.
  Future<List<int>> _pdf(DocDetail d, CurrentBusiness b) async {
    final logo = b.logoFileId == null ? null : await ref.read(repoProvider).fileBytes(b.logoFileId!);
    return buildDocumentPdf(d, b, logo: logo);
  }

  Future<void> _action(DocDetail d, String action, String done) => _run(action, () async {
    await ref.read(repoProvider).quoteAction(d.id, action);
    refreshInvoicing(ref);
  }, done: done);

  Future<void> _convert(DocDetail d) => _run('convert', () async {
    final inv = await ref.read(repoProvider).convertQuote(d.id);
    refreshInvoicing(ref);
    if (mounted) context.pushReplacement('/invoices/${inv.id}');
  }, done: 'Facture créée');

  Future<void> _pay(DocDetail d) async {
    final paid = await showModalBottomSheet<bool>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _PaymentSheet(doc: d),
    );
    if (paid == true && mounted) {
      refreshInvoicing(ref);
      showInfo(context, 'Paiement enregistré');
    }
  }

  Future<void> _cancel(DocDetail d) async {
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Annuler la facture ${d.number} ?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('La marchandise revient en stock. La facture reste visible, marquée « Annulée ».'),
            const SizedBox(height: 12),
            TextField(
              key: const Key('cancelReason'),
              controller: reason,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Motif'),
            ),
          ],
        ),
        actions: [
          CancelButton(label: 'Retour', onPressed: () => Navigator.pop(ctx, false)),
          ConfirmButton(
            danger: true,
            label: 'Oui, annuler',
            onPressed: () => Navigator.pop(ctx, reason.text.trim().length >= 3),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (!await confirmSensitive(context, ref, action: 'Annuler la facture ${d.number}')) return;
    await _run('cancel', () async {
      await ref.read(repoProvider).cancelInvoice(d.id, reason.text.trim());
      refreshInvoicing(ref);
    }, done: 'Facture annulée');
  }

  @override
  Widget build(BuildContext context) {
    final doc = ref.watch(documentProvider(widget.id));
    final business = ref.watch(currentBusinessProvider);
    final canWrite = ref.can('invoicing:write');
    final actions = ref.read(receiptActionsProvider);

    return AuroraScaffold(
      appBar: AppBar(
        title: Text(doc.value?.kind.label ?? 'Document', style: const TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          if (canWrite && doc.value != null && doc.value!.isQuote && doc.value!.status != 'invoiced')
            IconButton(
              tooltip: 'Modifier le devis',
              onPressed: () => context.push('/invoices/${widget.id}/edit'),
              icon: const Icon(Icons.edit_rounded),
            ),
        ],
      ),
      body: AsyncView<DocDetail>(
        value: doc,
        onRetry: () => ref.invalidate(documentProvider(widget.id)),
        data: (d) => AsyncView<CurrentBusiness>(
          value: business,
          onRetry: () => ref.invalidate(currentBusinessProvider),
          data: (b) => Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: [
                    _StatusBanner(doc: d),
                    const SizedBox(height: 12),
                    DocumentPaper(doc: d, business: b),
                    const AddLogoHint(),
                    if (d.related != null) ...[
                      const SizedBox(height: 12),
                      Glass(
                        radius: 18,
                        onTap: () => context.push('/invoices/${d.related!.id}'),
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          children: [
                            Icon(
                              d.isQuote ? Icons.receipt_long_rounded : Icons.request_quote_rounded,
                              color: AppColors.green,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                d.isQuote ? 'Facture ${d.related!.number}' : 'Devis d’origine ${d.related!.number}',
                                style: const TextStyle(fontWeight: FontWeight.w700),
                              ),
                            ),
                            const Icon(Icons.chevron_right_rounded),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(10, 4, 10, 8 + MediaQuery.paddingOf(context).bottom),
                child: Glass(
                  radius: 28,
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ..._mainActions(d, canWrite),
                      Row(
                        children: [
                          Expanded(
                            child: _SmallAction(
                              icon: Icons.chat_rounded,
                              label: 'WhatsApp',
                              busy: _busy == 'wa',
                              onTap: () => _run('wa', () async {
                                await actions.openWhatsApp(whatsAppUri(docText(d, b), phone: d.customer.phone));
                              }),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _SmallAction(
                              icon: Icons.ios_share_rounded,
                              label: 'PDF',
                              busy: _busy == 'pdf',
                              onTap: () => _run('pdf', () async {
                                await actions.sharePdf(await _pdf(d, b), docFileName(d));
                              }),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _SmallAction(
                              icon: Icons.print_rounded,
                              label: 'Imprimer',
                              busy: _busy == 'print',
                              onTap: () => _run('print', () async {
                                await actions.printPdf(
                                  await buildDocumentPdf(d, b),
                                  d.number,
                                  format: PdfPageFormat.a4,
                                );
                              }),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Bouton principal (et secondaire) selon le type et le statut.
  List<Widget> _mainActions(DocDetail d, bool canWrite) {
    if (!canWrite) return const [];
    Widget gap() => const SizedBox(height: 10);
    if (d.isQuote) {
      return switch (d.status) {
        'pending' => [
          BusyButton(label: 'Transformer en facture', busy: _busy == 'convert', onPressed: () => _convert(d)),
          gap(),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy == null ? () => _action(d, 'accept', 'Devis accepté') : null,
                  icon: const Icon(Icons.thumb_up_alt_outlined),
                  label: const Text('Accepté'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy == null ? () => _action(d, 'decline', 'Devis refusé') : null,
                  icon: const Icon(Icons.thumb_down_alt_outlined),
                  label: const Text('Refusé'),
                ),
              ),
            ],
          ),
          gap(),
        ],
        'accepted' => [
          BusyButton(label: 'Transformer en facture', busy: _busy == 'convert', onPressed: () => _convert(d)),
          gap(),
        ],
        'declined' => [
          OutlinedButton.icon(
            onPressed: _busy == null ? () => _action(d, 'reopen', 'Devis remis en attente') : null,
            icon: const Icon(Icons.undo_rounded),
            label: const Text('Remettre en attente'),
          ),
          gap(),
        ],
        _ => const [],
      };
    }
    if (d.cancelled || d.status == 'paid') return const [];
    return [
      BusyButton(label: 'Enregistrer un paiement', busy: false, onPressed: _busy == null ? () => _pay(d) : null),
      if (d.paid == 0) ...[
        const SizedBox(height: 6),
        CancelButton(label: 'Annuler la facture', onPressed: _busy == null ? () => _cancel(d) : null),
      ] else
        gap(),
    ];
  }
}

class _SmallAction extends StatelessWidget {
  const _SmallAction({required this.icon, required this.label, required this.onTap, this.busy = false});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
    onPressed: busy ? null : onTap,
    icon: busy
        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
        : Icon(icon, size: 18),
    label: Text(label, overflow: TextOverflow.ellipsis),
  );
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.doc});
  final DocDetail doc;

  @override
  Widget build(BuildContext context) {
    final d = doc;
    final text = switch (d.status) {
      _ when d.overdue => 'Échéance dépassée : ${moneyShort(d.due)} restent à payer.',
      'unpaid' => d.dueDate == null ? 'Payable à réception.' : 'À payer avant le ${docDate(d.dueDate!)}.',
      'partial' => '${moneyShort(d.paid)} déjà payés, ${moneyShort(d.due)} restent à payer.',
      'paid' => 'Facture entièrement payée.',
      'cancelled' => 'Facture annulée${d.cancelReason == null ? '' : ' : ${d.cancelReason}'}.',
      'pending' =>
        d.dueDate == null
            ? 'En attente de la réponse du client.'
            : 'En attente de réponse · valable jusqu’au ${docDate(d.dueDate!)}.',
      'accepted' => 'Le client a accepté : transformez le devis en facture.',
      'declined' => 'Le client a refusé ce devis.',
      'invoiced' => 'Ce devis a été transformé en facture.',
      _ => '',
    };
    return Row(
      children: [
        DocStatusPill(status: d.status, overdue: d.overdue),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text, style: TextStyle(color: AppColors.muted, fontSize: 13)),
        ),
      ],
    );
  }
}

/// Aperçu du document à l'écran (même contenu que le PDF).
class DocumentPaper extends StatelessWidget {
  const DocumentPaper({super.key, required this.doc, required this.business});
  final DocDetail doc;
  final CurrentBusiness business;

  @override
  Widget build(BuildContext context) {
    final d = doc;
    final b = business;
    final small = TextStyle(fontSize: 12, color: AppColors.muted);
    Widget total(String l, String v, {bool strong = false, Color? color}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(l, style: TextStyle(fontWeight: strong ? FontWeight.w800 : FontWeight.w500)),
          ),
          Text(
            v,
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: strong ? 17 : 14, color: color),
          ),
        ],
      ),
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.line),
        boxShadow: const [BoxShadow(color: Color(0x140B3D2E), blurRadius: 24, offset: Offset(0, 10))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      b.name,
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: AppColors.green),
                    ),
                    if (b.phone != null) Text('Tél. ${b.phone}', style: small),
                    if (b.city != null) Text(b.city!, style: small),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(docTitle(d), style: const TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1)),
                  Text(
                    d.number,
                    style: TextStyle(fontWeight: FontWeight.w800, color: AppColors.green),
                  ),
                  Text(docDate(d.issueDate), style: small),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: AppColors.greenSoft, borderRadius: BorderRadius.circular(12)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(d.isQuote ? 'DEVIS POUR' : 'FACTURÉ À', style: small.copyWith(letterSpacing: 1)),
                Text(d.customer.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                if (d.customer.phone != null) Text(intlPhone(d.customer.phone!), style: small),
              ],
            ),
          ),
          const SizedBox(height: 12),
          for (final l in d.lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                        if ((l.description ?? '').isNotEmpty) Text(l.description!, style: small),
                        Text('${qty(l.quantity)} × ${moneyShort(l.unitPrice)}', style: small),
                      ],
                    ),
                  ),
                  Text(moneyShort(l.total), style: const TextStyle(fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          const Divider(height: 22),
          if (d.discount > 0) ...[
            total('Sous-total', moneyShort(d.subtotal)),
            total('Remise', '−${moneyShort(d.discount)}'),
          ],
          total('TOTAL', moneyShort(d.total), strong: true),
          if (!d.isQuote && d.paid > 0) total('Déjà payé', moneyShort(d.paid)),
          if (!d.isQuote && !d.cancelled && d.due > 0)
            total(
              'Reste à payer',
              moneyShort(d.due),
              strong: true,
              color: d.overdue ? AppColors.danger : AppColors.greenDark,
            ),
          if (d.payments.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Text('Paiements reçus', style: TextStyle(fontWeight: FontWeight.w800)),
            for (final p in d.payments)
              Text(
                '${docDate(p.paidAt.toLocal())} · ${p.method?.label ?? 'Autre'} · ${moneyShort(p.amount)}',
                style: small,
              ),
          ],
          if (d.note != null) ...[const SizedBox(height: 10), Text('Note : ${d.note}', style: small)],
          if (docDueLine(d) != null && !d.cancelled && d.status != 'paid') ...[
            const SizedBox(height: 10),
            Text(docDueLine(d)!, style: const TextStyle(fontWeight: FontWeight.w700)),
          ],
        ],
      ),
    );
  }
}

/// Paiement d'une facture : montant (reste dû proposé), moyen, référence.
class _PaymentSheet extends ConsumerStatefulWidget {
  const _PaymentSheet({required this.doc});
  final DocDetail doc;
  @override
  ConsumerState<_PaymentSheet> createState() => _PaymentSheetState();
}

class _PaymentSheetState extends ConsumerState<_PaymentSheet> {
  final _paymentId = const Uuid().v7();
  late final _amount = TextEditingController(text: '${widget.doc.due}');
  final _ref = TextEditingController();
  PayMethod _method = PayMethod.cash;
  String? _error;
  bool _busy = false;

  List<PayMethod> get _methods => [
    PayMethod.cash,
    ...ref.watch(countryProvider).mobileMoney,
    PayMethod.transfer,
    PayMethod.cheque,
  ];

  @override
  void dispose() {
    _amount.dispose();
    _ref.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final amount = int.tryParse(_amount.text.replaceAll(' ', '')) ?? 0;
    if (amount <= 0) return setState(() => _error = 'Montant invalide');
    if (amount > widget.doc.due) return setState(() => _error = 'Au maximum ${money(widget.doc.due)}');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(repoProvider)
          .payInvoice(widget.doc.id, paymentId: _paymentId, amount: amount, method: _method, reference: _ref.text);
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
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
        const Text('Enregistrer un paiement', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        Text('Reste à payer : ${money(widget.doc.due)}', style: TextStyle(color: AppColors.muted)),
        const SizedBox(height: 14),
        TextField(
          key: const Key('payAmount'),
          controller: _amount,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(labelText: 'Montant reçu', suffixText: 'F', errorText: _error),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final m in _methods)
              Pill(label: m.label, selected: _method == m, onTap: () => setState(() => _method = m)),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _ref,
          decoration: const InputDecoration(
            labelText: 'Référence (facultatif)',
            hintText: 'N° de transaction, de chèque…',
          ),
        ),
        const SizedBox(height: 16),
        BusyButton(label: 'Enregistrer', busy: _busy, onPressed: _save),
      ],
    ),
  );
}
