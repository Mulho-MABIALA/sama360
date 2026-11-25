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

/// Ventes du jour : retrouver une vente et renvoyer son reçu.
class SalesHistoryScreen extends ConsumerWidget {
  const SalesHistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sales = ref.watch(salesTodayProvider);
    return AuroraScaffold(
      appBar: AppBar(
        title: Text(
          ref.can('reports:read') ? "Ventes d'aujourd'hui" : 'Mes ventes du jour',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: AsyncView<List<SaleSummary>>(
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
                for (final s in list)
                  Padding(
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
                        subtitle: Text(
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
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
