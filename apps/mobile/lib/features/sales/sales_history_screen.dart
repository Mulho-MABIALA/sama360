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

/// Ventes du jour : retrouver une vente et renvoyer son reçu.
class SalesHistoryScreen extends ConsumerWidget {
  const SalesHistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sales = ref.watch(salesTodayProvider);
    return AuroraScaffold(
      appBar: AppBar(
        title: const Text("Ventes d'aujourd'hui", style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: AsyncView<List<SaleSummary>>(
        value: sales,
        onRetry: () => ref.invalidate(salesTodayProvider),
        data: (list) {
          final done = list.where((s) => s.status == 'completed');
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
                      child: StatTile(label: "Chiffre d'affaires", value: moneyShort(total)),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (list.isEmpty)
                  const Padding(
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
                        leading: Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: s.status == 'voided' ? const Color(0xFFFBEAEA) : AppColors.greenSoft,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            s.status == 'voided' ? Icons.block_rounded : Icons.receipt_long_rounded,
                            color: s.status == 'voided' ? AppColors.danger : AppColors.green,
                          ),
                        ),
                        title: Text(s.number, style: const TextStyle(fontWeight: FontWeight.w800)),
                        subtitle: Text(
                          [
                            DateFormat('HH:mm', 'fr').format(s.soldAt.toLocal()),
                            if (s.customerName != null) s.customerName!,
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
                                fontSize: 14,
                                color: AppColors.ink,
                                fontWeight: FontWeight.w800,
                                decoration: s.status == 'voided' ? TextDecoration.lineThrough : null,
                              ),
                            ),
                            if (s.due > 0 && s.status != 'voided')
                              Text(
                                'Crédit ${moneyShort(s.due)}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.warnText,
                                ),
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
