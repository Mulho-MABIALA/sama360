import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/api_client.dart';
import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/offline/pending_sales.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../catalog/product_photo.dart';
import '../customers/customer_picker.dart';
import '../offline/offline_ui.dart';
import '../catalog/barcode_scanner.dart';
import 'cart.dart';

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
            payments: paymentsFor(cart.total, cart.mode, cart.deposit),
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

  /// Scan en caisse : le produit trouvé va au panier ; un code inconnu propose de créer la fiche.
  Future<void> _scan() async {
    final code = await ref.read(barcodeScannerProvider)(context);
    if (code == null || !mounted) return;
    Product? product;
    try {
      product = await ref.read(repoProvider).productByCode(code);
    } catch (e) {
      if (mounted) showError(context, e);
      return;
    }
    if (!mounted) return;
    if (product != null) {
      HapticFeedback.mediumImpact();
      ref.read(cartProvider.notifier).add(product);
      showInfo(context, '${product.name} ajouté au panier');
      return;
    }
    final create = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.qr_code_2_rounded, size: 40),
        title: const Text('Produit inconnu'),
        content: Text(
          'Aucun produit n’a le code $code.${ref.can('catalog:write') ? ' Voulez-vous créer sa fiche ?' : ''}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Fermer')),
          if (ref.can('catalog:write'))
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Créer la fiche')),
        ],
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
      icon: const Icon(Icons.cloud_off_rounded, color: AppColors.warn, size: 46),
      title: const Text('Vente gardée sur le téléphone'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(money(p.total), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          const Text(
            'Pas de connexion pour l’instant. La vente est bien enregistrée sur ce téléphone '
            'et sera envoyée automatiquement dès le retour du réseau.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.muted),
          ),
        ],
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Nouvelle vente'))],
    ),
  );

  Future<void> _showSuccess(SaleResult sale, Contact? customer) => showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.check_circle_rounded, color: AppColors.green, size: 48),
      title: const Text('Vente enregistrée'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(sale.number, style: const TextStyle(color: AppColors.muted)),
          const SizedBox(height: 8),
          Text(money(sale.total), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
          if (sale.due > 0) ...[
            const SizedBox(height: 8),
            Text(
              '${money(sale.due)} ajoutés au crédit de ${customer?.name ?? 'ce client'}',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.warn, fontWeight: FontWeight.w700),
            ),
          ],
        ],
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                context.push('/sales/${sale.id}');
              },
              icon: const Icon(Icons.receipt_long_rounded),
              label: const Text('Voir le reçu'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: () => Navigator.pop(ctx), child: const Text('Nouvelle vente')),
          ],
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final products = ref.watch(productsProvider);
    final categories = ref.watch(categoriesProvider).value ?? const <Category>[];
    final stock = ref.can('inventory:read') ? ref.watch(stockProvider).value : null;
    final onHand = {for (final s in stock?.items ?? const <StockItem>[]) s.productId: s};
    final cart = ref.watch(cartProvider);

    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Nouvelle vente', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
            tooltip: "Ventes d'aujourd'hui",
            onPressed: () => context.push('/sales'),
            icon: const Icon(Icons.receipt_long_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          const SyncBanner(padding: EdgeInsets.fromLTRB(16, 0, 16, 10)),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Rechercher un produit',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                suffixIcon: IconButton(
                  tooltip: 'Scanner un code-barres',
                  onPressed: _scan,
                  icon: const Icon(Icons.qr_code_scanner_rounded, color: AppColors.green),
                ),
              ),
              onChanged: (v) => setState(() => _search = v.trim().toLowerCase()),
            ),
          ),
          if (categories.isNotEmpty)
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  Pill(label: 'Tout', selected: _categoryId == null, onTap: () => setState(() => _categoryId = null)),
                  for (final c in categories) ...[
                    const SizedBox(width: 8),
                    Pill(label: c.name, selected: _categoryId == c.id, onTap: () => setState(() => _categoryId = c.id)),
                  ],
                ],
              ),
            ),
          const SizedBox(height: 10),
          Expanded(
            child: AsyncView<List<Product>>(
              value: products,
              onRetry: () => ref.invalidate(productsProvider),
              data: (list) {
                final shown = list
                    .where((p) => _categoryId == null || p.categoryId == _categoryId)
                    .where((p) => _search.isEmpty || p.name.toLowerCase().contains(_search))
                    .toList();
                if (list.isEmpty) {
                  return const _EmptyCatalog();
                }
                return GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 200,
                    mainAxisExtent: 186,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                  ),
                  itemCount: shown.length,
                  itemBuilder: (_, i) => _ProductCard(
                    product: shown[i],
                    stock: onHand[shown[i].id],
                    quantity: cart.quantityOf(shown[i].id),
                    onAdd: () {
                      HapticFeedback.selectionClick();
                      ref.read(cartProvider.notifier).add(shown[i]);
                    },
                    onRemove: () => ref.read(cartProvider.notifier).remove(shown[i].id),
                  ),
                );
              },
            ),
          ),
          _CheckoutPanel(busy: _busy, onCheckout: _checkout),
        ],
      ),
    );
  }
}

class _EmptyCatalog extends StatelessWidget {
  const _EmptyCatalog();
  @override
  Widget build(BuildContext context) => const Center(
    child: Padding(
      padding: EdgeInsets.all(32),
      child: Text(
        'Aucun produit pour l’instant.\nAjoutez vos produits depuis l’onglet Stock.',
        textAlign: TextAlign.center,
        style: TextStyle(color: AppColors.muted),
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
  });
  final Product product;
  final StockItem? stock;
  final double quantity;
  final VoidCallback onAdd;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final inCart = quantity > 0;
    final low = stock?.low ?? false;
    return Material(
      color: Colors.white.withValues(alpha: inCart ? 0.92 : 0.74),
      shadowColor: const Color(0x330B3D2E),
      elevation: inCart ? 6 : 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: inCart ? AppColors.green : AppColors.glassLine, width: inCart ? 2 : 1.2),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onAdd,
        onLongPress: inCart ? onRemove : null,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ProductThumb(name: product.name, fileId: product.imageFileId, height: 76, highlight: inCart),
              const SizedBox(height: 8),
              Expanded(
                child: Text(
                  product.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, height: 1.2),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: product.unitPriceFor(quantity) != product.price
                        // Prix de gros atteint
                        ? Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(text: moneyShort(product.unitPriceFor(quantity))),
                                const TextSpan(
                                  text: '  gros',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: AppColors.greenDark,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ),
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                          )
                        : Text(
                            moneyShort(product.price),
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                          ),
                  ),
                  if (inCart)
                    Semantics(
                      label: 'Retirer un ${product.name}',
                      button: true,
                      child: InkWell(
                        onTap: onRemove,
                        borderRadius: BorderRadius.circular(14),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(color: AppColors.green, borderRadius: BorderRadius.circular(14)),
                          child: Text(
                            '×${qty(quantity)}',
                            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              if (stock != null)
                Text(
                  low ? 'Stock bas : ${qty(stock!.onHand)}' : 'En stock : ${qty(stock!.onHand)}',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: low ? AppColors.warn : AppColors.muted,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CheckoutPanel extends ConsumerWidget {
  const _CheckoutPanel({required this.busy, required this.onCheckout});
  final bool busy;
  final VoidCallback onCheckout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cart = ref.watch(cartProvider);
    final ctrl = ref.read(cartProvider.notifier);
    final credit = cart.mode == PaymentMode.credit;
    final articles = qty(cart.itemCount);

    // Panneau du panier : carte flottante en verre.
    return Padding(
      padding: EdgeInsets.fromLTRB(10, 4, 10, 8 + MediaQuery.paddingOf(context).bottom),
      child: Glass(
        radius: 28,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      InkWell(
                        onTap: () async {
                          final c = await pickCustomer(context);
                          if (c != null) ctrl.setCustomer(c);
                        },
                        child: Text(
                          cart.customer == null
                              ? '$articles article(s) · Choisir un client'
                              : '$articles article(s) · ${cart.customer!.name}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.muted,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                      Text(money(cart.total), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                    ],
                  ),
                ),
                if (!cart.isEmpty) TextButton(onPressed: ctrl.clear, child: const Text('Vider')),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                for (final m in PaymentMode.values) ...[
                  Expanded(
                    child: _ModeButton(mode: m, selected: cart.mode == m, onTap: () => ctrl.setMode(m)),
                  ),
                  if (m != PaymentMode.values.last) const SizedBox(width: 8),
                ],
              ],
            ),
            if (credit) ...[
              const SizedBox(height: 10),
              TextField(
                key: const Key('deposit'),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Acompte payé en espèces (facultatif)',
                  suffixText: 'FCFA',
                  isDense: true,
                ),
                onChanged: (v) => ctrl.setDeposit(int.tryParse(v) ?? 0),
              ),
              if (cart.total > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Reste à crédit : ${money((cart.total - cart.deposit).clamp(0, cart.total))}',
                    style: const TextStyle(color: AppColors.warnText, fontWeight: FontWeight.w700, fontSize: 13),
                  ),
                ),
            ],
            const SizedBox(height: 12),
            BusyButton(
              label: cart.isEmpty ? 'Encaisser' : (credit ? 'Valider à crédit' : 'Encaisser ${money(cart.total)}'),
              busy: busy,
              onPressed: cart.isEmpty ? null : onCheckout,
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  const _ModeButton({required this.mode, required this.selected, required this.onTap});
  final PaymentMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (bg, border, fg) = switch ((mode, selected)) {
      (PaymentMode.wave, true) => (const Color(0xFFEAF5FE), const Color(0xFF1D9BF0), const Color(0xFF0B4F82)),
      (PaymentMode.orangeMoney, true) => (const Color(0xFFFFF1E6), const Color(0xFFF07B14), const Color(0xFF8A3D00)),
      (PaymentMode.credit, true) => (AppColors.warnBg, AppColors.warn, AppColors.warnText),
      (_, true) => (AppColors.greenSoft, AppColors.green, AppColors.greenDark),
      _ => (Colors.white, AppColors.line, AppColors.ink),
    };
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: border, width: selected ? 2 : 1),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: SizedBox(
            height: 44,
            child: Center(
              child: Text(
                mode.label,
                style: TextStyle(fontSize: 12, fontWeight: selected ? FontWeight.w800 : FontWeight.w600, color: fg),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
