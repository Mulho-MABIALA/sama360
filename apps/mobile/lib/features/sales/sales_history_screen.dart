import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/offline/pending_sales.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../offline/offline_ui.dart';

/// Recherche d'un reçu par son numéro (« 42 » ou « VEN-2026-0042 »), tous les jours confondus.
final saleSearchProvider = FutureProvider.autoDispose.family<List<SaleSummary>, String>(
  (ref, q) => ref.watch(repoProvider).salesByNumber(q),
);

/// Ventes du jour : retrouver une vente et renvoyer son reçu.
class SalesHistoryScreen extends ConsumerStatefulWidget {
  const SalesHistoryScreen({super.key});

  @override
  ConsumerState<SalesHistoryScreen> createState() => _SalesHistoryScreenState();
}

class _SalesHistoryScreenState extends ConsumerState<SalesHistoryScreen> {
  final _search = TextEditingController();
  String _q = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Widget _searchField() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
    child: TextField(
      key: const Key('sale_search'),
      controller: _search,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: 'N° de reçu (ex. 42)',
        prefixIcon: const Icon(Icons.receipt_long_rounded),
        suffixIcon: _q.isEmpty
            ? null
            : IconButton(
                tooltip: 'Effacer',
                icon: const Icon(Icons.close_rounded),
                onPressed: () => setState(() {
                  _search.clear();
                  _q = '';
                }),
              ),
      ),
      onChanged: (v) => setState(() => _q = v.trim()),
    ),
  );

  Widget _results() => AsyncView<List<SaleSummary>>(
    value: ref.watch(saleSearchProvider(_q)),
    onRetry: () => ref.invalidate(saleSearchProvider(_q)),
    data: (found) => found.isEmpty
        ? Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              'Aucun reçu n° $_q',
              key: const Key('sale_search_empty'),
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.muted),
            ),
          )
        : ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            children: [for (final s in found) _SaleTile(sale: s, showSeller: true)],
          ),
  );

  @override
  Widget build(BuildContext context) {
    final sales = ref.watch(salesTodayProvider);
    return AuroraScaffold(
      appBar: AppBar(
        title: Text(
          ref.can('reports:read') ? "Ventes d'aujourd'hui" : 'Mes ventes du jour',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: Column(
        children: [
          _searchField(),
          Expanded(
            child: _q.isNotEmpty
                ? _results()
                : AsyncView<List<SaleSummary>>(
                    value: sales,
                    onRetry: () => ref.invalidate(salesTodayProvider),
                    data: (list) {
                      final done = list.where((s) => s.status == 'completed');
                      // Plusieurs vendeurs aujourd'hui : on indique qui a fait chaque vente
                      final showSeller = list.map((s) => s.cashierName).whereType<String>().toSet().length > 1;
                      final total = done.fold(0, (sum, s) => sum + s.total);
                      return RefreshIndicator(
                        onRefresh: () async => ref.invalidate(salesTodayProvider),
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: StatTile(label: 'Ventes', value: '${done.length}'),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: StatTile(label: "Chiffre d'affaires", value: moneyShort(total), money: true),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            const _PendingVoids(),
                            const PendingSalesSection(),
                            if (list.isEmpty && ref.watch(pendingForBusinessProvider).isEmpty)
                              Padding(
                                padding: EdgeInsets.all(32),
                                child: Text(
                                  "Aucune vente aujourd'hui pour l'instant.",
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: AppColors.muted),
                                ),
                              ),
                            for (final s in list) _SaleTile(sale: s, showSeller: showSeller),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Une vente de la liste (aujourd'hui ou résultat de recherche).
class _SaleTile extends StatelessWidget {
  const _SaleTile({required this.sale, this.showSeller = false});
  final SaleSummary sale;
  final bool showSeller;

  @override
  Widget build(BuildContext context) {
    final s = sale;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          // Reçu en relief, vert (annulée : rouge barré)
          leading: GlossyOrb(
            icon: s.status == 'voided' ? Icons.block_rounded : Icons.receipt_long_rounded,
            color: s.status == 'voided' ? AppColors.danger : const Color(0xFF0E9F6E),
            size: 44,
          ),
          title: Text(
            s.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          subtitle: _subtitle(
            s,
            [
              DateFormat('HH:mm', 'fr').format(s.soldAt.toLocal()),
              // Le numéro reste visible, en petit
              if (s.title != s.number) s.number,
              if (s.customerName != null && s.firstItem != null) s.firstItem!,
              if (showSeller && s.cashierName != null) 'par ${firstName(s.cashierName!)}',
              if (s.status == 'voided') 'Annulée',
            ].join(' · '),
          ),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                moneyShort(s.total),
                style: TextStyle(
                  fontSize: 16,
                  // Le montant ressort : vert, annulé gris
                  color: s.status == 'voided' ? AppColors.muted : AppColors.green,
                  fontWeight: FontWeight.w900,
                  decoration: s.status == 'voided' ? TextDecoration.lineThrough : null,
                ),
              ),
              if (s.due > 0 && s.status != 'voided')
                Text(
                  'Crédit ${moneyShort(s.due)}',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.warnText),
                ),
            ],
          ),
          onTap: () => context.push('/sales/${s.id}'),
        ),
      ),
    );
  }
}

Widget _subtitle(SaleSummary s, String text) => s.voidPending
    ? Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text),
          Text(
            'Annulation demandée',
            style: TextStyle(color: AppColors.warnText, fontWeight: FontWeight.w800, fontSize: 12.5),
          ),
        ],
      )
    : Text(text);

/// Gérant : les ventes dont un vendeur demande l'annulation, en haut de la liste.
class _PendingVoids extends ConsumerWidget {
  const _PendingVoids();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(pendingVoidsProvider).value ?? const [];
    if (list.isEmpty) return const SizedBox.shrink();
    return Padding(
      key: const Key('pending_voids'),
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Text(
              list.length == 1 ? '1 demande d’annulation' : '${list.length} demandes d’annulation',
              style: TextStyle(fontWeight: FontWeight.w800, color: AppColors.warnText),
            ),
          ),
          for (final s in list) _SaleTile(sale: s, showSeller: true),
        ],
      ),
    );
  }
}
