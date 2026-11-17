import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// Écrans de la barre de navigation du bas.
const tabRoutes = {'/', '/pos', '/stock', '/customers'};

/// Icône et couleur de chaque type de notification.
(IconData, Color) notificationStyle(String kind) => switch (kind) {
  'stock_low' => (Icons.inventory_2_rounded, const Color(0xFFD9822B)),
  'shop_order' => (Icons.shopping_bag_rounded, AppColors.green),
  'sale_voided' => (Icons.receipt_long_rounded, const Color(0xFFC62828)),
  'invoices_overdue' => (Icons.request_quote_rounded, const Color(0xFF7A5AF8)),
  'credit_stale' => (Icons.menu_book_rounded, const Color(0xFF2F6FDB)),
  'cash_open' || 'cash_open_team' => (Icons.point_of_sale_rounded, AppColors.ink),
  'welcome' => (Icons.celebration_rounded, const Color(0xFFE0533D)),
  'birthday' => (Icons.cake_rounded, const Color(0xFFE0A100)),
  'weekly_report' => (Icons.chat_rounded, AppColors.whatsapp),
  'document_expiring' => (Icons.event_busy_rounded, const Color(0xFF6B7280)),
  _ => (Icons.notifications_rounded, AppColors.green),
};

/// « à l’instant », « il y a 12 min », « 14:20 », « hier, 09:05 », « 12 nov. ».
String notificationTime(DateTime at, DateTime now) {
  final diff = now.difference(at);
  if (diff.inMinutes < 1) return 'à l’instant';
  if (diff.inMinutes < 60) return 'il y a ${diff.inMinutes} min';
  final day = DateTime(at.year, at.month, at.day);
  final today = DateTime(now.year, now.month, now.day);
  final hm = '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
  if (day == today) return hm;
  if (today.difference(day).inDays == 1) return 'hier, $hm';
  return shortDate(at);
}

/// Groupe d'affichage : Aujourd’hui, Hier, Plus tôt.
String notificationGroup(DateTime at, DateTime now) {
  final day = DateTime(at.year, at.month, at.day);
  final today = DateTime(now.year, now.month, now.day);
  final days = today.difference(day).inDays;
  if (days <= 0) return 'Aujourd’hui';
  if (days == 1) return 'Hier';
  return 'Plus tôt';
}

class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});

  @override
  ConsumerState<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  /// Lues pendant la visite de l'écran (affichage immédiat, sans attendre le serveur).
  final _readHere = <String>{};
  bool _allRead = false;

  Future<void> _open(AppNotification n) async {
    if (!n.read && !_readHere.contains(n.id)) {
      setState(() => _readHere.add(n.id));
      ref
          .read(repoProvider)
          .markNotificationRead(n.id)
          .then((_) => ref.invalidate(unreadNotificationsProvider), onError: (_) {});
    }
    final link = n.link;
    if (link == null || !mounted) return;
    // Les onglets de la barre du bas se rejoignent, les autres écrans s'empilent (retour possible).
    if (tabRoutes.contains(link)) {
      context.go(link);
    } else {
      await context.push(link);
    }
  }

  Future<void> _readAll() async {
    setState(() => _allRead = true);
    try {
      await ref.read(repoProvider).markAllNotificationsRead();
      ref.invalidate(unreadNotificationsProvider);
    } catch (e) {
      if (mounted) {
        setState(() => _allRead = false);
        showError(context, e);
      }
    }
  }

  Future<void> _refresh() async {
    _readHere.clear();
    _allRead = false;
    refreshNotifications(ref);
    await ref.read(notificationsProvider.future);
  }

  @override
  Widget build(BuildContext context) {
    final page = ref.watch(notificationsProvider);
    final unread = page.value == null
        ? 0
        : _allRead
        ? 0
        : page.value!.items.where((n) => !n.read && !_readHere.contains(n.id)).length;
    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Notifications', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          if (unread > 0)
            TextButton.icon(
              onPressed: _readAll,
              icon: const Icon(Icons.done_all_rounded, size: 18),
              label: const Text('Tout lire'),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: AsyncView<NotificationsPage>(
        value: page,
        onRetry: () => ref.invalidate(notificationsProvider),
        data: (p) {
          if (p.items.isEmpty) return const _Empty();
          final now = DateTime.now();
          final rows = <Widget>[];
          String? group;
          for (final n in p.items) {
            final g = notificationGroup(n.createdAt, now);
            if (g != group) {
              group = g;
              rows.add(
                Padding(
                  padding: EdgeInsets.fromLTRB(4, rows.isEmpty ? 4 : 18, 4, 8),
                  child: Text(g, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                ),
              );
            }
            final read = _allRead || n.read || _readHere.contains(n.id);
            rows.add(
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: NotificationTile(
                  notification: n.copyWith(read: read),
                  now: now,
                  onTap: () => _open(n),
                ),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: rows),
          );
        },
      ),
    );
  }
}

class NotificationTile extends StatelessWidget {
  const NotificationTile({super.key, required this.notification, required this.now, this.onTap});
  final AppNotification notification;
  final DateTime now;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final n = notification;
    final (icon, color) = notificationStyle(n.kind);
    return Semantics(
      label: n.read ? null : 'Non lue',
      child: Glass(
        radius: 18,
        onTap: onTap,
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(14)),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          n.title,
                          style: TextStyle(fontWeight: n.read ? FontWeight.w600 : FontWeight.w800, fontSize: 14.5),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        notificationTime(n.createdAt, now),
                        style: TextStyle(color: AppColors.muted, fontSize: 11.5),
                      ),
                    ],
                  ),
                  if (n.body.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(n.body, style: TextStyle(color: AppColors.muted, fontSize: 13, height: 1.3)),
                  ],
                ],
              ),
            ),
            if (!n.read)
              Padding(
                padding: const EdgeInsets.only(left: 8, top: 4),
                child: Container(
                  key: ValueKey('unread_${n.id}'),
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(color: AppColors.green, shape: BoxShape.circle),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.notifications_none_rounded, size: 56, color: AppColors.muted),
          SizedBox(height: 12),
          Text('Rien de nouveau', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
          SizedBox(height: 6),
          Text(
            'Stock bas, commandes en ligne, factures en retard, caisse restée ouverte : tout s’affichera ici.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.muted),
          ),
        ],
      ),
    ),
  );
}
