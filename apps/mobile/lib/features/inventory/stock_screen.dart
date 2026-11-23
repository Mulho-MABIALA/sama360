import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../catalog/product_photo.dart';
import '../catalog/scan_lookup.dart';

/// Stock (maquette « Stock ») : valeur, stock bas, liste des produits, entrées et nouveaux produits.
class StockScreen extends ConsumerStatefulWidget {
  const StockScreen({super.key, this.lowOnly = false});
  final bool lowOnly;
  @override
  ConsumerState<StockScreen> createState() => _StockScreenState();
}

class _StockScreenState extends ConsumerState<StockScreen> {
  late bool _lowOnly = widget.lowOnly;
  String _search = '';
  final _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant StockScreen old) {
    super.didUpdateWidget(old);
    if (old.lowOnly != widget.lowOnly) _lowOnly = widget.lowOnly;
  }

  @override
  Widget build(BuildContext context) {
    final stock = ref.watch(stockProvider);
    final canWrite = ref.can('inventory:write');
    final canCatalog = ref.can('catalog:write');
    final costs = seesCosts(ref.watch(currentBusinessProvider).value?.permissions ?? const []);

    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Stock', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          if (canWrite && (ref.watch(locationsProvider).value?.several ?? false))
            IconButton(
              key: const Key('stock_transfer'),
              tooltip: 'Transférer entre points de vente',
              onPressed: () => context.push('/stock/transfer'),
              icon: const Icon(Icons.swap_horiz_rounded),
            ),
          if (ref.can('purchasing:read'))
            IconButton(
              tooltip: 'Achats et fournisseurs',
              onPressed: () => context.push('/purchases'),
              icon: const Icon(Icons.local_shipping_outlined),
            ),
          IconButton(
            tooltip: 'Catégories',
            onPressed: () => context.push('/categories'),
            icon: const Icon(Icons.label_outline_rounded),
          ),
        ],
      ),
      floatingActionButton: canCatalog
          ? FloatingActionButton.extended(
              onPressed: () => _openNewProduct(context),
              backgroundColor: AppColors.green,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add),
              label: const Text('Nouveau produit', style: TextStyle(fontWeight: FontWeight.w800)),
            )
          : null,
      body: AsyncView<StockOverview>(
        value: stock,
        onRetry: () => ref.invalidate(stockRawProvider),
        data: (s) {
          final items = s.items
              .where((i) => !_lowOnly || i.low)
              .where((i) => _search.isEmpty || i.name.toLowerCase().contains(_search))
              .toList();
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(stockRawProvider),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
              children: [
                Row(
                  children: [
                    // Valeur du stock (prix d'achat) : pas pour le vendeur
                    if (costs) ...[
                      Expanded(
                        child: StatTile(label: 'Valeur du stock', value: moneyShort(s.stockValue)),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: StatTile(label: 'Produits', value: '${s.items.length}'),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: StatTile(label: 'Stock bas', value: '${s.lowStock}', warn: s.lowStock > 0),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _searchCtrl,
                  decoration: InputDecoration(
                    hintText: 'Rechercher',
                    prefixIcon: const Icon(Icons.search),
                    isDense: true,
                    suffixIcon: IconButton(
                      tooltip: 'Scanner un article',
                      onPressed: () => _scan(context, s),
                      icon: const Icon(Icons.qr_code_scanner_rounded),
                    ),
                  ),
                  onChanged: (v) => setState(() => _search = v.trim().toLowerCase()),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Pill(label: 'Tous', selected: !_lowOnly, onTap: () => setState(() => _lowOnly = false)),
                    const SizedBox(width: 8),
                    Pill(label: 'Stock bas', selected: _lowOnly, onTap: () => setState(() => _lowOnly = true)),
                  ],
                ),
                if (_lowOnly && s.lowStock > 0 && ref.can('inventory:write')) ...[
                  const SizedBox(height: 10),
                  FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44)),
                    onPressed: () => context.push('/purchases/new?low=1'),
                    icon: const Icon(Icons.add_shopping_cart_rounded, size: 18),
                    label: const Text('Commander les produits en stock bas'),
                  ),
                ],
                const SizedBox(height: 12),
                if (items.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      s.items.isEmpty
                          ? 'Aucun produit suivi en stock.\nAjoutez votre premier produit.'
                          : 'Aucun produit ne correspond.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.muted),
                    ),
                  ),
                for (final it in items)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _StockRow(item: it, onTap: canWrite ? () => _openEntry(context, it) : null),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _openEntry(BuildContext context, StockItem item) async {
    final done = await showModalBottomSheet<bool>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _StockEntrySheet(item: item),
    );
    if (done == true && context.mounted) {
      refreshBusinessData(ref);
      showInfo(context, 'Stock mis à jour');
    }
  }

  Future<void> _openNewProduct(BuildContext context) => context.push('/products/new');

  /// Scan en réserve : ouvre l'entrée de stock de l'article (ou le retrouve dans la liste).
  Future<void> _scan(BuildContext context, StockOverview overview) async {
    final product = await scanForProduct(context, ref);
    if (product == null || !context.mounted) return;
    final item = overview.items.where((i) => i.productId == product.id).firstOrNull;
    if (item != null && ref.read(canProvider('inventory:write'))) {
      await _openEntry(context, item);
      return;
    }
    // Pas de droit d'écriture, ou produit absent de la liste : on le montre via la recherche
    _searchCtrl.text = product.name;
    setState(() {
      _search = product.name.toLowerCase();
      _lowOnly = false;
    });
    if (item == null) showInfo(context, '${product.name} n’est pas suivi en stock');
  }
}

class _StockRow extends ConsumerWidget {
  const _StockRow({required this.item, this.onTap});
  final StockItem item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Tous les points de vente regardés : le détail par point de vente sous le nom
    final locs = ref.watch(locationsProvider).value;
    final breakdown = locs != null && locs.several && locs.currentId == null
        ? [
            for (final l in locs.list)
              if ((item.byLocation[l.id] ?? 0) != 0) '${l.name} ${qty(item.byLocation[l.id]!)}',
          ].join(' · ')
        : '';
    final costs = seesCosts(ref.watch(currentBusinessProvider).value?.permissions ?? const []);
    return _card(context, breakdown, costs);
  }

  Widget _card(BuildContext context, String breakdown, bool costs) => Card(
    child: InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            ProductThumb(name: item.name, fileId: item.imageFileId, size: 48),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    costs ? '${moneyShort(item.price)} · marge ${item.margin} %' : moneyShort(item.price),
                    style: TextStyle(fontSize: 12, color: AppColors.muted),
                  ),
                  if (breakdown.isNotEmpty)
                    Text(
                      breakdown,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: AppColors.muted, fontWeight: FontWeight.w600),
                    ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  qty(item.onHand),
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: item.low ? AppColors.warn : AppColors.ink,
                  ),
                ),
                if (item.low)
                  Container(
                    margin: const EdgeInsets.only(top: 3),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(color: AppColors.warnBg, borderRadius: BorderRadius.circular(6)),
                    child: Text(
                      'Seuil ${item.threshold}',
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.warnText),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

int? _parseInt(String v) => int.tryParse(v.replaceAll(RegExp(r'\s'), ''));

class _StockEntrySheet extends ConsumerStatefulWidget {
  const _StockEntrySheet({required this.item});
  final StockItem item;
  @override
  ConsumerState<_StockEntrySheet> createState() => _StockEntrySheetState();
}

class _StockEntrySheetState extends ConsumerState<_StockEntrySheet> {
  final _qty = TextEditingController();
  late final _cost = TextEditingController(text: widget.item.cost > 0 ? '${widget.item.cost}' : '');
  bool _busy = false;

  @override
  void dispose() {
    _qty.dispose();
    _cost.dispose();
    super.dispose();
  }

  Future<void> _changePhoto() async {
    final photo = await choosePhoto(context, ref);
    if (photo == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(repoProvider).uploadProductImage(widget.item.productId, photo.bytes, filename: photo.filename);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e);
      setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final q = double.tryParse(_qty.text.replaceAll(',', '.')) ?? 0;
    if (q <= 0) return;
    setState(() => _busy = true);
    try {
      await ref.read(repoProvider).addStock(widget.item.productId, q, unitCost: _parseInt(_cost.text));
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e);
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            ProductThumb(name: widget.item.name, fileId: widget.item.imageFileId, size: 56),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Entrée de stock', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  Text(
                    '${widget.item.name} · actuellement ${qty(widget.item.onHand)}',
                    style: TextStyle(color: AppColors.muted),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (ref.can('catalog:write'))
          Wrap(
            spacing: 4,
            children: [
              TextButton.icon(
                onPressed: _busy ? null : _changePhoto,
                icon: const Icon(Icons.add_a_photo_outlined, size: 18),
                label: Text(widget.item.imageFileId == null ? 'Ajouter une photo' : 'Changer la photo'),
              ),
              TextButton.icon(
                onPressed: _busy
                    ? null
                    : () {
                        Navigator.pop(context);
                        GoRouter.of(context).push('/products/${widget.item.productId}');
                      },
                icon: const Icon(Icons.edit_note_rounded, size: 20),
                label: const Text('Modifier la fiche'),
              ),
            ],
          ),
        const SizedBox(height: 16),
        TextField(
          controller: _qty,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Quantité reçue'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _cost,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(labelText: "Coût d'achat unitaire", suffixText: 'FCFA'),
        ),
        const SizedBox(height: 16),
        BusyButton(label: 'Ajouter au stock', busy: _busy, onPressed: _save),
      ],
    ),
  );
}
