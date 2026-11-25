import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../sales/receipt_screen.dart' show receiptActionsProvider, whatsAppUri;
import 'shop_cover.dart';

/// Adresse publique complète de la boutique (servie par l'API).
String shopUrl(String apiBase, String path) => '${apiBase.replaceAll(RegExp(r'/+$'), '')}$path';

/// Pastille de statut d'une commande en ligne.
class ShopStatusChip extends StatelessWidget {
  const ShopStatusChip({super.key, required this.status});
  final ShopOrderStatus status;

  /// Une couleur par étape, fixe (ne suit pas la couleur de la boutique) : on reconnaît l'étape d'un coup d'œil.
  static Color colorOf(ShopOrderStatus s) => switch (s) {
    ShopOrderStatus.newOrder => const Color(0xFFE5484D), // rouge : à traiter
    ShopOrderStatus.confirmed => const Color(0xFF2563EB), // bleu : acceptée
    ShopOrderStatus.ready => const Color(0xFFE08A12), // orange : prête
    ShopOrderStatus.delivering => const Color(0xFF7C3AED), // violet : en route
    ShopOrderStatus.completed => const Color(0xFF12A150), // vert : livrée, encaissée
    ShopOrderStatus.cancelled => const Color(0xFF8A948F), // gris : annulée
  };

  static IconData iconOf(ShopOrderStatus s) => switch (s) {
    ShopOrderStatus.newOrder => Icons.fiber_new_rounded,
    ShopOrderStatus.confirmed => Icons.thumb_up_alt_rounded,
    ShopOrderStatus.ready => Icons.inventory_2_rounded,
    ShopOrderStatus.delivering => Icons.delivery_dining_rounded,
    ShopOrderStatus.completed => Icons.check_circle_rounded,
    ShopOrderStatus.cancelled => Icons.cancel_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final c = colorOf(status);
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 3, 9, 3),
      decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(iconOf(status), size: 13, color: Colors.white),
          const SizedBox(width: 4),
          Text(
            status.label,
            style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }
}

/// Boutique en ligne : lien à partager, chiffres, commandes reçues.
class ShopScreen extends ConsumerStatefulWidget {
  const ShopScreen({super.key});
  @override
  ConsumerState<ShopScreen> createState() => _ShopScreenState();
}

class _ShopScreenState extends ConsumerState<ShopScreen> {
  ShopOrderFilter _filter = ShopOrderFilter.open;

  @override
  Widget build(BuildContext context) {
    final shop = ref.watch(shopProvider);
    final canSettings = ref.watch(canProvider('catalog:write'));
    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Boutique en ligne', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: AsyncView<ShopOverview>(
        value: shop,
        onRetry: () => ref.invalidate(shopProvider),
        data: (s) => RefreshIndicator(
          onRefresh: () async => refreshShop(ref),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
            children: s.settings.enabled ? _open(s) : [_Closed(canOpen: canSettings)],
          ),
        ),
      ),
    );
  }

  List<Widget> _open(ShopOverview s) {
    final orders = ref.watch(shopOrdersProvider(_filter));
    return [
      _LinkCard(overview: s),
      const SizedBox(height: 10),
      Glass(
        key: const Key('open_status'),
        outlined: true,
        radius: 18,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        onTap: () => context.push('/status'),
        child: Row(
          children: [
            Icon(Icons.auto_awesome_rounded, color: AppColors.whatsapp),
            const SizedBox(width: 10),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Créer un statut WhatsApp', style: TextStyle(fontWeight: FontWeight.w800)),
                  Text('Image prête avec photo, prix et lien de commande', style: TextStyle(fontSize: 12.5)),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: AppColors.muted),
          ],
        ),
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: StatTile(label: 'Nouvelles', value: '${s.newOrders}', warn: s.newOrders > 0),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: StatTile(label: 'En cours', value: '${s.openOrders}'),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: StatTile(label: 'Ventes du mois', value: moneyShort(s.monthRevenue)),
          ),
        ],
      ),
      const SizedBox(height: 10),
      Glass(
        outlined: true,
        radius: 18,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        onTap: () => context.push('/shop/products'),
        child: Row(
          children: [
            Icon(Icons.storefront_rounded, color: AppColors.green),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '${s.publishedProducts} produit${s.publishedProducts > 1 ? 's' : ''} en ligne sur ${s.totalProducts}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            Text(
              'Choisir',
              style: TextStyle(color: AppColors.green, fontWeight: FontWeight.w700),
            ),
            Icon(Icons.chevron_right_rounded, color: AppColors.green),
          ],
        ),
      ),
      const SizedBox(height: 18),
      const Text('Commandes', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final f in ShopOrderFilter.values) ...[
              Pill(label: f.label, selected: _filter == f, onTap: () => setState(() => _filter = f)),
              const SizedBox(width: 8),
            ],
          ],
        ),
      ),
      const SizedBox(height: 10),
      AsyncView<List<ShopOrder>>(
        value: orders,
        onRetry: () => ref.invalidate(shopOrdersProvider(_filter)),
        data: (list) => list.isEmpty
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Column(
                  children: [
                    Icon(Icons.shopping_bag_outlined, size: 44, color: AppColors.muted),
                    const SizedBox(height: 8),
                    Text(
                      _filter == ShopOrderFilter.done
                          ? 'Aucune commande terminée'
                          : 'Pas de commande pour l’instant.\nPartagez votre lien sur WhatsApp !',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.muted),
                    ),
                  ],
                ),
              )
            : Column(
                children: [
                  for (final o in list)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: ShopOrderTile(o: o),
                    ),
                ],
              ),
      ),
    ];
  }
}

class ShopOrderTile extends StatelessWidget {
  const ShopOrderTile({super.key, required this.o});
  final ShopOrder o;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      contentPadding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
      onTap: () => context.push('/shop/orders/${o.id}'),
      leading: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: ShopStatusChip.colorOf(o.status).withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(
          o.delivery ? Icons.delivery_dining_rounded : Icons.storefront_rounded,
          color: ShopStatusChip.colorOf(o.status),
        ),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              o.customerName,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(width: 8),
          ShopStatusChip(status: o.status),
        ],
      ),
      subtitle: Text(
        '${o.number} · ${dateTime(o.createdAt)} · ${o.lineCount} article${o.lineCount > 1 ? 's' : ''}',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Text(
        moneyShort(o.total),
        style: TextStyle(
          fontWeight: FontWeight.w900,
          fontSize: 15,
          color: o.status == ShopOrderStatus.cancelled ? AppColors.muted : AppColors.green,
          decoration: o.status == ShopOrderStatus.cancelled ? TextDecoration.lineThrough : null,
        ),
      ),
    ),
  );
}

class _LinkCard extends ConsumerWidget {
  const _LinkCard({required this.overview});
  final ShopOverview overview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = shopUrl(ref.watch(apiBaseUrlProvider), overview.path);
    final actions = ref.read(receiptActionsProvider);
    final name = shopDisplayName(overview.settings, ref.watch(shopBusinessNameProvider));
    final st = overview.settings;
    final b = ref.watch(currentBusinessProvider).value;
    Widget action(IconData icon, String label, VoidCallback onTap) => Expanded(
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: Colors.white.withValues(alpha: 0.18),
          foregroundColor: Colors.white,
          side: BorderSide(color: Colors.white.withValues(alpha: 0.55), width: 1.2),
          minimumSize: const Size.fromHeight(40),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700, fontSize: 12.5),
        ),
        onPressed: onTap,
        icon: Icon(icon, size: 16),
        label: Text(label),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Stack(
          children: [
            ShopCover(
              headline: (st.tagline ?? '').trim().isNotEmpty ? st.tagline!.trim() : name,
              coverFileId: st.coverFileId,
              kicker: b?.city ?? name,
              height: 300,
              bottom: Column(
                children: [
                  // Toujours là : ouvre la boutique telle que la voient les clients
                  ShopCoverButton(
                    key: const Key('shop_view'),
                    label: 'Voir ma boutique',
                    onTap: () => actions.openWhatsApp(Uri.parse(url)),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      action(Icons.chat_rounded, 'Partager', () {
                        actions.openWhatsApp(whatsAppUri('Découvrez $name et commandez directement ici : $url'));
                      }),
                      const SizedBox(width: 8),
                      action(Icons.copy_rounded, 'Copier le lien', () async {
                        await Clipboard.setData(ClipboardData(text: url));
                        if (context.mounted) showInfo(context, 'Lien copié');
                      }),
                    ],
                  ),
                  // Un peu d'air sous les boutons
                  const SizedBox(height: 8),
                ],
              ),
            ),
            Positioned(
              top: 12,
              left: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(color: const Color(0x66000000), borderRadius: BorderRadius.circular(20)),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.circle, size: 8, color: AppColors.glow),
                    SizedBox(width: 6),
                    Text(
                      'En ligne',
                      style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            ),
            // Seul accès aux réglages : bien visible, orange et nommé
            if (ref.watch(canProvider('catalog:write')))
              Positioned(
                top: 10,
                right: 10,
                child: FilledButton.icon(
                  key: const Key('shop_edit_cover'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.orange,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    elevation: 3,
                    textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
                  ),
                  onPressed: () => context.push('/shop/settings'),
                  icon: const Icon(Icons.edit_rounded, size: 17),
                  label: const Text('Modifier'),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(
            url.replaceFirst(RegExp(r'^https?://'), ''),
            style: TextStyle(color: AppColors.muted, fontWeight: FontWeight.w600, fontSize: 12.5),
          ),
        ),
      ],
    );
  }
}

/// Nom affiché de la boutique : son titre, sinon le nom de l'entreprise.
String shopDisplayName(ShopSettings? s, String business) {
  final t = s?.title?.trim() ?? '';
  return t.isEmpty ? business : t;
}

/// Nom de l'entreprise courante (titre par défaut de la boutique).
final shopBusinessNameProvider = Provider<String>(
  (ref) => ref.watch(currentBusinessProvider).value?.name ?? 'Ma boutique',
);

class _Closed extends StatelessWidget {
  const _Closed({required this.canOpen});
  final bool canOpen;

  @override
  Widget build(BuildContext context) => Glass(
    radius: 26,
    padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
    child: Column(
      children: [
        const GlossyOrb(icon: Icons.storefront_rounded, color: Color(0xFF0E9384), size: 72),
        const SizedBox(height: 16),
        const Text(
          'Vendez aussi sur Internet',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        Text(
          'Vos produits sur une page web à partager sur WhatsApp, Facebook ou TikTok. '
          'Vos clients commandent sans compte, vous recevez la commande ici, vous livrez, '
          'et la vente s’enregistre toute seule dans votre caisse.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.muted, height: 1.4),
        ),
        const SizedBox(height: 18),
        for (final (icon, text) in const [
          (Icons.link_rounded, 'Un lien à votre nom, prêt à partager'),
          (Icons.delivery_dining_rounded, 'Livraison ou retrait en boutique, à vous de choisir'),
          (Icons.payments_outlined, 'Paiement à la livraison : espèces, Wave, Orange Money'),
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Icon(icon, size: 20, color: AppColors.green),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
        const SizedBox(height: 12),
        if (canOpen)
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
            onPressed: () => context.push('/shop/settings?open=1'),
            icon: const Icon(Icons.rocket_launch_rounded),
            label: const Text('Ouvrir ma boutique'),
          )
        else
          Text('Demandez au gérant d’ouvrir la boutique en ligne.', style: TextStyle(color: AppColors.muted)),
      ],
    ),
  );
}
