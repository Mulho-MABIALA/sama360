import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/celebrate.dart';
import '../../core/charts.dart';
import '../../core/api/api_client.dart';
import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/offline/pending_sales.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../locations/locations_screen.dart' show SellingAtBanner;
import '../catalog/variant_picker.dart';
import 'line_options_sheet.dart';
import 'quantity_sheet.dart';
import '../catalog/product_photo.dart';
import '../customers/customer_picker.dart';
import '../offline/offline_ui.dart';
import '../catalog/barcode_scanner.dart';
import 'cart.dart';
import 'pay_qr_sheet.dart';

/// Caisse : produits à gauche/en haut, panier et encaissement en bas (maquette « Nouvelle vente »).
class PosScreen extends ConsumerStatefulWidget {
  const PosScreen({super.key});
  @override
  ConsumerState<PosScreen> createState() => _PosScreenState();
}

class _PosScreenState extends ConsumerState<PosScreen> {
  String _search = '';
  String? _categoryId;
  bool _busy = false;

  /// Ajout d'un produit selon son métier : IMEI (téléphonie), suppléments (restaurant),
  /// quantité tapée (mètre, kilo, carton), sinon +1.
  Future<void> _addFlow(Product p, {double? onHand}) async {
    final cart = ref.read(cartProvider.notifier);
    if (p.trackSerial) {
      final existing = ref.read(cartProvider).lines[p.id];
      final serials = await pickSerials(context, p, current: existing?.serials ?? const []);
      if (serials == null) return;
      cart.setLineQuantity(p.id, 0);
      if (serials.isNotEmpty) cart.addLine(CartLine(p, serials.length.toDouble(), serials: serials));
      return;
    }
    if (p.extras.isNotEmpty) {
      final line = await pickExtras(context, p);
      if (line != null) cart.addLine(line);
      return;
    }
    if (p.decimalUnit || p.hasPack) {
      final q = await pickQuantity(
        context,
        product: p,
        current: ref.read(cartProvider).quantityOf(p.id),
        onHand: onHand,
      );
      if (q != null) cart.setQuantity(p, q);
      return;
    }
    HapticFeedback.selectionClick();
    cart.add(p);
  }

  Future<void> _checkout() async {
    final cart = ref.read(cartProvider);
    final blocker = checkoutBlocker(cart);
    if (blocker != null) return showInfo(context, blocker);

    final businessId = ref.read(businessIdProvider);
    if (businessId == null) return;
    final id = ref.read(cartProvider.notifier).ensureSaleId();
    setState(() => _busy = true);
    CheckoutOutcome outcome;
    try {
      // Sans réseau, la vente est gardée sur le téléphone et partira toute seule plus tard.
      outcome = await ref
          .read(pendingSalesProvider.notifier)
          .checkout(
            id: id,
            businessId: businessId,
            customer: cart.customer,
            total: cart.total,
            lines: [for (final l in cart.lines.values) (product: l.product, quantity: l.quantity)],
            details: {
              for (final (n, l) in cart.lines.values.indexed)
                if (l.extras.isNotEmpty || l.serials.isNotEmpty)
                  n: {
                    if (l.extras.isNotEmpty) 'extras': [for (final e in l.extras) e.name],
                    if (l.serials.isNotEmpty) 'serials': l.serials,
                  },
            },
            names: {for (final (n, l) in cart.lines.values.indexed) n: l.name},
            payments: paymentsFor(cart.total, cart.mode, cart.deposit),
            redeemRewards: cart.customer == null ? 0 : cart.rewards,
          );
    } on ApiException catch (e) {
      // Refus du serveur : le panier et son identifiant sont gardés pour corriger et réessayer.
      if (mounted) {
        setState(() => _busy = false);
        showError(context, e);
      }
      return;
    }
    ref.read(cartProvider.notifier).clear();
    if (outcome is SaleSent) refreshBusinessData(ref);
    if (!mounted) return;
    setState(() => _busy = false);
    switch (outcome) {
      case SaleSent(:final sale):
        await _showSuccess(sale, cart.customer);
      case SaleQueued(:final pending):
        await _showQueued(pending);
    }
  }

  /// Scan en caisse, en continu : chaque article reconnu va au panier sans refermer la caméra.
  /// À la fin, un code inconnu propose de créer la fiche.
  Future<void> _scan() async {
    final unknown = <String>[];
    final repo = ref.read(repoProvider);
    final cart = ref.read(cartProvider.notifier);
    await ref.read(continuousScannerProvider)(context, (code) async {
      Product? product;
      try {
        product = await repo.productByCode(code);
      } catch (e) {
        return ScanFeedback(errorMessage(e), ok: false);
      }
      if (product == null) {
        if (!unknown.contains(code)) unknown.add(code);
        return ScanFeedback('Code inconnu : $code', ok: false);
      }
      cart.add(product);
      final q = ref.read(cartProvider).lines[product.id]?.quantity ?? 1;
      return ScanFeedback('${product.name} ajouté${q > 1 ? ' · ${qty(q)} au panier' : ''}');
    });
    if (!mounted || unknown.isEmpty) return;
    final code = unknown.last;
    final create = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.qr_code_2_rounded, size: 40),
        title: const Text('Produit inconnu'),
        content: Text(
          'Aucun produit n’a le code $code.${ref.can('catalog:write') ? ' Voulez-vous créer sa fiche ?' : ''}',
        ),
        actions: dialogActions([
          CancelButton(label: 'Fermer', onPressed: () => Navigator.pop(ctx, false)),
          if (ref.can('catalog:write'))
            ConfirmButton(label: 'Créer la fiche', onPressed: () => Navigator.pop(ctx, true)),
        ]),
      ),
    );
    if (create == true && mounted) {
      final created = await context.push<Product>('/products/new?barcode=${Uri.encodeComponent(code)}');
      if (created != null) ref.read(cartProvider.notifier).add(created);
    }
  }

  Future<void> _showQueued(PendingSale p) => showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: Icon(Icons.cloud_off_rounded, color: AppColors.warn, size: 46),
      title: const Text('Vente gardée sur le téléphone'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(money(p.total), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          Text(
            'Pas de connexion pour l’instant. La vente est bien enregistrée sur ce téléphone '
            'et sera envoyée automatiquement dès le retour du réseau.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.muted),
          ),
        ],
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: dialogActions([FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Nouvelle vente'))]),
    ),
  );

  Future<void> _showSuccess(SaleResult sale, Contact? customer) {
    final milestone = saleMilestone(sale.number);
    return showDialog<void>(
      context: context,
      builder: (ctx) => Stack(
        children: [
          if (milestone != null) const Positioned.fill(child: ConfettiBurst()),
          Dialog(
            key: const Key('sale_success'),
            insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 26, 22, 18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Taille fixe, centrée : sur le web, l'emplacement d'icône d'AlertDialog l'étirait.
                    const Center(child: SuccessCheck(size: 76)),
                    const SizedBox(height: 14),
                    const Text(
                      'Vente enregistrée',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
                    ),
                    if (milestone != null) ...[
                      const SizedBox(height: 8),
                      Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                          decoration: BoxDecoration(
                            color: AppColors.saffron.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            milestone,
                            key: const Key('sale_milestone'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: AppColors.strongOf(AppColors.warnBg, const Color(0xFF8A5300)),
                              fontWeight: FontWeight.w800,
                              fontSize: 13.5,
                            ),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
                      decoration: BoxDecoration(
                        color: AppColors.greenSoft.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Column(
                        children: [
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              money(sale.total),
                              style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w900, letterSpacing: -0.5),
                            ),
                          ),
                          Text(sale.number, style: TextStyle(color: AppColors.muted, fontSize: 13)),
                        ],
                      ),
                    ),
                    if (sale.due > 0) ...[
                      const SizedBox(height: 10),
                      Text(
                        '${money(sale.due)} ajoutés au crédit de ${customer?.name ?? 'ce client'}',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppColors.warnText, fontWeight: FontWeight.w700),
                      ),
                    ],
                    const SizedBox(height: 18),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                      onPressed: () {
                        Navigator.pop(ctx);
                        context.push('/sales/${sale.id}');
                      },
                      icon: const Icon(Icons.receipt_long_rounded),
                      label: const Text('Voir le reçu'),
                    ),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      style: TextButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                      onPressed: () => Navigator.pop(ctx),
                      icon: const Icon(Icons.add_shopping_cart_rounded, size: 19),
                      label: const Text('Nouvelle vente'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final products = ref.watch(productsProvider);
    final categories = ref.watch(categoriesProvider).value ?? const <Category>[];
    final stock = ref.can('inventory:read') ? ref.watch(stockProvider).value : null;
    final onHand = {for (final s in stock?.items ?? const <StockItem>[]) s.productId: s};
    final cart = ref.watch(cartProvider);

    final count = products.value?.where((p) => !p.isVariant).length;
    return AuroraScaffold(
      appBar: AppBar(
        toolbarHeight: 64,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Nouvelle vente', style: TextStyle(fontWeight: FontWeight.w800)),
            Text(
              toBeginningOfSentenceCase(DateFormat('EEEE d MMMM', 'fr').format(DateTime.now())),
              style: TextStyle(fontSize: 12.5, color: AppColors.muted, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        actions: [
          _HeaderAction(
            label: 'Caisse',
            tooltip: 'Ma caisse',
            icon: Icons.point_of_sale_rounded,
            onTap: () => context.push('/cash'),
          ),
          const SizedBox(width: 8),
          _HeaderAction(
            label: 'Reçus',
            tooltip: "Ventes d'aujourd'hui",
            icon: Icons.receipt_long_rounded,
            onTap: () => context.push('/sales'),
          ),
          const SizedBox(width: 14),
        ],
      ),
      // Téléphone : catalogue puis panier en bas. Tablette et ordinateur : panier à droite.
      body: LayoutBuilder(
        builder: (context, box) {
          final catalog = <Widget>[
            const SyncBanner(padding: EdgeInsets.fromLTRB(16, 0, 16, 10)),
            const _CashClosedBanner(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Glass(
                radius: 18,
                blur: 12,
                padding: const EdgeInsets.only(left: 6, right: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        decoration: InputDecoration(
                          hintText: count == null || count == 0
                              ? 'Rechercher un produit'
                              : 'Rechercher parmi $count produits',
                          prefixIcon: const Icon(Icons.search_rounded),
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          isDense: true,
                        ),
                        onChanged: (v) => setState(() => _search = v.trim().toLowerCase()),
                      ),
                    ),
                    Tooltip(
                      message: 'Scanner un code-barres',
                      child: Material(
                        color: AppColors.green,
                        borderRadius: BorderRadius.circular(13),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(13),
                          onTap: _scan,
                          child: SizedBox(
                            width: 48,
                            height: 48,
                            child: Icon(Icons.qr_code_scanner_rounded, color: AppColors.onGreen, size: 22),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (categories.isNotEmpty)
              SizedBox(
                height: 48,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    Pill(label: 'Tout', selected: _categoryId == null, onTap: () => setState(() => _categoryId = null)),
                    for (final c in categories) ...[
                      const SizedBox(width: 8),
                      Pill(
                        label: c.name,
                        selected: _categoryId == c.id,
                        onTap: () => setState(() => _categoryId = c.id),
                      ),
                    ],
                  ],
                ),
              ),
            const SizedBox(height: 10),
            Expanded(
              child: AsyncView<List<Product>>(
                value: products,
                onRetry: () => ref.invalidate(productsProvider),
                data: (all) {
                  // Les variantes (Noir · M…) se choisissent depuis leur modèle
                  final list = all.where((p) => !p.isVariant).toList();
                  final shown = list
                      .where((p) => _categoryId == null || p.categoryId == _categoryId)
                      .where(
                        (p) =>
                            _search.isEmpty ||
                            p.name.toLowerCase().contains(_search) ||
                            (p.hasVariants && variantsOf(p, all).any((v) => v.name.toLowerCase().contains(_search))),
                      )
                      .toList();
                  if (list.isEmpty) {
                    return _EmptyCatalog(onScan: _scan);
                  }
                  if (shown.isEmpty) {
                    return Center(
                      child: Text('Aucun produit ne correspond', style: TextStyle(color: AppColors.muted)),
                    );
                  }
                  return GridView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 200,
                      mainAxisExtent: 204,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                    ),
                    itemCount: shown.length,
                    itemBuilder: (_, i) {
                      final p = shown[i];
                      if (!p.hasVariants) {
                        return _ProductCard(
                          product: p,
                          stock: onHand[p.id],
                          quantity: cart.quantityOf(p.id),
                          onAdd: () => _addFlow(p, onHand: onHand[p.id]?.onHand),
                          onRemove: () => ref.read(cartProvider.notifier).remove(p.id),
                        );
                      }
                      // Modèle : stock et quantité additionnés sur ses variantes ; le toucher ouvre le choix
                      final vs = variantsOf(p, all);
                      final items = [for (final v in vs) ?onHand[v.id]];
                      final total = items.fold<double>(0, (s, x) => s + x.onHand);
                      Future<void> choose() async {
                        final v = await pickVariant(
                          context,
                          parent: p,
                          variants: vs,
                          onHand: stock == null ? null : {for (final x in items) x.productId: x.onHand},
                        );
                        if (v == null || !context.mounted) return;
                        await _addFlow(v, onHand: onHand[v.id]?.onHand);
                      }

                      return _ProductCard(
                        product: p,
                        fromPrice: vs.map((v) => v.price).toSet().length > 1
                            ? vs.map((v) => v.price).reduce((a, b) => a < b ? a : b)
                            : null,
                        options: vs.length,
                        stock: items.isEmpty
                            ? null
                            : StockItem(
                                productId: p.id,
                                name: p.name,
                                price: p.price,
                                cost: p.cost,
                                threshold: p.lowStockThreshold,
                                onHand: total,
                                low: total <= p.lowStockThreshold,
                              ),
                        quantity: vs.fold(0.0, (s, v) => s + cart.quantityOf(v.id)),
                        onAdd: choose,
                        onRemove: choose,
                      );
                    },
                  );
                },
              ),
            ),
          ];
          if (box.maxWidth < wideCheckoutWidth) {
            return Column(
              children: [
                ...catalog,
                _CheckoutPanel(busy: _busy, onCheckout: _checkout, compact: true),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: Column(children: catalog)),
              SizedBox(
                key: const Key('pos_side_panel'),
                width: box.maxWidth >= 1200 ? 420 : 380,
                child: Column(
                  children: [
                    const Expanded(child: _CartLines()),
                    _CheckoutPanel(busy: _busy, onCheckout: _checkout),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Largeur à partir de laquelle le panier passe à droite du catalogue (tablette, ordinateur).
const wideCheckoutWidth = 900.0;

/// Grand écran : les lignes du panier, avec + / − pour ajuster les quantités.
class _CartLines extends ConsumerWidget {
  const _CartLines();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cart = ref.watch(cartProvider);
    final ctrl = ref.read(cartProvider.notifier);
    final lines = cart.lines.values.toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 0),
      child: Glass(
        key: const Key('cart_lines'),
        radius: 24,
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Panier', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
            const SizedBox(height: 6),
            Expanded(
              child: lines.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.shopping_basket_outlined, size: 40, color: AppColors.muted),
                          const SizedBox(height: 8),
                          Text(
                            'Touchez un produit pour l’ajouter',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppColors.muted),
                          ),
                        ],
                      ),
                    )
                  : ListView.separated(
                      itemCount: lines.length,
                      separatorBuilder: (_, _) => Divider(height: 1, color: AppColors.glassLine),
                      itemBuilder: (_, i) {
                        final l = lines[i];
                        return Padding(
                          key: Key('cart_line_${l.key}'),
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            children: [
                              Expanded(
                                // Toucher la ligne : taper la quantité (2,5 m, 1 carton, 50 pièces…)
                                child: InkWell(
                                  key: Key('cart_qty_${l.key}'),
                                  borderRadius: BorderRadius.circular(8),
                                  onTap: () async {
                                    // Téléphones : on corrige la liste des IMEI ; sinon la quantité
                                    if (l.product.trackSerial) {
                                      final serials = await pickSerials(context, l.product, current: l.serials);
                                      if (serials == null) return;
                                      ctrl.setLineQuantity(l.key, 0);
                                      if (serials.isNotEmpty) {
                                        ctrl.addLine(CartLine(l.product, serials.length.toDouble(), serials: serials));
                                      }
                                      return;
                                    }
                                    final q = await pickQuantity(context, product: l.product, current: l.quantity);
                                    if (q != null) ctrl.setLineQuantity(l.key, q, product: l.product);
                                  },
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        l.name,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontWeight: FontWeight.w700),
                                      ),
                                      if (l.serials.isNotEmpty)
                                        Text(
                                          'IMEI ${l.serials.join(', ')}',
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(color: AppColors.muted, fontSize: 11.5),
                                        ),
                                      Text(
                                        '${qty(l.quantity)}${l.product.unit == 'pièce' ? '' : ' ${l.product.unit}'} × ${moneyShort(l.unitPrice)}',
                                        style: TextStyle(
                                          color: AppColors.green,
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w700,
                                          decoration: TextDecoration.underline,
                                          decorationStyle: TextDecorationStyle.dotted,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: 'Retirer un',
                                onPressed: () => ctrl.remove(l.key),
                                icon: const Icon(Icons.remove_circle_outline_rounded),
                              ),
                              IconButton(
                                tooltip: 'Ajouter un',
                                onPressed: () async {
                                  if (l.product.trackSerial) {
                                    final serials = await pickSerials(context, l.product, current: l.serials);
                                    if (serials == null) return;
                                    ctrl.setLineQuantity(l.key, 0);
                                    if (serials.isNotEmpty) {
                                      ctrl.addLine(CartLine(l.product, serials.length.toDouble(), serials: serials));
                                    }
                                    return;
                                  }
                                  ctrl.addLine(CartLine(l.product, 1, extras: l.extras));
                                },
                                icon: Icon(Icons.add_circle_rounded, color: AppColors.green),
                              ),
                              SizedBox(
                                width: 78,
                                child: Text(
                                  moneyShort(l.total),
                                  textAlign: TextAlign.right,
                                  style: const TextStyle(fontWeight: FontWeight.w800),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderAction extends StatelessWidget {
  const _HeaderAction({required this.label, required this.tooltip, required this.icon, required this.onTap});

  /// Mot sous l'icône : une icône seule ne se comprend pas toujours.
  final String label;
  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Glass(
      radius: 14,
      blur: 10,
      shadow: false,
      onTap: onTap,
      child: SizedBox(
        width: 56,
        height: 50,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: AppColors.ink, size: 19),
            Text(
              label,
              maxLines: 1,
              style: TextStyle(fontSize: 10.5, height: 1.1, fontWeight: FontWeight.w700, color: AppColors.ink),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Catalogue vide : accueillant, avec les deux façons d'ajouter des produits.
class _EmptyCatalog extends ConsumerWidget {
  const _EmptyCatalog({required this.onScan});
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const GlossyOrb(icon: Icons.storefront_rounded, color: Color(0xFF19B56F), size: 72),
          const SizedBox(height: 16),
          const Text(
            'Votre caisse est prête',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            'Ajoutez vos produits une fois : ensuite, une touche suffit pour vendre.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.muted, height: 1.35),
          ),
          const SizedBox(height: 18),
          if (ref.can('catalog:write'))
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(220, 50)),
              onPressed: () => context.push('/products/new'),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Ajouter un produit'),
            ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(220, 46)),
            onPressed: onScan,
            icon: const Icon(Icons.qr_code_scanner_rounded),
            label: const Text('Scanner un article'),
          ),
        ],
      ),
    ),
  );
}

class _ProductCard extends StatelessWidget {
  const _ProductCard({
    required this.product,
    this.stock,
    required this.quantity,
    required this.onAdd,
    required this.onRemove,
    this.fromPrice,
    this.options = 0,
  });
  final Product product;

  /// Modèle à variantes : prix « dès », nombre de choix.
  final int? fromPrice;
  final int options;
  final StockItem? stock;
  final double quantity;
  final VoidCallback onAdd;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final inCart = quantity > 0;
    final low = stock?.low ?? false;
    final out = stock != null && stock!.onHand <= 0;
    final wholesale = product.unitPriceFor(quantity) != product.price;
    return AnimatedScale(
      scale: inCart ? 1.0 : 0.985,
      duration: const Duration(milliseconds: 160),
      child: Material(
        color: AppColors.surface(inCart ? 0.95 : 0.78),
        shadowColor: AppColors.green.withValues(alpha: 0.35),
        elevation: inCart ? 8 : 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: inCart ? AppColors.green : AppColors.glassLine, width: inCart ? 2 : 1.2),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: onAdd,
          onLongPress: inCart ? onRemove : null,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  children: [
                    ProductThumb(
                      name: product.name,
                      fileId: product.imageFileId,
                      height: 92,
                      radius: 16,
                      highlight: inCart,
                    ),
                    if (inCart)
                      Positioned(
                        top: 6,
                        right: 6,
                        child: Semantics(
                          label: 'Retirer un ${product.name}',
                          button: true,
                          child: InkWell(
                            onTap: onRemove,
                            borderRadius: BorderRadius.circular(14),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                              decoration: BoxDecoration(
                                color: AppColors.green,
                                borderRadius: BorderRadius.circular(14),
                                boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 6)],
                              ),
                              child: Text(
                                '×${qty(quantity)}',
                                style: TextStyle(color: AppColors.onGreen, fontSize: 12.5, fontWeight: FontWeight.w900),
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (out)
                      Positioned(
                        left: 6,
                        top: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                          decoration: BoxDecoration(color: AppColors.danger, borderRadius: BorderRadius.circular(10)),
                          child: const Text(
                            'Rupture',
                            style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      product.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, height: 1.2),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: fromPrice != null
                                        ? 'dès ${moneyShort(fromPrice!)}'
                                        : moneyShort(product.unitPriceFor(quantity)),
                                  ),
                                  if (options > 0)
                                    TextSpan(
                                      text: '  $options choix',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: AppColors.muted,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  if (wholesale)
                                    TextSpan(
                                      text: '  gros',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: AppColors.greenDark,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                ],
                              ),
                              style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800),
                            ),
                            if (stock != null)
                              Row(
                                children: [
                                  Container(
                                    width: 7,
                                    height: 7,
                                    decoration: BoxDecoration(
                                      color: out
                                          ? AppColors.danger
                                          : low
                                          ? AppColors.warn
                                          : AppColors.leaf,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                  Flexible(
                                    child: Text(
                                      low ? 'Stock bas : ${qty(stock!.onHand)}' : 'En stock : ${qty(stock!.onHand)}',
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: low ? AppColors.warn : AppColors.muted,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ),
                      ExcludeSemantics(
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: inCart ? AppColors.green : AppColors.greenSoft,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(Icons.add_rounded, size: 20, color: inCart ? AppColors.onGreen : AppColors.green),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CheckoutPanel extends ConsumerWidget {
  const _CheckoutPanel({required this.busy, required this.onCheckout, this.compact = false});
  final bool busy;
  final VoidCallback onCheckout;

  /// Téléphone : panier vide = une seule ligne (plus de place pour les produits) ;
  /// le nombre d'articles s'ouvre pour voir et ajuster les lignes du panier.
  final bool compact;

  void _showLines(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => Consumer(
      builder: (ctx, ref, _) {
        // Hauteur selon le nombre de lignes, sans dépasser 70 % de l'écran
        final lines = ref.watch(cartProvider).lines.length;
        final h = (110.0 + lines * 72).clamp(180.0, MediaQuery.sizeOf(ctx).height * 0.7);
        return SizedBox(height: h, child: const _CartLines());
      },
    ),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cart = ref.watch(cartProvider);
    final ctrl = ref.read(cartProvider.notifier);
    final credit = cart.mode == PaymentMode.credit;
    final n = cart.itemCount;
    final mustOpen = ref.watch(mustOpenCashProvider);

    // Panier vide sur téléphone : une ligne discrète, les produits gardent la place
    if (compact && cart.isEmpty && !mustOpen) {
      return Padding(
        padding: EdgeInsets.fromLTRB(10, 4, 10, 8 + MediaQuery.paddingOf(context).bottom),
        child: Glass(
          key: const Key('pos_compact_panel'),
          radius: 24,
          padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
          child: Row(
            children: [
              Icon(Icons.touch_app_rounded, color: AppColors.muted, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Touchez un produit',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: AppColors.muted, fontWeight: FontWeight.w600),
                ),
              ),
              Flexible(
                child: _CustomerChip(
                  customer: cart.customer,
                  onPick: () async {
                    final c = await pickCustomer(context);
                    if (c != null) ctrl.setCustomer(c);
                  },
                  onClear: () => ctrl.setCustomer(null),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Panneau du panier : carte flottante en verre.
    return Padding(
      padding: EdgeInsets.fromLTRB(10, 4, 10, 8 + MediaQuery.paddingOf(context).bottom),
      child: Glass(
        radius: 28,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Une seule ligne : total à gauche, client et « vider » à droite
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      InkWell(
                        key: const Key('cart_lines_open'),
                        borderRadius: BorderRadius.circular(8),
                        onTap: compact && n > 0 ? () => _showLines(context) : null,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                n == 0
                                    ? 'Panier vide'
                                    : cart.loyaltyDiscount > 0
                                    ? '${qty(n)} article${n > 1 ? 's' : ''} · au lieu de ${moneyShort(cart.subtotal)}'
                                    : '${qty(n)} article${n > 1 ? 's' : ''}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: compact && n > 0 ? AppColors.green : AppColors.muted,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            if (compact && n > 0) ...[
                              Text(
                                ' · voir',
                                style: TextStyle(fontSize: 12, color: AppColors.green, fontWeight: FontWeight.w700),
                              ),
                              Icon(Icons.expand_less_rounded, size: 16, color: AppColors.green),
                            ],
                          ],
                        ),
                      ),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: CountUp(
                          value: cart.total,
                          builder: (context, shown) => Text(
                            money(shown),
                            style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.5,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: _CustomerChip(
                    customer: cart.customer,
                    onPick: () async {
                      final c = await pickCustomer(context);
                      if (c != null) ctrl.setCustomer(c);
                    },
                    onClear: () => ctrl.setCustomer(null),
                  ),
                ),
                if (!cart.isEmpty) TrashButton(tooltip: 'Vider le panier', onPressed: ctrl.clear),
              ],
            ),
            if (cart.customer != null && !cart.isEmpty) LoyaltyRewardChip(customer: cart.customer!),
            const SellingAtBanner(),
            const SizedBox(height: 10),
            Builder(
              builder: (context) {
                final modes = PaymentMode.forCountry(ref.watch(countryProvider));
                // 4 boutons sur une ligne ; au-delà (Côte d'Ivoire), deux lignes de 3
                final perRow = modes.length <= 4 ? modes.length : 3;
                return Column(
                  children: [
                    for (var i = 0; i < modes.length; i += perRow) ...[
                      if (i > 0) const SizedBox(height: 8),
                      Row(
                        children: [
                          for (final (j, m) in modes.skip(i).take(perRow).indexed) ...[
                            if (j > 0) const SizedBox(width: 8),
                            Expanded(
                              child: _ModeButton(mode: m, selected: cart.mode == m, onTap: () => ctrl.setMode(m)),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ],
                );
              },
            ),
            if (credit) ...[
              const SizedBox(height: 10),
              TextField(
                key: const Key('deposit'),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Avance payée en espèces (facultatif)',
                  suffixText: 'F',
                  isDense: true,
                ),
                onChanged: (v) => ctrl.setDeposit(int.tryParse(v) ?? 0),
              ),
              if (cart.total > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Reste à crédit : ${money((cart.total - cart.deposit).clamp(0, cart.total))}',
                    style: TextStyle(color: AppColors.warnText, fontWeight: FontWeight.w700, fontSize: 13),
                  ),
                ),
              if (cart.customer?.creditLimit != null)
                _CreditLimitHint(customer: cart.customer!, due: cart.total - cart.deposit),
            ],
            if (!credit && !cart.isEmpty && !mustOpen) _PayQrButton(onCheckout: onCheckout),
            const SizedBox(height: 12),
            SizedBox(
              height: 52,
              child: mustOpen
                  // Caisse obligatoire (option du patron) : on ouvre la caisse avant d'encaisser
                  ? BusyButton(
                      key: const Key('open_cash_to_sell'),
                      icon: Icons.lock_open_rounded,
                      label: 'Ouvrez la caisse pour vendre',
                      busy: false,
                      onPressed: () => context.push('/cash'),
                    )
                  : BusyButton(
                      accent: true,
                      icon: cart.isEmpty ? null : (credit ? Icons.menu_book_rounded : Icons.check_circle_rounded),
                      label: cart.isEmpty
                          ? 'Encaisser'
                          : (credit ? 'Valider à crédit' : 'Encaisser ${money(cart.total)}'),
                      busy: busy,
                      onPressed: cart.isEmpty ? null : onCheckout,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Paiement mobile : montrer au client le QR (ou le numéro) du commerçant avec le montant.
class _PayQrButton extends ConsumerWidget {
  const _PayQrButton({required this.onCheckout});
  final VoidCallback onCheckout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cart = ref.watch(cartProvider);
    final b = ref.watch(currentBusinessProvider).value;
    final m = cart.mode.method;
    final account = payAccountFor(b, m);
    if (account != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: OutlinedButton.icon(
          key: const Key('show_pay_qr'),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46)),
          onPressed: () async {
            final paid = await showPayQr(
              context,
              businessName: b!.name,
              country: b.country,
              method: m!,
              account: account,
              amount: cart.total,
            );
            if (paid) onCheckout();
          },
          icon: const Icon(Icons.qr_code_2_rounded),
          label: Text((account.link ?? '').isNotEmpty ? 'Montrer le QR au client' : 'Montrer mon numéro au client'),
        ),
      );
    }
    if (canSetupPayAccount(b, m) && ref.can('business:update')) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: TextButton.icon(
          key: const Key('setup_pay_qr'),
          style: TextButton.styleFrom(minimumSize: const Size(0, 40)),
          onPressed: () => context.push(payAccountsRoute),
          icon: const Icon(Icons.qr_code_2_rounded, size: 18),
          label: Text('Ajoutez votre numéro ${m!.label} : le client verra où payer'),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

/// Client de la vente : « Ajouter un client » ou son nom (avec la croix pour le retirer).
class _CustomerChip extends StatelessWidget {
  const _CustomerChip({required this.customer, required this.onPick, required this.onClear});
  final Contact? customer;
  final VoidCallback onPick;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final c = customer;
    return TapTarget(
      onTap: onPick,
      child: Material(
        color: c == null ? AppColors.surface(0.6) : AppColors.greenSoft,
        shape: StadiumBorder(
          side: BorderSide(color: c == null ? AppColors.line : AppColors.green.withValues(alpha: 0.4)),
        ),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onPick,
          child: Padding(
            padding: EdgeInsets.fromLTRB(4, 4, c == null ? 14 : 4, 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (c == null)
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(color: AppColors.greenSoft, shape: BoxShape.circle),
                    child: Icon(Icons.person_add_alt_1_rounded, size: 16, color: AppColors.green),
                  )
                else
                  Avatar(name: c.name, size: 28),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    c?.name ?? 'Client',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: c == null ? AppColors.ink : AppColors.greenDark,
                    ),
                  ),
                ),
                if (c != null)
                  IconButton(
                    tooltip: 'Retirer le client',
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    padding: EdgeInsets.zero,
                    onPressed: onClear,
                    icon: Icon(Icons.close_rounded, size: 18, color: AppColors.greenDark),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Crédit encore possible pour le client choisi (plafond − dette actuelle).
class _CreditLimitHint extends StatelessWidget {
  const _CreditLimitHint({required this.customer, required this.due});
  final Contact customer;
  final int due;

  @override
  Widget build(BuildContext context) {
    final available = (customer.creditLimit! - customer.balance).clamp(0, customer.creditLimit!);
    final over = due > available;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        over
            ? 'Dépasse son crédit maximum : ${money(available)} au plus'
            : 'Crédit encore possible : ${money(available)}',
        style: TextStyle(
          color: over ? AppColors.danger : AppColors.muted,
          fontWeight: over ? FontWeight.w700 : FontWeight.w500,
          fontSize: 12.5,
        ),
      ),
    );
  }
}

/// Rappel discret : la caisse n'est pas ouverte (les ventes restent possibles).
class _CashClosedBanner extends ConsumerWidget {
  const _CashClosedBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final closed = ref.watch(cashCurrentProvider).maybeWhen(data: (s) => s == null, orElse: () => false);
    if (!closed) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Material(
        color: AppColors.warnBg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: AppColors.warnLine),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => context.push('/cash'),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(color: AppColors.warn.withValues(alpha: 0.15), shape: BoxShape.circle),
                  child: Icon(Icons.lock_clock_rounded, size: 19, color: AppColors.warn),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    ref.watch(mustOpenCashProvider)
                        ? 'Caisse fermée : ouvrez-la pour pouvoir vendre'
                        : 'Caisse non ouverte : ouvrez-la pour suivre vos espèces',
                    style: TextStyle(color: AppColors.warnText, fontWeight: FontWeight.w700, fontSize: 13),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    backgroundColor: AppColors.warn,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () => context.push('/cash'),
                  child: const Text('Ouvrir'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  const _ModeButton({required this.mode, required this.selected, required this.onTap});

  /// Couleur de l'icône quand le bouton n'est pas choisi (repère visuel du moyen de paiement).
  Color get _accent => switch (mode) {
    PaymentMode.cash => AppColors.green,
    PaymentMode.wave => const Color(0xFF1D9BF0),
    PaymentMode.orangeMoney => const Color(0xFFF07B14),
    PaymentMode.freeMoney => const Color(0xFFCD1E25),
    PaymentMode.mtnMomo => const Color(0xFFC79A00),
    PaymentMode.moovMoney => const Color(0xFF0066B3),
    PaymentMode.airtelMoney => const Color(0xFFE40000),
    PaymentMode.credit => AppColors.warn,
  };

  /// Bouton choisi : fond doux, bordure et texte de la couleur du moyen de paiement (adaptés au mode sombre).
  static (Color, Color, Color) _selected(Color soft, Color border, Color text) {
    final (bg, fg) = AppColors.tone(soft, text);
    return (bg, AppColors.isDark ? fg : border, fg);
  }

  final PaymentMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (bg, border, fg) = switch ((mode, selected)) {
      (PaymentMode.wave, true) => _selected(const Color(0xFFEAF5FE), const Color(0xFF1D9BF0), const Color(0xFF0B4F82)),
      (PaymentMode.orangeMoney, true) => _selected(
        const Color(0xFFFFF1E6),
        const Color(0xFFF07B14),
        const Color(0xFF8A3D00),
      ),
      (PaymentMode.mtnMomo, true) => _selected(
        const Color(0xFFFFF7D6),
        const Color(0xFFFFCC00),
        const Color(0xFF5C4A00),
      ),
      (PaymentMode.moovMoney, true) => _selected(
        const Color(0xFFE6F1FA),
        const Color(0xFF0066B3),
        const Color(0xFF003B66),
      ),
      (PaymentMode.airtelMoney || PaymentMode.freeMoney, true) => _selected(
        const Color(0xFFFDE8E8),
        const Color(0xFFE40000),
        const Color(0xFF7A0000),
      ),
      (PaymentMode.credit, true) => _selected(AppColors.warnBg, AppColors.warn, AppColors.warnText),
      (_, true) => _selected(AppColors.greenSoft, AppColors.green, AppColors.greenDark),
      _ => (AppColors.surface(), AppColors.line, AppColors.ink),
    };
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: border, width: selected ? 2 : 1),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: SizedBox(
            height: 60,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                PayLogo(mode.method, size: 22, color: selected ? fg : _accent),
                const SizedBox(height: 2),
                Text(
                  mode.label,
                  style: TextStyle(fontSize: 12, fontWeight: selected ? FontWeight.w800 : FontWeight.w600, color: fg),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Client choisi avec des points : propose d'utiliser une récompense (remise) sur cette vente.
class LoyaltyRewardChip extends ConsumerWidget {
  const LoyaltyRewardChip({super.key, required this.customer});
  final Contact customer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(loyaltySettingsProvider).value;
    if (settings == null || !settings.enabled) return const SizedBox.shrink();
    final card = ref.watch(loyaltyCardProvider(customer.id)).value;
    if (card == null) return const SizedBox.shrink();
    final cart = ref.watch(cartProvider);
    final ctrl = ref.read(cartProvider.notifier);
    final online = ref.watch(onlineProvider);
    final used = cart.rewards;
    // Pas plus de récompenses que le client n'en a, ni que le montant des articles
    final maxBySubtotal = settings.rewardValue == 0 ? 0 : cart.subtotal ~/ settings.rewardValue;
    final max = math.min(card.rewardsAvailable, maxBySubtotal);
    final earn = settings.pointsFor(cart.total);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        key: const Key('loyalty_chip'),
        padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
        decoration: BoxDecoration(
          color: AppColors.softOf(const Color(0xFFFFF4E2), const Color(0xFF9A5B00)),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(Icons.stars_rounded, color: AppColors.strongOf(const Color(0xFFFFF4E2), const Color(0xFF9A5B00))),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    used > 0
                        ? 'Réduction fidélité : −${moneyShort(cart.loyaltyDiscount)}'
                        : '${card.balance} points${max > 0 ? ' · récompense disponible' : ''}',
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
                  ),
                  Text(
                    earn > 0 ? '+$earn points avec cet achat' : 'Points gagnés dès ${moneyShort(settings.earnPer)}',
                    style: TextStyle(color: AppColors.muted, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (used > 0)
              TextButton(onPressed: () => ctrl.setRewards(0, settings.rewardValue), child: const Text('Retirer'))
            else if (max > 0)
              TextButton(
                onPressed: online
                    ? () => ctrl.setRewards(1, settings.rewardValue)
                    : () => showInfo(context, 'Connexion nécessaire pour utiliser des points'),
                child: Text('Utiliser −${moneyShort(settings.rewardValue)}'),
              ),
          ],
        ),
      ),
    );
  }
}
