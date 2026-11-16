import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/api_client.dart';
import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import 'barcode_scanner.dart';
import 'categories_screen.dart' show pickOrCreateCategory;
import 'product_photo.dart';

/// Fiche produit complète : création ([productId] null) ou modification.
class ProductEditorScreen extends ConsumerStatefulWidget {
  const ProductEditorScreen({super.key, this.productId, this.initialBarcode});
  final String? productId;

  /// Code scanné inconnu : la fiche s'ouvre avec ce code déjà rempli.
  final String? initialBarcode;

  @override
  ConsumerState<ProductEditorScreen> createState() => _ProductEditorScreenState();
}

class _ProductEditorScreenState extends ConsumerState<ProductEditorScreen> {
  final _name = TextEditingController();
  final _price = TextEditingController();
  final _cost = TextEditingController();
  final _barcode = TextEditingController();
  final _sku = TextEditingController();
  final _threshold = TextEditingController(text: '5');
  final _wPrice = TextEditingController();
  final _wQty = TextEditingController();
  bool _isService = false;
  String _unit = 'pièce';
  bool _trackStock = true;
  bool _published = true; // nouveau produit : visible dans la boutique en ligne
  bool _wholesale = false;
  Category? _category;
  PickedPhoto? _photo;
  String? _imageFileId;
  bool _loaded = false;
  bool _busy = false;
  final _errors = <String, String>{};

  bool get _editing => widget.productId != null;

  @override
  void initState() {
    super.initState();
    _barcode.text = widget.initialBarcode ?? '';
    if (!_editing) {
      _loaded = true;
      return;
    }
    Future(() async {
      final p = await ref.read(productProvider(widget.productId!).future);
      final cats = await ref.read(categoriesProvider.future);
      if (!mounted) return;
      setState(() {
        _name.text = p.name;
        _price.text = '${p.price}';
        _cost.text = p.cost == 0 ? '' : '${p.cost}';
        _barcode.text = p.barcode ?? '';
        _sku.text = p.sku ?? '';
        _threshold.text = '${p.lowStockThreshold}';
        _isService = p.isService;
        _unit = p.unit;
        _trackStock = p.trackStock;
        _wholesale = p.hasWholesale;
        _published = p.published;
        if (p.hasWholesale) {
          _wPrice.text = '${p.wholesalePrice}';
          _wQty.text = qty(p.wholesaleMinQty!);
        }
        _category = cats.where((c) => c.id == p.categoryId).firstOrNull;
        _imageFileId = p.imageFileId;
        _loaded = true;
      });
    });
  }

  @override
  void dispose() {
    for (final c in [_name, _price, _cost, _barcode, _sku, _threshold, _wPrice, _wQty]) {
      c.dispose();
    }
    super.dispose();
  }

  int? _int(TextEditingController c) => int.tryParse(c.text.replaceAll(' ', ''));

  Future<void> _scan() async {
    final code = await ref.read(barcodeScannerProvider)(context);
    if (code != null) setState(() => _barcode.text = code);
  }

  Future<void> _save() async {
    final price = _int(_price);
    final cost = _int(_cost) ?? 0;
    final wPrice = _int(_wPrice);
    final wQty = double.tryParse(_wQty.text.replaceAll(',', '.').replaceAll(' ', ''));
    setState(() {
      _errors.clear();
      if (_name.text.trim().isEmpty) _errors['name'] = 'Donnez un nom';
      if (price == null) _errors['price'] = 'Indiquez le prix de vente';
      if (_wholesale) {
        if (wPrice == null) _errors['wPrice'] = 'Prix de gros';
        if (wQty == null || wQty <= 0) _errors['wQty'] = 'Quantité minimale';
        if (wPrice != null && price != null && wPrice >= price) {
          _errors['wPrice'] = 'Doit être inférieur au prix normal';
        }
      }
    });
    if (_errors.isNotEmpty) return;

    final draft = ProductDraft(
      name: _name.text,
      price: price!,
      cost: cost,
      categoryId: _category?.id,
      isService: _isService,
      unit: _unit,
      barcode: _barcode.text,
      sku: _sku.text,
      trackStock: _trackStock,
      published: _published,
      lowStockThreshold: _int(_threshold) ?? 5,
      wholesalePrice: _wholesale ? wPrice : null,
      wholesaleMinQty: _wholesale ? wQty : null,
    );
    setState(() => _busy = true);
    final repo = ref.read(repoProvider);
    try {
      final saved = await repo.saveProduct(draft, id: widget.productId);
      if (_photo != null) {
        try {
          await repo.uploadProductImage(saved.id, _photo!.bytes, filename: _photo!.filename);
        } catch (_) {
          if (mounted) showInfo(context, 'Produit enregistré, mais la photo n’a pas pu être envoyée');
        }
      }
      refreshBusinessData(ref);
      ref.invalidate(categoriesProvider);
      if (_editing) ref.invalidate(productProvider(widget.productId!));
      if (!mounted) return;
      showInfo(context, _editing ? 'Fiche enregistrée' : 'Produit ajouté');
      _leave(saved);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      if (e.code == 'CONFLICT') {
        setState(() => _errors[e.message.startsWith('Ce code-barres') ? 'barcode' : 'sku'] = e.message);
      } else {
        showError(context, e);
      }
    }
  }

  /// Retour à l'écran précédent (ou au stock si la fiche a été ouverte directement).
  void _leave(Product? result) => context.canPop() ? context.pop(result) : context.go('/stock');

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Supprimer « ${_name.text} » ?'),
        content: const Text(
          'Il disparaît du catalogue et de la caisse. Les ventes et factures passées gardent son nom et son prix.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await ref.read(repoProvider).deleteProduct(widget.productId!);
      refreshBusinessData(ref);
      ref.invalidate(categoriesProvider);
      if (!mounted) return;
      showInfo(context, 'Produit supprimé');
      _leave(null);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final price = _int(_price) ?? 0;
    final cost = _int(_cost) ?? 0;
    final margin = price - cost;
    final digits = [FilteringTextInputFormatter.digitsOnly];
    return AuroraScaffold(
      appBar: AppBar(
        title: Text(
          _editing ? 'Fiche produit' : 'Nouveau produit',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          if (_editing)
            IconButton(
              tooltip: 'Supprimer le produit',
              onPressed: _busy ? null : _delete,
              icon: const Icon(Icons.delete_outline_rounded),
            ),
        ],
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
                        title: 'Produit',
                        children: [
                          if (_photo == null && _imageFileId != null)
                            Row(
                              children: [
                                ProductThumb(name: _name.text, fileId: _imageFileId, size: 64),
                                const SizedBox(width: 12),
                                TextButton.icon(
                                  onPressed: () async {
                                    final p = await choosePhoto(context, ref);
                                    if (p != null) setState(() => _photo = p);
                                  },
                                  icon: const Icon(Icons.photo_camera_rounded),
                                  label: const Text('Changer la photo'),
                                ),
                              ],
                            )
                          else
                            PhotoField(photo: _photo, onChanged: (p) => setState(() => _photo = p)),
                          const SizedBox(height: 12),
                          TextField(
                            key: const Key('pName'),
                            controller: _name,
                            textCapitalization: TextCapitalization.sentences,
                            decoration: InputDecoration(labelText: 'Nom', errorText: _errors['name']),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              for (final (service, label) in [(false, 'Article'), (true, 'Service')])
                                Expanded(
                                  child: Padding(
                                    padding: EdgeInsets.only(right: service ? 0 : 8),
                                    child: Pill(
                                      label: label,
                                      selected: _isService == service,
                                      onTap: () => setState(() => _isService = service),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          InkWell(
                            borderRadius: BorderRadius.circular(14),
                            onTap: () async {
                              final c = await pickOrCreateCategory(context, ref, selected: _category);
                              if (c != null) setState(() => _category = c.id.isEmpty ? null : c);
                            },
                            child: InputDecorator(
                              decoration: const InputDecoration(
                                labelText: 'Catégorie',
                                suffixIcon: Icon(Icons.expand_more),
                              ),
                              child: Text(_category?.name ?? 'Sans catégorie'),
                            ),
                          ),
                          SwitchListTile(
                            key: const Key('pPublished'),
                            contentPadding: EdgeInsets.zero,
                            value: _published,
                            onChanged: (v) => setState(() => _published = v),
                            title: const Text(
                              'Visible dans la boutique en ligne',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _Section(
                        title: 'Prix',
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  key: const Key('pPrice'),
                                  controller: _price,
                                  keyboardType: TextInputType.number,
                                  inputFormatters: digits,
                                  onChanged: (_) => setState(() {}),
                                  decoration: InputDecoration(
                                    labelText: 'Prix de vente',
                                    suffixText: 'F',
                                    errorText: _errors['price'],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: TextField(
                                  key: const Key('pCost'),
                                  controller: _cost,
                                  keyboardType: TextInputType.number,
                                  inputFormatters: digits,
                                  onChanged: (_) => setState(() {}),
                                  decoration: const InputDecoration(labelText: 'Prix d’achat', suffixText: 'F'),
                                ),
                              ),
                            ],
                          ),
                          if (price > 0 && cost > 0)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                margin >= 0
                                    ? 'Bénéfice : ${moneyShort(margin)} par ${_unit == 'pièce' ? 'pièce' : _unit} (${(margin * 100 / price).round()} %)'
                                    : 'Attention : vendu à perte (${moneyShort(-margin)})',
                                style: TextStyle(
                                  color: margin >= 0 ? AppColors.greenDark : AppColors.danger,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          const SizedBox(height: 10),
                          InputDecorator(
                            decoration: const InputDecoration(labelText: 'Vendu par'),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                isDense: true,
                                isExpanded: true,
                                value: productUnits.contains(_unit) ? _unit : 'pièce',
                                items: [for (final u in productUnits) DropdownMenuItem(value: u, child: Text(u))],
                                onChanged: (u) => setState(() => _unit = u ?? 'pièce'),
                              ),
                            ),
                          ),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            value: _wholesale,
                            onChanged: (v) => setState(() => _wholesale = v),
                            title: const Text('Prix de gros', style: TextStyle(fontWeight: FontWeight.w700)),
                            subtitle: const Text('Un prix plus bas à partir d’une certaine quantité'),
                          ),
                          if (_wholesale)
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    key: const Key('pWPrice'),
                                    controller: _wPrice,
                                    keyboardType: TextInputType.number,
                                    inputFormatters: digits,
                                    decoration: InputDecoration(
                                      labelText: 'Prix de gros',
                                      suffixText: 'F',
                                      errorText: _errors['wPrice'],
                                      errorMaxLines: 2,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: TextField(
                                    key: const Key('pWQty'),
                                    controller: _wQty,
                                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                    decoration: InputDecoration(
                                      labelText: 'À partir de',
                                      suffixText: _unit,
                                      errorText: _errors['wQty'],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _Section(
                        title: 'Codes',
                        children: [
                          TextField(
                            key: const Key('pBarcode'),
                            controller: _barcode,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: 'Code-barres',
                              errorText: _errors['barcode'],
                              errorMaxLines: 2,
                              suffixIcon: IconButton(
                                tooltip: 'Scanner le code-barres',
                                onPressed: _scan,
                                icon: const Icon(Icons.qr_code_scanner_rounded),
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            key: const Key('pSku'),
                            controller: _sku,
                            textCapitalization: TextCapitalization.characters,
                            decoration: InputDecoration(
                              labelText: 'Référence interne (facultatif)',
                              hintText: 'Ex. RIZ-5',
                              errorText: _errors['sku'],
                              errorMaxLines: 2,
                            ),
                          ),
                        ],
                      ),
                      if (!_isService) ...[
                        const SizedBox(height: 12),
                        _Section(
                          title: 'Stock',
                          children: [
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              value: _trackStock,
                              onChanged: (v) => setState(() => _trackStock = v),
                              title: const Text('Suivre le stock', style: TextStyle(fontWeight: FontWeight.w700)),
                              subtitle: const Text('Les ventes diminuent la quantité en stock'),
                            ),
                            if (_trackStock)
                              TextField(
                                key: const Key('pThreshold'),
                                controller: _threshold,
                                keyboardType: TextInputType.number,
                                inputFormatters: digits,
                                decoration: InputDecoration(
                                  labelText: 'Me prévenir quand il reste',
                                  suffixText: _unit,
                                  helperText: 'Alerte « stock bas » sur l’accueil',
                                ),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(10, 4, 10, 8 + MediaQuery.paddingOf(context).bottom),
                  child: Glass(
                    radius: 28,
                    padding: const EdgeInsets.all(14),
                    child: BusyButton(
                      label: _editing ? 'Enregistrer la fiche' : 'Ajouter le produit',
                      busy: _busy,
                      onPressed: _save,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;

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
        ...children,
      ],
    ),
  );
}
