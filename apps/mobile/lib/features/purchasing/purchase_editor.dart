import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uuid/uuid.dart';

import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/repositories.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../catalog/barcode_scanner.dart';
import '../catalog/product_photo.dart';
import 'invoice_scan_screen.dart';

/// Quantité proposée pour un produit en stock bas : de quoi remonter à deux fois le seuil.
double suggestedReorder(StockItem i) {
  final target = i.threshold * 2 - i.onHand;
  return target < 1 ? 1 : target.ceilToDouble();
}

/// Achat pré-rempli depuis une facture fournisseur en photo.
class PurchasePrefill {
  const PurchasePrefill({required this.supplier, required this.lines, this.note, this.received = true});
  final Contact supplier;
  final List<PurchaseLineDraft> lines;
  final String? note;

  /// La marchandise est arrivée avec la facture : entrée en stock à l'enregistrement.
  final bool received;
}

/// Création ou modification d'un bon de commande, ou achat direct (marchandise déjà reçue).
class PurchaseEditorScreen extends ConsumerStatefulWidget {
  const PurchaseEditorScreen({super.key, this.editId, this.supplierId, this.lowStock = false, this.prefill});
  final String? editId;
  final String? supplierId;
  final PurchasePrefill? prefill;

  /// Ouvert depuis l'alerte de stock bas : les produits concernés sont pré-remplis.
  final bool lowStock;

  @override
  ConsumerState<PurchaseEditorScreen> createState() => _PurchaseEditorScreenState();
}

class _PurchaseEditorScreenState extends ConsumerState<PurchaseEditorScreen> {
  final _id = const Uuid().v7(); // même identifiant à chaque essai : pas de doublon
  final _note = TextEditingController();
  final _paid = TextEditingController();
  Contact? _supplier;
  final _lines = <PurchaseLineDraft>[];
  int? _deliveryDays = 3; // null : pas de date
  bool _alreadyReceived = false;
  PayMethod _method = PayMethod.cash;
  bool _busy = false;
  bool _loaded = false;

  bool get _editing => widget.editId != null;
  int get _total => _lines.fold(0, (s, l) => s + l.total);

  @override
  void initState() {
    super.initState();
    Future(() async {
      try {
        if (_editing) {
          final d = await ref.read(purchaseProvider(widget.editId!).future);
          _supplier = d.supplier;
          _lines.addAll(d.lines.map(PurchaseLineDraft.fromLine));
          _note.text = d.note ?? '';
          _deliveryDays = d.summary.expectedDate?.difference(d.summary.orderDate).inDays;
        } else if (widget.prefill case final p?) {
          _supplier = p.supplier;
          _lines.addAll(p.lines);
          _note.text = p.note ?? '';
          _alreadyReceived = p.received;
        } else {
          if (widget.supplierId != null) {
            _supplier = (await ref.read(supplierProvider(widget.supplierId!).future)).supplier;
          }
          if (widget.lowStock) await _addLowStock(silent: true);
        }
      } catch (e) {
        if (mounted) showError(context, e);
      }
      if (mounted) setState(() => _loaded = true);
    });
  }

  @override
  void dispose() {
    _note.dispose();
    _paid.dispose();
    super.dispose();
  }

  void _add(Product p, {double quantity = 1}) {
    final i = _lines.indexWhere((l) => l.productId == p.id);
    setState(() {
      if (i >= 0) {
        _lines[i] = _lines[i].copyWith(quantity: _lines[i].quantity + quantity);
      } else {
        _lines.add(
          PurchaseLineDraft(productId: p.id, name: p.name, quantity: quantity, unitCost: p.cost, unit: p.unit),
        );
      }
    });
  }

  Future<void> _addLowStock({bool silent = false}) async {
    final stock = await ref.read(stockProvider.future);
    final low = stock.items.where((i) => i.low).toList();
    if (low.isEmpty) {
      if (!silent && mounted) showInfo(context, 'Aucun produit en stock bas');
      return;
    }
    final products = {for (final p in await ref.read(productsProvider.future)) p.id: p};
    var added = 0;
    for (final i in low) {
      if (_lines.any((l) => l.productId == i.productId)) continue;
      final p = products[i.productId];
      _lines.add(
        PurchaseLineDraft(
          productId: i.productId,
          name: i.name,
          quantity: suggestedReorder(i),
          unitCost: i.cost,
          unit: p?.unit ?? 'pièce',
        ),
      );
      added++;
    }
    if (mounted) {
      setState(() {});
      if (!silent) showInfo(context, '$added produit(s) en stock bas ajouté(s)');
    }
  }

  Future<void> _pickProduct() async {
    final p = await showModalBottomSheet<Product>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const ProductPicker(),
    );
    if (p != null) _add(p);
  }

  Future<void> _scan() async {
    final code = await ref.read(barcodeScannerProvider)(context);
    if (code == null || !mounted) return;
    try {
      final p = await ref.read(repoProvider).productByCode(code);
      if (!mounted) return;
      if (p == null) return showInfo(context, 'Aucun produit avec le code $code : créez sa fiche dans le stock');
      _add(p);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _pickSupplier() async {
    final s = await showModalBottomSheet<Contact>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const FractionallySizedBox(heightFactor: 0.8, child: SupplierPicker()),
    );
    if (s != null) setState(() => _supplier = s);
  }

  Future<void> _editLine(int index) async {
    final result = await showModalBottomSheet<PurchaseLineDraft?>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _LineSheet(line: _lines[index]),
    );
    if (result != null) setState(() => _lines[index] = result);
  }

  Future<void> _save({bool draft = false}) async {
    if (_supplier == null) return showInfo(context, 'Choisissez le fournisseur');
    if (_lines.isEmpty) return showInfo(context, 'Ajoutez au moins un produit');
    final paid = int.tryParse(_paid.text) ?? 0;
    if (_alreadyReceived && paid > _total) return showInfo(context, 'Le montant payé dépasse le total');
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final body = SamaRepository.purchaseBody(
      id: _editing ? null : _id,
      supplierId: _supplier!.id,
      lines: _lines,
      expectedDate: _alreadyReceived || _deliveryDays == null ? null : today.add(Duration(days: _deliveryDays!)),
      note: _note.text,
      draft: draft,
      receive: !_editing && _alreadyReceived,
      payment: !_editing && _alreadyReceived && paid > 0 ? (amount: paid, method: _method) : null,
    );
    setState(() => _busy = true);
    try {
      final repo = ref.read(repoProvider);
      final d = _editing ? await repo.updatePurchase(widget.editId!, body) : await repo.createPurchase(body);
      refreshPurchasing(ref);
      if (!mounted) return;
      showInfo(
        context,
        _editing
            ? 'Bon modifié'
            : _alreadyReceived
            ? 'Achat enregistré : le stock est à jour'
            : draft
            ? 'Enregistré, pas encore envoyé'
            : 'Commande ${d.number} créée',
      );
      if (_editing) {
        context.pop();
      } else {
        context.pushReplacement('/purchases/${d.id}');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuroraScaffold(
      appBar: AppBar(
        title: Text(_editing ? 'Modifier le bon' : 'Nouvel achat', style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    children: [
                      _Section(
                        title: 'Fournisseur',
                        child: _supplier == null
                            ? OutlinedButton.icon(
                                onPressed: _pickSupplier,
                                icon: const Icon(Icons.storefront_rounded),
                                label: const Text('Choisir le fournisseur'),
                              )
                            : ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: Avatar(
                                  name: _supplier!.name,
                                  bg: const Color(0xFFE6EFFC),
                                  fg: const Color(0xFF1F5BB8),
                                ),
                                title: Text(_supplier!.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                                subtitle: _supplier!.phone == null ? null : Text(intlPhone(_supplier!.phone!)),
                                trailing: TextButton(onPressed: _pickSupplier, child: const Text('Changer')),
                              ),
                      ),
                      const SizedBox(height: 12),
                      _Section(
                        title: 'Produits',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (_lines.isEmpty)
                              Padding(
                                padding: EdgeInsets.only(bottom: 8),
                                child: Text(
                                  'Ajoutez les produits à acheter : le prix proposé est votre coût d’achat actuel.',
                                  style: TextStyle(color: AppColors.muted, fontSize: 13),
                                ),
                              ),
                            for (final (i, l) in _lines.indexed)
                              _LineTile(
                                line: l,
                                onTap: () => _editLine(i),
                                onMinus: () => setState(() {
                                  if (l.quantity <= 1) {
                                    _lines.removeAt(i);
                                  } else {
                                    _lines[i] = l.copyWith(quantity: l.quantity - 1);
                                  }
                                }),
                                onPlus: () => setState(() => _lines[i] = l.copyWith(quantity: l.quantity + 1)),
                              ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                for (final (i, b) in [
                                  (Icons.inventory_2_rounded, 'Produit', _pickProduct, const Color(0xFF0F9D6B)),
                                  (Icons.qr_code_scanner_rounded, 'Scanner', _scan, const Color(0xFF2563EB)),
                                  (Icons.trending_down_rounded, 'Stock bas', _addLowStock, const Color(0xFFEA580C)),
                                  if (!_editing && _lines.isEmpty)
                                    (
                                      Icons.document_scanner_rounded,
                                      'Facture',
                                      () => startInvoiceScan(context, ref, replace: true),
                                      const Color(0xFF7A5AF8),
                                    ),
                                ].indexed) ...[
                                  if (i > 0) const SizedBox(width: 8),
                                  Expanded(
                                    child: OutlinedButton(
                                      style: OutlinedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
                                        minimumSize: const Size(0, 76),
                                      ),
                                      onPressed: b.$3,
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          // Pastille colorée : les raccourcis attirent l'œil
                                          Container(
                                            width: 34,
                                            height: 34,
                                            decoration: BoxDecoration(
                                              color: b.$4.withValues(alpha: 0.14),
                                              borderRadius: BorderRadius.circular(11),
                                            ),
                                            child: Icon(b.$1, size: 20, color: b.$4),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            b.$2,
                                            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (!_editing) ...[
                        _Section(
                          title: 'Livraison',
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              SwitchListTile(
                                key: const Key('alreadyReceived'),
                                contentPadding: EdgeInsets.zero,
                                value: _alreadyReceived,
                                onChanged: (v) => setState(() => _alreadyReceived = v),
                                title: const Text(
                                  'Marchandise déjà reçue',
                                  style: TextStyle(fontWeight: FontWeight.w700),
                                ),
                                subtitle: const Text(
                                  'Achat au marché ou chez le grossiste : le stock est mis à jour tout de suite',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ),
                              if (_alreadyReceived) ...[
                                const SizedBox(height: 6),
                                TextField(
                                  key: const Key('purchasePaid'),
                                  controller: _paid,
                                  keyboardType: TextInputType.number,
                                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                                  decoration: InputDecoration(
                                    labelText: 'Montant payé maintenant',
                                    suffixText: 'F',
                                    helperText: _total > 0 ? 'Laissez vide si vous payez plus tard' : null,
                                    suffixIcon: TextButton(
                                      onPressed: () => setState(() => _paid.text = '$_total'),
                                      child: const Text('Tout'),
                                    ),
                                  ),
                                  onChanged: (_) => setState(() {}),
                                ),
                                const SizedBox(height: 10),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    for (final m in [PayMethod.cash, ...ref.watch(countryProvider).mobileMoney])
                                      Pill(
                                        label: m.label,
                                        selected: _method == m,
                                        onTap: () => setState(() => _method = m),
                                      ),
                                  ],
                                ),
                              ] else ...[
                                Text('Livraison attendue', style: TextStyle(color: AppColors.muted, fontSize: 13)),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    for (final d in const [1, 3, 7, 14])
                                      Pill(
                                        label: d == 1 ? 'Demain' : 'Sous $d jours',
                                        selected: _deliveryDays == d,
                                        onTap: () => setState(() => _deliveryDays = d),
                                      ),
                                    Pill(
                                      label: 'Pas de date',
                                      selected: _deliveryDays == null,
                                      onTap: () => setState(() => _deliveryDays = null),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      _Section(
                        title: 'Note',
                        child: TextField(
                          key: const Key('purchaseNote'),
                          controller: _note,
                          minLines: 1,
                          maxLines: 3,
                          decoration: const InputDecoration(hintText: 'Ex. livrer à la boutique de Sandaga'),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(10, 4, 10, 8 + MediaQuery.paddingOf(context).bottom),
                  child: Glass(
                    radius: 28,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Total',
                                style: TextStyle(color: AppColors.muted, fontWeight: FontWeight.w600),
                              ),
                            ),
                            Text(money(_total), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                          ],
                        ),
                        const SizedBox(height: 10),
                        BusyButton(
                          label: _editing
                              ? 'Enregistrer les modifications'
                              : _alreadyReceived
                              ? 'Enregistrer l’achat'
                              : 'Passer la commande',
                          busy: _busy,
                          onPressed: () => _save(),
                          accent: true,
                        ),
                        if (!_editing && !_alreadyReceived)
                          TextButton(
                            onPressed: _busy ? null : () => _save(draft: true),
                            child: const Text('Enregistrer sans envoyer'),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Glass(
    radius: 22,
    padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
        ),
        const SizedBox(height: 10),
        child,
      ],
    ),
  );
}

class _LineTile extends StatelessWidget {
  const _LineTile({required this.line, required this.onTap, required this.onMinus, required this.onPlus});
  final PurchaseLineDraft line;
  final VoidCallback onTap;
  final VoidCallback onMinus;
  final VoidCallback onPlus;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(12),
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(line.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                Text(
                  '${qty(line.quantity)} × ${moneyShort(line.unitCost)} = ${moneyShort(line.total)}',
                  style: TextStyle(fontSize: 13, color: AppColors.muted),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: line.quantity <= 1 ? 'Retirer ${line.name}' : 'Une de moins',
            onPressed: onMinus,
            icon: line.quantity <= 1
                ? Icon(Icons.delete_rounded, color: AppColors.danger)
                : const Icon(Icons.remove_circle_outline_rounded),
          ),
          Text(qty(line.quantity), style: const TextStyle(fontWeight: FontWeight.w800)),
          IconButton(tooltip: 'Une de plus', onPressed: onPlus, icon: const Icon(Icons.add_circle_outline_rounded)),
        ],
      ),
    ),
  );
}

/// Quantité et prix d'achat d'une ligne.
class _LineSheet extends StatefulWidget {
  const _LineSheet({required this.line});
  final PurchaseLineDraft line;
  @override
  State<_LineSheet> createState() => _LineSheetState();
}

class _LineSheetState extends State<_LineSheet> {
  late final _qty = TextEditingController(text: qty(widget.line.quantity));
  late final _cost = TextEditingController(text: '${widget.line.unitCost}');
  String? _error;

  @override
  void dispose() {
    _qty.dispose();
    _cost.dispose();
    super.dispose();
  }

  void _ok() {
    final q = double.tryParse(_qty.text.replaceAll(',', '.').replaceAll(RegExp(r'\s'), ''));
    final c = int.tryParse(_cost.text.replaceAll(RegExp(r'\s'), ''));
    if (q == null || q <= 0 || c == null) {
      setState(() => _error = 'Quantité et prix d’achat sont nécessaires');
      return;
    }
    Navigator.pop(context, widget.line.copyWith(quantity: q, unitCost: c));
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(widget.line.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('plQty'),
                controller: _qty,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'Quantité',
                  suffixText: widget.line.unit == 'pièce' ? null : widget.line.unit,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: TextField(
                key: const Key('plCost'),
                controller: _cost,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(labelText: 'Prix d’achat unitaire', suffixText: 'F'),
              ),
            ),
          ],
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_error!, style: TextStyle(color: AppColors.danger)),
          ),
        const SizedBox(height: 16),
        FilledButton(onPressed: _ok, child: const Text('Valider')),
      ],
    ),
  );
}

/// Choix d'un produit du catalogue (articles suivis ou non).
class ProductPicker extends ConsumerStatefulWidget {
  const ProductPicker({super.key});
  @override
  ConsumerState<ProductPicker> createState() => ProductPickerState();
}

class ProductPickerState extends ConsumerState<ProductPicker> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final products = ref.watch(productsProvider);
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.75,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Rechercher un produit',
                prefixIcon: Icon(Icons.search),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: AsyncView<List<Product>>(
                value: products,
                onRetry: () => ref.invalidate(productsProvider),
                data: (list) {
                  final shown = list
                      .where((p) => !p.isService && (_q.isEmpty || p.name.toLowerCase().contains(_q)))
                      .toList();
                  return ListView.builder(
                    itemCount: shown.length,
                    itemBuilder: (_, i) {
                      final p = shown[i];
                      return ListTile(
                        leading: ProductThumb(name: p.name, fileId: p.imageFileId, size: 44),
                        title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text('Coût d’achat ${moneyShort(p.cost)}', style: const TextStyle(fontSize: 12)),
                        onTap: () => Navigator.pop(context, p),
                      );
                    },
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

/// Liste des fournisseurs avec recherche et création rapide.
class SupplierPicker extends ConsumerStatefulWidget {
  const SupplierPicker({super.key});
  @override
  ConsumerState<SupplierPicker> createState() => SupplierPickerState();
}

class SupplierPickerState extends ConsumerState<SupplierPicker> {
  String _q = '';

  Future<void> _create() async {
    final name = TextEditingController(text: _q);
    final phone = TextEditingController();
    final created = await showDialog<Contact>(
      context: context,
      builder: (ctx) {
        var busy = false;
        return StatefulBuilder(
          builder: (ctx, setState) => AlertDialog(
            title: const Text('Nouveau fournisseur'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  key: const Key('newSupplierName'),
                  controller: name,
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Nom'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: phone,
                  keyboardType: TextInputType.phone,
                  decoration: InputDecoration(
                    labelText: 'Téléphone (facultatif)',
                    prefixText: '+${ref.read(countryProvider).dial} ',
                  ),
                ),
              ],
            ),
            actions: dialogActions([
              CancelButton(onPressed: () => Navigator.pop(ctx)),
              FilledButton(
                onPressed: busy
                    ? null
                    : () async {
                        if (name.text.trim().isEmpty) return;
                        final p = phone.text.trim().isEmpty ? null : localPhone(phone.text, ref.read(countryProvider));
                        if (phone.text.trim().isNotEmpty && p == null) {
                          showInfo(ctx, invalidPhone(ref.read(countryProvider)));
                          return;
                        }
                        setState(() => busy = true);
                        try {
                          final c = await ref
                              .read(repoProvider)
                              .saveCustomer(
                                CustomerDraft(name: name.text.trim(), phone: p),
                                type: 'supplier',
                                withLimit: false,
                              );
                          refreshPurchasing(ref);
                          if (ctx.mounted) Navigator.pop(ctx, c);
                        } catch (e) {
                          setState(() => busy = false);
                          if (ctx.mounted) showError(ctx, e);
                        }
                      },
                child: const Text('Créer'),
              ),
            ]),
          ),
        );
      },
    );
    if (created != null && mounted) Navigator.pop(context, created);
  }

  @override
  Widget build(BuildContext context) {
    final list = ref.watch(suppliersProvider(_q));
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Choisir le fournisseur', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              ),
              TextButton.icon(
                onPressed: _create,
                icon: const Icon(Icons.add_business_rounded),
                label: const Text('Nouveau'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            decoration: const InputDecoration(
              hintText: 'Nom ou téléphone',
              prefixIcon: Icon(Icons.search),
              isDense: true,
            ),
            onChanged: (v) => setState(() => _q = v.trim()),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: AsyncView<List<SupplierRow>>(
              value: list,
              onRetry: () => ref.invalidate(suppliersProvider(_q)),
              data: (rows) => rows.isEmpty
                  ? Center(
                      child: Text(
                        'Aucun fournisseur : créez-le avec « Nouveau »',
                        style: TextStyle(color: AppColors.muted),
                      ),
                    )
                  : ListView.separated(
                      itemCount: rows.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final s = rows[i];
                        return ListTile(
                          leading: Avatar(
                            name: s.name,
                            size: 40,
                            bg: const Color(0xFFE6EFFC),
                            fg: const Color(0xFF1F5BB8),
                          ),
                          title: Text(s.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                          subtitle: s.phone == null ? null : Text(displayPhone(s.phone!)),
                          trailing: s.due > 0
                              ? Text(
                                  'dû ${moneyShort(s.due)}',
                                  style: TextStyle(color: AppColors.warn, fontWeight: FontWeight.w700),
                                )
                              : null,
                          onTap: () => Navigator.pop(context, s.toContact()),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
