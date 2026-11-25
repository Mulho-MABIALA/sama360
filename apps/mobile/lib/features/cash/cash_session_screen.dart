import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdf/pdf.dart';

import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../auth/auth_controller.dart';
import '../sales/receipt_screen.dart' show receiptActionsProvider;
import 'cash_close_screen.dart';
import 'cash_pdf.dart';
import 'cash_screen.dart';

/// Rapport Z d'une caisse (ou état en direct si elle est encore ouverte).
class CashSessionScreen extends ConsumerStatefulWidget {
  const CashSessionScreen({super.key, required this.sessionId});
  final String sessionId;
  @override
  ConsumerState<CashSessionScreen> createState() => _CashSessionScreenState();
}

class _CashSessionScreenState extends ConsumerState<CashSessionScreen> {
  bool _busy = false;

  Future<void> _pdf(CashSession s, {required bool print}) async {
    setState(() => _busy = true);
    try {
      final b = await ref.read(currentBusinessProvider.future);
      final bytes = await buildCashZPdf(s, b);
      final actions = ref.read(receiptActionsProvider);
      if (print) {
        await actions.printPdf(bytes, s.number, format: PdfPageFormat.roll80);
      } else {
        await actions.sharePdf(bytes, cashFileName(s));
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(cashSessionProvider(widget.sessionId));
    final canManage = ref.watch(canProvider('sales:void'));
    final me = ref.watch(authProvider).value?.me?.id;
    final s = session.value;
    return AuroraScaffold(
      appBar: AppBar(
        title: Text(s?.number ?? 'Caisse', style: const TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          if (s != null) ...[
            IconButton(
              tooltip: 'Imprimer le rapport',
              onPressed: _busy ? null : () => _pdf(s, print: true),
              icon: const Icon(Icons.print_rounded),
            ),
            IconButton(
              tooltip: 'Partager le rapport (PDF)',
              onPressed: _busy ? null : () => _pdf(s, print: false),
              icon: const Icon(Icons.ios_share_rounded),
            ),
          ],
        ],
      ),
      body: AsyncView<CashSession>(
        value: session,
        onRetry: () => ref.invalidate(cashSessionProvider(widget.sessionId)),
        data: (s) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
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
                        Text(
                          s.open ? 'Caisse ouverte' : 'Résumé de caisse',
                          style: const TextStyle(color: Color(0xFFCDE9DD), fontSize: 12.5),
                        ),
                        Text(
                          s.userName ?? '',
                          style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800),
                        ),
                        Text(
                          '${dateTime(s.openedAt)}${s.closedAt == null ? '' : ' – ${hourOf(s.closedAt!)}'}',
                          style: const TextStyle(color: Color(0xFFCDE9DD), fontSize: 12.5),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: _Big(label: 'Ventes', value: '${s.report.salesCount}'),
                            ),
                            Expanded(
                              child: _Big(label: 'Chiffre d’affaires', value: moneyShort(s.report.salesTotal)),
                            ),
                            if (s.difference != null)
                              Expanded(
                                child: _Big(
                                  label: 'Écart',
                                  value: s.difference == 0
                                      ? 'Juste'
                                      : '${s.difference! > 0 ? '+' : '−'}${moneyShort(s.difference!.abs())}',
                                  color: s.difference == 0
                                      ? AppColors.glow
                                      : s.difference! < 0
                                      ? const Color(0xFFFFB199)
                                      : const Color(0xFFFFC28F),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (s.lines != null) ...[
              const SizedBox(height: 14),
              const Text('Comptage', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Card(
                child: Column(
                  children: [
                    for (final (i, l) in s.lines!.indexed) ...[
                      ListTile(
                        leading: PayLogo(l.method, size: 26, color: AppColors.green),
                        title: Text(l.method.label, style: const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text.rich(
                          TextSpan(
                            children: [
                              const TextSpan(text: 'Attendu '),
                              TextSpan(
                                text: moneyShort(l.expected),
                                style: TextStyle(color: AppColors.green, fontWeight: FontWeight.w800),
                              ),
                              const TextSpan(text: ' · compté '),
                              TextSpan(
                                text: moneyShort(l.counted),
                                style: TextStyle(color: AppColors.green, fontWeight: FontWeight.w800),
                              ),
                            ],
                          ),
                          style: const TextStyle(fontSize: 13),
                        ),
                        trailing: DifferenceText(value: l.difference),
                      ),
                      if (i < s.lines!.length - 1) const Divider(height: 1, indent: 14, endIndent: 14),
                    ],
                  ],
                ),
              ),
            ],
            const SizedBox(height: 14),
            const Text('Détail par moyen de paiement', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            for (final m in s.report.methods)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: CashMethodTile(line: m),
              ),
            if (s.report.creditTotal > 0 || s.report.voidedCount > 0)
              Glass(
                radius: 18,
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (s.report.creditTotal > 0)
                      Text.rich(
                        TextSpan(
                          children: [
                            const TextSpan(text: 'Dont vendu à crédit : '),
                            TextSpan(
                              text: money(s.report.creditTotal),
                              style: TextStyle(color: AppColors.warnText, fontWeight: FontWeight.w800),
                            ),
                          ],
                        ),
                      ),
                    if (s.report.voidedCount > 0)
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(text: '${s.report.voidedCount} vente(s) annulée(s) : '),
                            TextSpan(
                              text: money(s.report.voidedTotal),
                              style: TextStyle(color: AppColors.danger, fontWeight: FontWeight.w800),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            if (s.movements.isNotEmpty) ...[
              const SizedBox(height: 14),
              const Text('Entrées et sorties', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              CashMovementsCard(movements: s.movements),
            ],
            if ((s.closingNote ?? '').isNotEmpty) ...[
              const SizedBox(height: 10),
              Text('Note : ${s.closingNote}', style: TextStyle(color: AppColors.muted)),
            ],
            if (s.open && s.userId != me && canManage) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => context.push('/cash/close?session=${s.id}'),
                icon: const Icon(Icons.lock_clock_rounded),
                label: const Text('Fermer cette caisse'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Big extends StatelessWidget {
  const _Big({required this.label, required this.value, this.color = Colors.white});
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        value,
        style: TextStyle(color: color, fontSize: 18, fontWeight: FontWeight.w800),
      ),
      Text(label, style: const TextStyle(color: Color(0xFFCDE9DD), fontSize: 11.5)),
    ],
  );
}

/// Historique des caisses : les miennes, ou celles de tous les vendeurs pour le gérant.
class CashHistoryScreen extends ConsumerWidget {
  const CashHistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(cashSessionsProvider);
    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Historique des caisses', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: AsyncView<List<CashSessionSummary>>(
        value: list,
        onRetry: () => ref.invalidate(cashSessionsProvider),
        data: (rows) => rows.isEmpty
            ? Center(
                child: Text('Aucune caisse pour l’instant', style: TextStyle(color: AppColors.muted)),
              )
            : RefreshIndicator(
                onRefresh: () async => ref.invalidate(cashSessionsProvider),
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final c = rows[i];
                    return Card(
                      child: ListTile(
                        onTap: () => context.push('/cash/sessions/${c.id}'),
                        leading: Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: c.open ? AppColors.greenSoft : AppColors.line,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Icon(
                            c.open ? Icons.lock_open_rounded : Icons.lock_rounded,
                            color: c.open ? AppColors.green : AppColors.muted,
                          ),
                        ),
                        title: Text(
                          '${c.userName ?? c.number} · ${dateTime(c.openedAt)}',
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                        ),
                        subtitle: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: c.open
                                    ? '${c.number} · ouverte'
                                    : '${c.number} · ${c.salesCount ?? 0} vente(s) · ',
                              ),
                              if (!c.open)
                                TextSpan(
                                  text: moneyShort(c.salesTotal ?? 0),
                                  style: TextStyle(color: AppColors.green, fontWeight: FontWeight.w800),
                                ),
                            ],
                          ),
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: c.open
                            ? Text(
                                'Ouverte',
                                style: TextStyle(color: AppColors.green, fontWeight: FontWeight.w800),
                              )
                            : DifferenceText(value: c.difference),
                      ),
                    );
                  },
                ),
              ),
      ),
    );
  }
}
