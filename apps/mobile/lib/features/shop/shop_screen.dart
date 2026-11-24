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

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (status) {
      ShopOrderStatus.newOrder => AppColors.tone(const Color(0xFFFDE7E4), AppColors.danger),
      ShopOrderStatus.confirmed => AppColors.tone(const Color(0xFFE6EFFC), const Color(0xFF1F5BB8)),
      ShopOrderStatus.ready => AppColors.tone(AppColors.warnBg, AppColors.warnText),
      ShopOrderStatus.delivering => AppColors.tone(const Color(0xFFEDE7FB), const Color(0xFF5B3CC4)),
      ShopOrderStatus.completed => AppColors.tone(AppColors.greenSoft, AppColors.greenDark),
      ShopOrderStatus.cancelled => AppColors.tone(const Color(0xFFEFF1F0), AppColors.muted),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(
        status.label,
        style: TextStyle(color: fg, fontSize: 11.5, fontWeight: FontWeight.w700),
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
        actions: [
          if (canSettings)
            IconButton(
              tooltip: 'Réglages de la boutique',
              icon: const Icon(Icons.tune_rounded),
              onPressed: () => context.push('/shop/settings'),
            ),
        ],
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
          color: o.status == ShopOrderStatus.newOrder
              ? AppColors.softOf(const Color(0xFFFDE7E4), AppColors.danger)
              : AppColors.greenSoft,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(
          o.delivery ? Icons.delivery_dining_rounded : Icons.storefront_rounded,
          color: o.status == ShopOrderStatus.newOrder ? AppColors.danger : AppColors.green,
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
      trailing: Text(moneyShort(o.total), style: const TextStyle(fontWeight: FontWeight.w800)),
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
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                key: const Key('shop_edit_cover'),
                tooltip: 'Modifier la vitrine',
                style: IconButton.styleFrom(backgroundColor: const Color(0x66000000), foregroundColor: Colors.white),
                onPressed: () => context.push('/shop/settings'),
                icon: const Icon(Icons.edit_rounded, size: 18),
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
