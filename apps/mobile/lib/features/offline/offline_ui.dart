import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/offline/pending_sales.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// Envoie les ventes en attente sans que le commerçant y pense :
/// toutes les 30 s tant qu'il en reste, au retour de l'app au premier plan,
/// et dès qu'une nouvelle vente est mise en attente.
class SyncScheduler extends ConsumerStatefulWidget {
  const SyncScheduler({super.key, required this.child, this.every = const Duration(seconds: 30)});
  final Widget child;
  final Duration every;

  @override
  ConsumerState<SyncScheduler> createState() => _SyncSchedulerState();
}

class _SyncSchedulerState extends ConsumerState<SyncScheduler> {
  Timer? _timer;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _sync);
    _timer = Timer.periodic(widget.every, (_) => _sync());
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  void _sync() {
    if (!mounted) return;
    if (ref.read(pendingSalesProvider).any((p) => !p.failed)) {
      unawaited(ref.read(pendingSalesProvider.notifier).sync());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Bandeau d'état : hors ligne, ventes en attente, ventes refusées à vérifier.
class SyncBanner extends ConsumerStatefulWidget {
  const SyncBanner({super.key, this.padding = EdgeInsets.zero});
  final EdgeInsetsGeometry padding;

  @override
  ConsumerState<SyncBanner> createState() => _SyncBannerState();
}

class _SyncBannerState extends ConsumerState<SyncBanner> {
  bool _sending = false;

  Future<void> _sendNow() async {
    setState(() => _sending = true);
    final report = await ref.read(pendingSalesProvider.notifier).sync();
    if (!mounted) return;
    setState(() => _sending = false);
    if (report.sent > 0) {
      showInfo(context, report.sent == 1 ? '1 vente envoyée' : '${report.sent} ventes envoyées');
    } else if (report.offline) {
      showInfo(context, 'Toujours pas de connexion. Nouvel essai automatique dans un moment.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final online = ref.watch(onlineProvider);
    final mine = ref.watch(pendingSalesProvider).where((p) => p.businessId == ref.watch(businessIdProvider));
    final waiting = mine.where((p) => !p.failed).toList();
    final failed = mine.where((p) => p.failed).length;
    if (online && waiting.isEmpty && failed == 0) return const SizedBox.shrink();

    final String title;
    final String subtitle;
    final IconData icon;
    final Color color;
    if (failed > 0) {
      title = failed == 1 ? '1 vente à vérifier' : '$failed ventes à vérifier';
      subtitle = 'Le serveur les a refusées. Touchez pour voir le détail.';
      icon = Icons.error_outline_rounded;
      color = AppColors.danger;
    } else if (waiting.isNotEmpty) {
      final total = waiting.fold(0, (s, p) => s + p.total);
      title = waiting.length == 1 ? '1 vente en attente d’envoi' : '${waiting.length} ventes en attente d’envoi';
      subtitle = online
          ? '${moneyShort(total)} · envoi automatique dans un instant'
          : '${moneyShort(total)} · partiront dès le retour du réseau';
      icon = Icons.cloud_upload_rounded;
      color = const Color(0xFFE08A12);
    } else {
      title = 'Hors ligne';
      subtitle = 'Vous pouvez continuer à vendre : tout est gardé sur le téléphone.';
      icon = Icons.cloud_off_rounded;
      color = AppColors.muted;
    }

    return Padding(
      padding: widget.padding,
      child: Semantics(
        liveRegion: true,
        child: Glass(
          radius: 18,
          tint: failed > 0 ? AppColors.danger : (waiting.isNotEmpty ? AppColors.saffron : null),
          onTap: failed > 0 || waiting.isNotEmpty ? () => context.push('/sales') : null,
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          child: Row(
            children: [
              GlossyOrb(icon: icon, color: color, size: 34),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
                    Text(subtitle, style: const TextStyle(fontSize: 12.5, color: AppColors.muted)),
                  ],
                ),
              ),
              if (waiting.isNotEmpty && failed == 0)
                _sending
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4)),
                      )
                    : TextButton(onPressed: _sendNow, child: const Text('Envoyer')),
            ],
          ),
        ),
      ),
    );
  }
}

/// Ventes pas encore envoyées, en tête de l'historique.
class PendingSalesSection extends ConsumerWidget {
  const PendingSalesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(pendingForBusinessProvider).reversed.toList();
    if (list.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 4, 4, 8),
          child: Text('Sur ce téléphone', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
        ),
        for (final p in list)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Card(
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                leading: Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: p.failed ? const Color(0xFFFBEAEA) : AppColors.warnBg,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    p.failed ? Icons.error_outline_rounded : Icons.cloud_upload_rounded,
                    color: p.failed ? AppColors.danger : AppColors.warn,
                  ),
                ),
                title: Text(
                  p.failed ? 'Refusée — à vérifier' : 'En attente d’envoi',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                subtitle: Text(
                  [
                    DateFormat('HH:mm', 'fr').format(p.soldAt.toLocal()),
                    if (p.customerName != null) p.customerName!,
                    '${qty(p.itemCount)} article(s)',
                  ].join(' · '),
                ),
                trailing: Text(
                  moneyShort(p.total),
                  style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.ink, fontSize: 14),
                ),
                onTap: () => _details(context, ref, p),
              ),
            ),
          ),
        const SizedBox(height: 8),
      ],
    );
  }

  Future<void> _details(BuildContext context, WidgetRef ref, PendingSale p) => showModalBottomSheet<void>(
    useRootNavigator: true,
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              p.failed ? 'Vente refusée par le serveur' : 'Vente en attente d’envoi',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text(
              'Faite le ${DateFormat('d MMMM à HH:mm', 'fr').format(p.soldAt.toLocal())}'
              '${p.customerName == null ? '' : ' · ${p.customerName}'}',
              style: const TextStyle(color: AppColors.muted),
            ),
            if (p.error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: const Color(0xFFFBEAEA), borderRadius: BorderRadius.circular(12)),
                child: Text(
                  p.error!,
                  style: const TextStyle(color: AppColors.danger, fontWeight: FontWeight.w600),
                ),
              ),
            ],
            const SizedBox(height: 12),
            for (final l in p.lines)
              Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Text('${qty(l.quantity)} × ${l.name}')),
            const Divider(height: 24),
            Row(
              children: [
                const Expanded(
                  child: Text('Total', style: TextStyle(fontWeight: FontWeight.w800)),
                ),
                Text(money(p.total), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              ],
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                unawaited(
                  p.failed
                      ? ref.read(pendingSalesProvider.notifier).retry(p.id)
                      : ref.read(pendingSalesProvider.notifier).sync(),
                );
              },
              icon: const Icon(Icons.sync_rounded),
              label: const Text('Réessayer l’envoi'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: ctx,
                  builder: (d) => AlertDialog(
                    title: const Text('Supprimer cette vente ?'),
                    content: const Text('Elle ne sera jamais envoyée ni comptée dans votre caisse.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Annuler')),
                      TextButton(
                        style: TextButton.styleFrom(foregroundColor: AppColors.danger),
                        onPressed: () => Navigator.pop(d, true),
                        child: const Text('Supprimer'),
                      ),
                    ],
                  ),
                );
                if (ok == true) {
                  await ref.read(pendingSalesProvider.notifier).discard(p.id);
                  if (ctx.mounted) Navigator.pop(ctx);
                }
              },
              child: const Text('Supprimer la vente'),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Nombre de ventes non envoyées : pour prévenir avant une déconnexion.
int unsentSalesCount(WidgetRef ref) => ref.read(pendingSalesProvider).length;
