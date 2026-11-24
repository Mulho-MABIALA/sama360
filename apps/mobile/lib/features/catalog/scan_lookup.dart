import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../sales/cart.dart';
import 'barcode_scanner.dart';

/// Scanne un code et renvoie le produit correspondant.
/// Code inconnu : propose de créer la fiche (avec le code déjà rempli) et renvoie le produit créé.
Future<Product?> scanForProduct(BuildContext context, WidgetRef ref) async {
  final code = await ref.read(barcodeScannerProvider)(context);
  if (code == null || !context.mounted) return null;
  Product? product;
  try {
    product = await ref.read(repoProvider).productByCode(code);
  } catch (e) {
    if (context.mounted) showError(context, e);
    return null;
  }
  if (product != null || !context.mounted) return product;
  final canCreate = ref.read(canProvider('catalog:write'));
  final create = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.qr_code_2_rounded, size: 40),
      title: const Text('Produit inconnu'),
      content: Text('Aucun produit n’a le code $code.${canCreate ? ' Voulez-vous créer sa fiche ?' : ''}'),
      actions: dialogActions([
        CancelButton(label: 'Fermer', onPressed: () => Navigator.pop(ctx, false)),
        if (canCreate) ConfirmButton(label: 'Créer la fiche', onPressed: () => Navigator.pop(ctx, true)),
      ]),
    ),
  );
  if (create != true || !context.mounted) return null;
  return context.push<Product>('/products/new?barcode=${Uri.encodeComponent(code)}');
}

/// Depuis l'accueil : scanner un article pour voir son prix et son stock, le vendre ou ouvrir sa fiche.
Future<void> scanAndShowProduct(BuildContext context, WidgetRef ref) async {
  final product = await scanForProduct(context, ref);
  if (product == null || !context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    builder: (_) => ProductQuickSheet(product: product),
  );
}

class ProductQuickSheet extends ConsumerWidget {
  const ProductQuickSheet({super.key, required this.product});
  final Product product;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = product;
    final stock = p.trackStock
        ? ref.watch(stockProvider).value?.items.where((i) => i.productId == p.id).firstOrNull
        : null;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(p.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            if (p.barcode != null) Text(p.barcode!, style: TextStyle(color: AppColors.muted, fontSize: 12.5)),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: StatTile(label: 'Prix', value: moneyShort(p.price)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: StatTile(
                    label: 'En stock',
                    value: !p.trackStock ? 'Non suivi' : (stock == null ? '…' : qty(stock.onHand)),
                    warn: stock?.low ?? false,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                if (ref.can('catalog:write')) ...[
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        shape: const StadiumBorder(),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: () {
                        Navigator.pop(context);
                        context.push('/products/${p.id}');
                      },
                      icon: const Icon(Icons.edit_rounded, size: 18),
                      label: const Text('Voir la fiche'),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                if (ref.can('sales:create'))
                  Expanded(
                    child: ConfirmButton(
                      label: 'Vendre',
                      onPressed: () {
                        ref.read(cartProvider.notifier).add(p);
                        Navigator.pop(context);
                        context.go('/pos');
                      },
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
