import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/api_client.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../customers/customer_picker.dart';
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

    final id = ref.read(cartProvider.notifier).ensureSaleId();
    setState(() => _busy = true);
    SaleResult sale;
    try {
      sale = await ref.read(repoProvider).createSale(
        id: id,
        customerId: cart.customer?.id,
        items: [for (final l in cart.lines.values) (productId: l.product.id, quantity: l.quantity)],
        payments: paymentsFor(cart.total, cart.mode, cart.deposit),
      );
    } on ApiException catch (e) {
      // Réseau coupé : le panier et son identifiant sont gardés, un nouvel essai ne crée pas de doublon.
      if (mounted) {
        setState(() => _busy = false);
        showError(context, e);
      }
      return;
    }
    ref.read(cartProvider.notifier).clear();
    refreshBusinessData(ref);
    if (!mounted) return;
    setState(() => _busy = false);
    await _showSuccess(sale, cart.customer);
  }

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
      actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Nouvelle vente'))],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final products = ref.watch(productsProvider);
    final categories = ref.watch(categoriesProvider).value ?? const <Category>[];
    final stock = ref.can('inventory:read') ? ref.watch(stockProvider).value : null;
    final onHand = {for (final s in stock?.items ?? const <StockItem>[]) s.productId: s};
    final cart = ref.watch(cartProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Nouvelle vente', style: TextStyle(fontWeight: FontWeight.w800))),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Rechercher un produit',
                prefixIcon: Icon(Icons.search),
                isDense: true,
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
                    mainAxisExtent: 158,
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
  const _ProductCard({required this.product, this.stock, required this.quantity, required this.onAdd, required this.onRemove});
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
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: inCart ? AppColors.green : AppColors.line, width: inCart ? 2 : 1),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onAdd,
        onLongPress: inCart ? onRemove : null,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: inCart ? AppColors.greenSoft : const Color(0xFFEEF4F0),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  productInitials(product.name),
                  style: const TextStyle(color: AppColors.green, fontWeight: FontWeight.w800, fontSize: 17),
                ),
              ),
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
                  Expanded(child: Text(moneyShort(product.price), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
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
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: low ? AppColors.warn : AppColors.muted),
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

    return Container(
      padding: EdgeInsets.fromLTRB(16, 14, 16, 14 + MediaQuery.paddingOf(context).bottom),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        boxShadow: [BoxShadow(color: Color(0x1014201C), blurRadius: 20, offset: Offset(0, -6))],
      ),
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
                        style: const TextStyle(fontSize: 12, color: AppColors.muted, decoration: TextDecoration.underline),
                      ),
                    ),
                    Text(money(cart.total), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                  ],
                ),
              ),
              if (!cart.isEmpty)
                TextButton(onPressed: ctrl.clear, child: const Text('Vider')),
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
              decoration: const InputDecoration(labelText: 'Acompte payé en espèces (facultatif)', suffixText: 'FCFA', isDense: true),
              onChanged: (v) => ctrl.setDeposit(int.tryParse(v) ?? 0),
            ),
            if (cart.total > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Reste à crédit : ${money((cart.total - cart.deposit).clamp(0, cart.total))}',
                  style: const TextStyle(color: AppColors.warn, fontWeight: FontWeight.w700, fontSize: 13),
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
