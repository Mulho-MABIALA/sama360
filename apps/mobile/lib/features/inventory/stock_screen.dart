import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../catalog/product_photo.dart';

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

    return Scaffold(
      appBar: AppBar(
        title: const Text('Stock', style: TextStyle(fontWeight: FontWeight.w800)),
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
        onRetry: () => ref.invalidate(stockProvider),
        data: (s) {
          final items = s.items
              .where((i) => !_lowOnly || i.low)
              .where((i) => _search.isEmpty || i.name.toLowerCase().contains(_search))
              .toList();
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(stockProvider),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: StatTile(label: 'Valeur du stock', value: moneyShort(s.stockValue)),
                    ),
                    const SizedBox(width: 8),
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
                  decoration: const InputDecoration(
                    hintText: 'Rechercher',
                    prefixIcon: Icon(Icons.search),
                    isDense: true,
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
                const SizedBox(height: 12),
                if (items.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      s.items.isEmpty
                          ? 'Aucun produit suivi en stock.\nAjoutez votre premier produit.'
                          : 'Aucun produit ne correspond.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppColors.muted),
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

  Future<void> _openNewProduct(BuildContext context) async {
    final done = await showModalBottomSheet<bool>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _NewProductSheet(),
    );
    if (done == true && context.mounted) {
      refreshBusinessData(ref);
      showInfo(context, 'Produit ajouté');
    }
  }
}

class _StockRow extends StatelessWidget {
  const _StockRow({required this.item, this.onTap});
  final StockItem item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Card(
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
                    '${moneyShort(item.price)} · marge ${item.margin} %',
                    style: const TextStyle(fontSize: 12, color: AppColors.muted),
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
                      style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.warnText),
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
                    style: const TextStyle(color: AppColors.muted),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (ref.can('catalog:write'))
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _busy ? null : _changePhoto,
              icon: const Icon(Icons.add_a_photo_outlined, size: 18),
              label: Text(widget.item.imageFileId == null ? 'Ajouter une photo' : 'Changer la photo'),
            ),
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

class _NewProductSheet extends ConsumerStatefulWidget {
  const _NewProductSheet();
  @override
  ConsumerState<_NewProductSheet> createState() => _NewProductSheetState();
}

class _NewProductSheetState extends ConsumerState<_NewProductSheet> {
  final _name = TextEditingController();
  final _price = TextEditingController();
  final _cost = TextEditingController();
  final _initial = TextEditingController();
  final _threshold = TextEditingController(text: '5');
  String? _categoryId;
  PickedPhoto? _photo;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _price, _cost, _initial, _threshold]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final price = _parseInt(_price.text);
    if (_name.text.trim().isEmpty || price == null) {
      setState(() => _error = 'Le nom et le prix de vente sont obligatoires');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final repo = ref.read(repoProvider);
    try {
      final p = await repo.createProduct(
        name: _name.text.trim(),
        price: price,
        cost: _parseInt(_cost.text) ?? 0,
        categoryId: _categoryId,
        lowStockThreshold: _parseInt(_threshold.text) ?? 5,
      );
      final initial = double.tryParse(_initial.text.replaceAll(',', '.')) ?? 0;
      if (initial > 0) await repo.addStock(p.id, initial);
      if (_photo != null) {
        try {
          await repo.uploadProductImage(p.id, _photo!.bytes, filename: _photo!.filename);
        } catch (e) {
          // Le produit est créé : on le signale sans bloquer, la photo pourra être ajoutée ensuite.
          if (mounted) showError(context, 'Produit créé, mais la photo n’a pas pu être envoyée : ${errorMessage(e)}');
        }
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() {
        _busy = false;
        _error = errorMessage(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final categories = ref.watch(categoriesProvider).value ?? const <Category>[];
    Widget money(TextEditingController c, String label) => TextField(
      controller: c,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(labelText: label, suffixText: 'F'),
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Nouveau produit', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 14),
            PhotoField(photo: _photo, onChanged: (p) => setState(() => _photo = p)),
            const SizedBox(height: 14),
            TextField(
              controller: _name,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Nom du produit'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: money(_price, 'Prix de vente')),
                const SizedBox(width: 10),
                Expanded(child: money(_cost, "Coût d'achat")),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _initial,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Stock initial'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _threshold,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(labelText: "Seuil d'alerte"),
                  ),
                ),
              ],
            ),
            if (categories.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final c in categories)
                    Pill(
                      label: c.name,
                      selected: _categoryId == c.id,
                      onTap: () => setState(() => _categoryId = _categoryId == c.id ? null : c.id),
                    ),
                ],
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: const TextStyle(color: AppColors.danger)),
            ],
            const SizedBox(height: 16),
            BusyButton(label: 'Enregistrer le produit', busy: _busy, onPressed: _save),
          ],
        ),
      ),
    );
  }
}
