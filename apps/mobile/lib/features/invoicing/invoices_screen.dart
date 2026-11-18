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
import '../business/business_logo.dart';

/// Couleurs d'un statut (fond, texte) — contrastes ≥ 4,5:1.
(Color, Color) docStatusColors(String status, {bool overdue = false}) {
  if (overdue) return AppColors.tone(const Color(0xFFFBEAEA), AppColors.danger);
  return switch (status) {
    'paid' || 'accepted' || 'invoiced' => AppColors.tone(AppColors.greenSoft, AppColors.greenDark),
    'partial' => AppColors.tone(const Color(0xFFE6F0FF), const Color(0xFF1D4FA8)),
    'unpaid' || 'pending' => AppColors.tone(AppColors.warnBg, AppColors.warnText),
    'declined' || 'cancelled' => AppColors.tone(const Color(0xFFEDEFEE), AppColors.muted),
    _ => AppColors.tone(AppColors.line, AppColors.ink),
  };
}

class DocStatusPill extends StatelessWidget {
  const DocStatusPill({super.key, required this.status, this.overdue = false});
  final String status;
  final bool overdue;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = docStatusColors(status, overdue: overdue);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(
        docStatusLabel(status, overdue: overdue),
        style: TextStyle(color: fg, fontSize: 11.5, fontWeight: FontWeight.w800),
      ),
    );
  }
}

/// Filtres de la liste des factures.
enum _InvoiceFilter {
  all('Toutes', null, false),
  open('À encaisser', 'unpaid,partial', false),
  late('En retard', null, true),
  paid('Payées', 'paid', false);

  const _InvoiceFilter(this.label, this.status, this.onlyOverdue);
  final String label;
  final String? status;
  final bool onlyOverdue;
}

class InvoicesScreen extends ConsumerStatefulWidget {
  const InvoicesScreen({super.key, this.initialKind = DocKind.invoice});
  final DocKind initialKind;
  @override
  ConsumerState<InvoicesScreen> createState() => _InvoicesScreenState();
}

class _InvoicesScreenState extends ConsumerState<InvoicesScreen> {
  late DocKind _kind = widget.initialKind;
  _InvoiceFilter _filter = _InvoiceFilter.all;

  ({DocKind kind, String? status, bool overdue}) get _query => _kind == DocKind.quote
      ? (kind: DocKind.quote, status: null, overdue: false)
      : (kind: DocKind.invoice, status: _filter.status, overdue: _filter.onlyOverdue);

  Future<void> _new() async {
    final kind = await showModalBottomSheet<DocKind>(
      useRootNavigator: true,
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (k, icon, color, text) in [
                (
                  DocKind.quote,
                  Icons.request_quote_rounded,
                  const Color(0xFF2F6FDB),
                  'Proposez un prix au client avant la commande.',
                ),
                (
                  DocKind.invoice,
                  Icons.receipt_long_rounded,
                  const Color(0xFF7A5AF8),
                  'Demandez le paiement d’une vente ou d’un service.',
                ),
              ])
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Glass(
                    radius: 20,
                    onTap: () => Navigator.pop(ctx, k),
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      children: [
                        GlossyOrb(icon: icon, color: color, size: 44),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                k == DocKind.quote ? 'Nouveau devis' : 'Nouvelle facture',
                                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                              ),
                              Text(text, style: TextStyle(color: AppColors.muted)),
                            ],
                          ),
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
    if (kind != null && mounted) context.push('/invoices/new?kind=${kind.api}');
  }

  @override
  Widget build(BuildContext context) {
    final canWrite = ref.can('invoicing:write');
    final summary = ref.watch(invoicingSummaryProvider).value;
    final docs = ref.watch(documentsProvider(_query));

    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Factures et devis', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      floatingActionButton: canWrite
          ? FloatingActionButton.extended(
              onPressed: _new,
              backgroundColor: AppColors.green,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Nouveau', style: TextStyle(fontWeight: FontWeight.w800)),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: () async => refreshInvoicing(ref),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
          children: [
            if (summary != null) _SummaryCard(summary: summary),
            const AddLogoHint(),
            const SizedBox(height: 14),
            // Factures | Devis
            Glass(
              radius: 16,
              blur: 10,
              padding: const EdgeInsets.all(4),
              child: Row(
                children: [
                  for (final k in [DocKind.invoice, DocKind.quote])
                    Expanded(
                      child: Semantics(
                        selected: _kind == k,
                        button: true,
                        child: GestureDetector(
                          onTap: () => setState(() => _kind = k),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            decoration: BoxDecoration(
                              color: _kind == k ? AppColors.ink : Colors.transparent,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              k == DocKind.invoice ? 'Factures' : 'Devis',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                color: _kind == k ? AppColors.ground : AppColors.ink,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (_kind == DocKind.invoice) ...[
              const SizedBox(height: 10),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final f in _InvoiceFilter.values)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Pill(label: f.label, selected: _filter == f, onTap: () => setState(() => _filter = f)),
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            AsyncView<List<DocSummary>>(
              value: docs,
              onRetry: () => ref.invalidate(documentsProvider(_query)),
              data: (list) => list.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        _kind == DocKind.quote
                            ? 'Aucun devis pour l’instant.\nUn devis se transforme en facture en un geste.'
                            : 'Aucune facture ici.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppColors.muted),
                      ),
                    )
                  : Column(
                      children: [
                        for (final d in list)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _DocCard(doc: d),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary});
  final InvoicingSummary summary;

  @override
  Widget build(BuildContext context) {
    const muted = Color(0xFFCDE9DD);
    return Sheen(
      radius: 26,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: AuroraBackground(
          tone: AuroraTone.deep,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const LabelWithEye('À encaisser sur factures', style: TextStyle(color: muted, fontSize: 12.5)),
                MaskedText(
                  moneyShort(summary.receivable),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.6,
                  ),
                ),
                Text(
                  '${summary.openInvoices} facture${summary.openInvoices > 1 ? 's' : ''} à encaisser',
                  style: const TextStyle(color: muted, fontSize: 12.5),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: _Mini(
                        label: 'En retard',
                        value: moneyShort(summary.overdue),
                        color: summary.overdue > 0 ? const Color(0xFFFFB4A8) : Colors.white,
                      ),
                    ),
                    Expanded(
                      child: _Mini(label: 'Devis en cours', value: '${summary.openQuotes}', color: Colors.white),
                    ),
                    Expanded(
                      child: _Mini(
                        label: 'Facturé ce mois',
                        value: moneyShort(summary.invoicedThisMonth),
                        color: AppColors.glow,
                      ),
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
  const _Mini({required this.label, required this.value, required this.color});
  final String label;
  final String value;
  final Color color;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(color: Color(0xFFCDE9DD), fontSize: 11.5)),
      FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(
          value,
          style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 15),
        ),
      ),
    ],
  );
}

class _DocCard extends StatelessWidget {
  const _DocCard({required this.doc});
  final DocSummary doc;

  @override
  Widget build(BuildContext context) {
    final d = doc;
    final when = DateFormat('d MMM', 'fr');
    final sub = [
      'du ${when.format(d.issueDate)}',
      if (d.dueDate != null && d.kind == DocKind.invoice && d.due > 0 && d.status != 'cancelled')
        'échéance ${when.format(d.dueDate!)}',
      if (d.dueDate != null && d.kind == DocKind.quote) 'valable au ${when.format(d.dueDate!)}',
    ].join(' · ');
    return Glass(
      radius: 20,
      blur: 12,
      onTap: () => context.push('/invoices/${d.id}'),
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          GlossyOrb(
            icon: d.kind == DocKind.quote ? Icons.request_quote_rounded : Icons.receipt_long_rounded,
            color: d.kind == DocKind.quote ? const Color(0xFF2F6FDB) : const Color(0xFF7A5AF8),
            size: 42,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  d.customerName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                ),
                Text(
                  d.number,
                  style: TextStyle(color: AppColors.muted, fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
                Text(sub, style: TextStyle(color: AppColors.muted, fontSize: 12)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                moneyShort(d.total),
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  decoration: d.status == 'cancelled' ? TextDecoration.lineThrough : null,
                ),
              ),
              const SizedBox(height: 4),
              DocStatusPill(status: d.status, overdue: d.overdue),
            ],
          ),
        ],
      ),
    );
  }
}
