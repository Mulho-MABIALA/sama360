import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../auth/auth_controller.dart' show authProvider;
import '../auth/pin_screen.dart' show confirmSensitive;
import '../../core/api/api_client.dart';
import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/trades.dart';
import '../../core/widgets.dart';
import 'variants_screen.dart' show variantTitleFor;
import 'barcode_scanner.dart';
import 'categories_screen.dart' show pickOrCreateCategory;
import 'product_photo.dart';

/// Fiche produit complète : création ([productId] null) ou modification.
class ProductEditorScreen extends ConsumerStatefulWidget {
  const ProductEditorScreen({super.key, this.productId, this.initialBarcode, this.initialService = false});
  final String? productId;

  /// Code scanné inconnu : la fiche s'ouvre avec ce code déjà rempli.
  final String? initialBarcode;

  /// Nouvelle fiche de type « Service » (prestation).
  final bool initialService;

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
  final _qty = TextEditingController(); // nouveau produit : quantité déjà en stock
  // Conditionnement : vendu ou acheté aussi au carton, au sac…
  bool _pack = false;
  String _packName = packNames.first;
  final _packSize = TextEditingController();
  final _packPrice = TextEditingController();
  // Selon le métier : suppléments (restaurant), péremption (alimentation), IMEI et garantie (téléphonie)
  final _extras = <ProductExtra>[];
  final _extraName = TextEditingController();
  final _extraPrice = TextEditingController();
  DateTime? _expires;
  bool _expiryChanged = false;
  bool _trackSerial = false;
  final _warranty = TextEditingController();
  bool _isService = false;

  /// « Plus d'options » ouvert : toujours en modification ; à la création, seulement si besoin.
  late bool _more = widget.productId != null || widget.initialBarcode != null || widget.initialService;
  int? _duration; // prestations : durée d'un rendez-vous
  String _unit = 'pièce';
  bool _trackStock = true;
  bool _published = true; // nouveau produit : visible dans la boutique en ligne
  bool _wholesale = false;
  Category? _category;

  /// Galerie : photos en ligne (fileId) ou choisies, pas encore envoyées (picked). La première est la principale.
  List<GalleryPhoto> _photos = [];
  List<String> _serverPhotos = const [];
  bool _loaded = false;
  bool _busy = false;

  /// Fiche chargée (modification) : variante ou modèle à variantes.
  Product? _product;
  final _errors = <String, String>{};

  bool get _editing => widget.productId != null;

  /// Le propriétaire et ceux qui voient les coûts : prix d'achat demandé (et obligatoire pour un article).
  bool get _seesCosts => seesCosts(ref.watch(currentBusinessProvider).value?.permissions ?? const []);

  /// Métier où l'unité compte autant que le prix (mètre de câble, sac de ciment, kilo de riz).
  bool get _unitFirst {
    final c = ref.watch(authProvider).value?.business?.category;
    return c == 'quincaillerie' || c == 'alimentation';
  }

  @override
  void initState() {
    super.initState();
    _barcode.text = widget.initialBarcode ?? '';
    _isService = widget.initialService;
    if (!_editing) {
      _loaded = true;
      return;
    }
    Future(() async {
      final p = await ref.read(productProvider(widget.productId!).future);
      final cats = await ref.read(categoriesProvider.future);
      if (!mounted) return;
      setState(() {
        _product = p;
        _name.text = p.name;
        _price.text = '${p.price}';
        _cost.text = p.cost == 0 ? '' : '${p.cost}';
        _barcode.text = p.barcode ?? '';
        _sku.text = p.sku ?? '';
        _threshold.text = '${p.lowStockThreshold}';
        _isService = p.isService;
        _duration = p.durationMinutes;
        _unit = p.unit;
        _trackStock = p.trackStock;
        _wholesale = p.hasWholesale;
        _published = p.published;
        _extras.addAll(p.extras);
        _expires = p.expiresOn;
        _trackSerial = p.trackSerial;
        _warranty.text = (p.warrantyMonths ?? 0) > 0 ? '${p.warrantyMonths}' : '';
        _pack = p.hasPack;
        if (p.hasPack) {
          _packName = p.packName!;
          _packSize.text = qty(p.packSize!);
          // Prix du carton : celui du prix de gros quand il démarre au carton
          if (p.hasWholesale && p.wholesaleMinQty == p.packSize) {
            _packPrice.text = '${(p.wholesalePrice! * p.packSize!).round()}';
          }
        }
        if (p.hasWholesale) {
          _wPrice.text = '${p.wholesalePrice}';
          _wQty.text = qty(p.wholesaleMinQty!);
        }
        _category = cats.where((c) => c.id == p.categoryId).firstOrNull;
        _serverPhotos = p.images.isEmpty && p.imageFileId != null ? [p.imageFileId!] : p.images;
        _photos = [for (final f in _serverPhotos) GalleryPhoto(fileId: f)];
        _loaded = true;
      });
    });
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _price,
      _cost,
      _barcode,
      _sku,
      _threshold,
      _wPrice,
      _wQty,
      _qty,
      _packSize,
      _packPrice,
      _extraName,
      _extraPrice,
      _warranty,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  int? _int(TextEditingController c) => int.tryParse(c.text.replaceAll(' ', ''));

  Future<void> _scan() async {
    final code = await ref.read(barcodeScannerProvider)(context);
    if (code != null) setState(() => _barcode.text = code);
  }

  Future<void> _save({bool thenVariants = false}) async {
    final price = _int(_price);
    final cost = _int(_cost) ?? 0;
    var wPrice = _int(_wPrice);
    var wQty = double.tryParse(_wQty.text.replaceAll(',', '.').replaceAll(' ', ''));
    final packSize = double.tryParse(_packSize.text.replaceAll(',', '.').replaceAll(' ', ''));
    final packPrice = _int(_packPrice);
    var wholesale = _wholesale;
    // Prix du carton : devient le prix de gros à partir d'un carton
    if (_pack && packSize != null && packSize > 1 && packPrice != null) {
      wholesale = true;
      wPrice = (packPrice / packSize).round();
      wQty = packSize;
    }
    setState(() {
      _errors.clear();
      if (_category == null && !(_product?.isVariant ?? false)) _errors['category'] = 'Choisissez une catégorie';
      if (_seesCosts && !_isService && (_int(_cost) ?? 0) <= 0) {
        _errors['cost'] = 'Indiquez le prix d’achat : il sert à calculer vos bénéfices';
      }
      if (_name.text.trim().isEmpty) _errors['name'] = 'Donnez un nom';
      if (price == null) _errors['price'] = 'Indiquez le prix de vente';
      if (_pack && !_isService && (packSize == null || packSize <= 1)) {
        _errors['packSize'] = 'Plus de 1';
      }
      if (_pack && packSize != null && packPrice != null && price != null && packPrice >= price * packSize) {
        _errors['packPrice'] = 'Moins cher que ${moneyShort((price * packSize).round())} (à la pièce)';
      }
      if (wholesale && !(_pack && packPrice != null)) {
        if (wPrice == null) _errors['wPrice'] = 'Prix de gros';
        if (wQty == null || wQty <= 0) _errors['wQty'] = 'Quantité minimale';
        if (wPrice != null && price != null && wPrice >= price) {
          _errors['wPrice'] = 'Doit être inférieur au prix normal';
        }
      }
    });
    if (_errors.isNotEmpty) {
      if (_errors.keys.any((k) => k.startsWith('w') || k.startsWith('pack'))) setState(() => _more = true);
      return;
    }
    final initialQty = _editing || _isService || !_trackStock
        ? 0.0
        : double.tryParse(_qty.text.replaceAll(',', '.').replaceAll(' ', '')) ?? 0;

    final draft = ProductDraft(
      name: _name.text,
      price: price!,
      cost: cost,
      categoryId: _category?.id,
      isService: _isService,
      durationMinutes: _duration,
      unit: _unit,
      barcode: _barcode.text,
      sku: _sku.text,
      trackStock: _trackStock,
      published: _published,
      lowStockThreshold: _int(_threshold) ?? 5,
      wholesalePrice: wholesale ? wPrice : null,
      wholesaleMinQty: wholesale ? wQty : null,
      packName: _pack ? _packName : null,
      packSize: _pack ? packSize : null,
      extras: List.of(_extras),
      expiresOn: _expires,
      clearExpiry: _expiryChanged && _expires == null,
      warrantyMonths: _int(_warranty) ?? 0,
      trackSerial: _trackSerial,
    );
    setState(() => _busy = true);
    final repo = ref.read(repoProvider);
    try {
      final saved = await repo.saveProduct(draft, id: widget.productId);
      if (initialQty > 0 && !thenVariants) {
        try {
          await repo.addStock(saved.id, initialQty, unitCost: cost > 0 ? cost : null);
        } catch (_) {
          if (mounted) showInfo(context, 'Produit ajouté, mais le stock n’a pas pu être enregistré');
        }
      }
      try {
        await syncGallery(repo, saved.id, server: _serverPhotos, wanted: _photos);
      } catch (_) {
        if (mounted) showInfo(context, 'Produit enregistré, mais les photos n’ont pas toutes été envoyées');
      }
      refreshBusinessData(ref);
      ref.invalidate(categoriesProvider);
      if (_editing) ref.invalidate(productProvider(widget.productId!));
      if (!mounted) return;
      if (thenVariants) {
        // Nouveau produit : on enchaîne sur ses tailles, couleurs…
        context.pushReplacement('/products/${saved.id}/variants');
        return;
      }
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

  void _addExtra() {
    final name = _extraName.text.trim();
    if (name.isEmpty) return;
    setState(() {
      _extras.removeWhere((e) => e.name.toLowerCase() == name.toLowerCase());
      _extras.add(ProductExtra(name, _int(_extraPrice) ?? 0));
      _extraName.clear();
      _extraPrice.clear();
    });
  }

  /// Catégories du commerce en pastilles, « + Nouvelle » pour en créer une sans quitter la fiche.
  Widget _categoryPicker() {
    final cats = ref.watch(categoriesProvider).value ?? const <Category>[];
    final error = _errors['category'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Text(
          'Catégorie *',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5, color: error != null ? AppColors.danger : null),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final c in cats)
              Pill(
                key: Key('pCat_${c.id}'),
                label: c.name,
                selected: _category?.id == c.id,
                onTap: () => setState(() {
                  _category = c;
                  _errors.remove('category');
                }),
              ),
            Pill(
              key: const Key('pCat_new'),
              label: 'Nouvelle',
              icon: Icons.add_rounded,
              selected: false,
              onTap: () async {
                final c = await pickOrCreateCategory(context, ref, selected: _category);
                if (c != null && c.id.isNotEmpty) {
                  setState(() {
                    _category = c;
                    _errors.remove('category');
                  });
                }
              },
            ),
          ],
        ),
        if (error != null) ...[
          const SizedBox(height: 6),
          Text(
            error,
            key: const Key('pCat_error'),
            style: TextStyle(color: AppColors.danger, fontWeight: FontWeight.w600, fontSize: 12.5),
          ),
        ],
      ],
    );
  }

  /// Suppléments, péremption, IMEI et garantie : utiles selon le métier.
  Widget _tradeFields(List<TextInputFormatter> digits) {
    final business = ref.watch(currentBusinessProvider).value;
    final cat = business != null ? business.category : ref.watch(authProvider).value?.business?.category;
    // Champs du métier ; un champ déjà rempli reste visible (produit repris d'un autre métier)
    final extras = tradeShows(cat, TradeField.extras) || _extras.isNotEmpty;
    final expiry = tradeShows(cat, TradeField.expiry) || _expires != null;
    final serial = tradeShows(cat, TradeField.serial) || _trackSerial || _warranty.text.isNotEmpty;
    if (!extras && !expiry && !serial) return const SizedBox.shrink();
    final heading = TextStyle(fontWeight: FontWeight.w800, color: AppColors.ink);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (extras) ...[
          const SizedBox(height: 12),
          Text(cat == 'restaurant' ? 'Suppléments et options' : 'Suppléments et options (restaurant…)', style: heading),
          const SizedBox(height: 6),
          if (_extras.isNotEmpty)
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final e in _extras)
                  InputChip(
                    label: Text('${e.name} · ${e.price == 0 ? 'offert' : '+${moneyShort(e.price)}'}'),
                    onDeleted: () => setState(() => _extras.remove(e)),
                  ),
              ],
            ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  key: const Key('pExtraName'),
                  controller: _extraName,
                  textCapitalization: TextCapitalization.sentences,
                  onSubmitted: (_) => _addExtra(),
                  decoration: const InputDecoration(labelText: 'Ex. Œuf, Sauce, Grande portion', isDense: true),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: TextField(
                  key: const Key('pExtraPrice'),
                  controller: _extraPrice,
                  keyboardType: TextInputType.number,
                  inputFormatters: digits,
                  decoration: const InputDecoration(labelText: '+ Prix', suffixText: 'F', isDense: true),
                ),
              ),
              IconButton(
                key: const Key('pExtraAdd'),
                tooltip: 'Ajouter le supplément',
                onPressed: _addExtra,
                icon: Icon(Icons.add_circle_rounded, color: AppColors.green),
              ),
            ],
          ),
        ],
        if (expiry) ...[
          const SizedBox(height: 14),
          InkWell(
            key: const Key('pExpiry'),
            borderRadius: BorderRadius.circular(14),
            onTap: () async {
              final now = DateTime.now();
              final d = await showDatePicker(
                context: context,
                initialDate: _expires ?? now.add(const Duration(days: 30)),
                firstDate: now.subtract(const Duration(days: 365)),
                lastDate: now.add(const Duration(days: 365 * 10)),
                helpText: 'Date de péremption',
              );
              if (d != null) {
                setState(() {
                  _expires = d;
                  _expiryChanged = true;
                });
              }
            },
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: 'Date de péremption (alimentation…)',
                prefixIcon: const Icon(Icons.event_busy_rounded),
                suffixIcon: _expires == null
                    ? null
                    : IconButton(
                        tooltip: 'Retirer la date',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => setState(() {
                          _expires = null;
                          _expiryChanged = true;
                        }),
                      ),
              ),
              child: Text(_expires == null ? 'Aucune' : longDate(_expires!)),
            ),
          ),
        ],
        if (serial) ...[
          const SizedBox(height: 6),
          SwitchListTile(
            key: const Key('pSerial'),
            contentPadding: EdgeInsets.zero,
            value: _trackSerial,
            onChanged: (v) => setState(() => _trackSerial = v),
            title: const Text('IMEI / numéro de série à la vente', style: TextStyle(fontWeight: FontWeight.w700)),
            subtitle: const Text('Téléphones, appareils : le numéro est noté sur le reçu'),
          ),
          TextField(
            key: const Key('pWarranty'),
            controller: _warranty,
            keyboardType: TextInputType.number,
            inputFormatters: digits,
            decoration: const InputDecoration(
              labelText: 'Garantie (facultatif)',
              suffixText: 'mois',
              prefixIcon: Icon(Icons.verified_user_rounded),
            ),
          ),
        ],
      ],
    );
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
        actions: dialogActions([
          CancelButton(onPressed: () => Navigator.pop(ctx, false)),
          ConfirmButton(danger: true, label: 'Supprimer', onPressed: () => Navigator.pop(ctx, true)),
        ]),
      ),
    );
    if (ok != true || !mounted) return;
    if (!await confirmSensitive(context, ref, action: 'Supprimer le produit')) return;
    if (!mounted) return;
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
              key: const Key('product_status'),
              tooltip: 'Statut WhatsApp',
              onPressed: () => context.push('/status?ids=${widget.productId}'),
              icon: const Icon(Icons.auto_awesome_rounded),
            ),
          if (_editing) TrashButton(tooltip: 'Supprimer le produit', onPressed: _busy ? null : _delete),
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
                        title: _editing ? 'Produit' : 'L’essentiel',
                        children: [
                          PhotoGallery(
                            name: _name.text,
                            photos: _photos,
                            onChanged: (list) => setState(() => _photos = list),
                          ),
                          const SizedBox(height: 12),
                          if (_product?.isVariant ?? false)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: OutlinedButton.icon(
                                key: const Key('open_parent'),
                                onPressed: () => context.push('/products/${_product!.parentId}/variants'),
                                icon: const Icon(Icons.style_rounded),
                                label: Text('Variante « ${_product!.variantLabel} » : voir toutes les variantes'),
                              ),
                            ),
                          TextField(
                            key: const Key('pName'),
                            controller: _name,
                            // Le nom d'une variante suit celui de son modèle
                            enabled: !(_product?.isVariant ?? false),
                            textCapitalization: TextCapitalization.sentences,
                            decoration: InputDecoration(labelText: 'Nom', errorText: _errors['name']),
                          ),
                          const SizedBox(height: 10),
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
                              if (!_editing && !_isService && _trackStock) ...[
                                const SizedBox(width: 10),
                                Expanded(
                                  child: TextField(
                                    key: const Key('pQty'),
                                    controller: _qty,
                                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                    decoration: InputDecoration(
                                      labelText: 'Quantité',
                                      suffixText: _unit,
                                      hintText: '0',
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          // Prix d'achat : obligatoire pour un article (sans lui, pas de bénéfice juste)
                          if (_seesCosts) ...[
                            const SizedBox(height: 10),
                            TextField(
                              key: const Key('pCost'),
                              controller: _cost,
                              keyboardType: TextInputType.number,
                              inputFormatters: digits,
                              onChanged: (_) => setState(() => _errors.remove('cost')),
                              decoration: InputDecoration(
                                labelText: _isService ? 'Coût (facultatif)' : 'Prix d’achat *',
                                suffixText: 'F',
                                prefixIcon: const Icon(Icons.shopping_cart_checkout_rounded),
                                helperText: price > 0 && cost > 0
                                    ? null
                                    : 'Ce que l’article vous coûte : Sama360 calcule vos bénéfices avec',
                                helperMaxLines: 2,
                                errorText: _errors['cost'],
                              ),
                            ),
                            if (price > 0 && cost > 0)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(
                                  margin >= 0
                                      ? 'Bénéfice : ${moneyShort(margin)} par ${_unit == 'pièce' ? 'pièce' : _unit} (${(margin * 100 / price).round()} %)'
                                      : 'Attention : vendu à perte (${moneyShort(-margin)})',
                                  key: const Key('pMargin'),
                                  style: TextStyle(
                                    color: margin >= 0 ? AppColors.green : AppColors.danger,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                          ],
                          // Catégorie obligatoire, à portée de main (boutique en ligne et caisse rangées)
                          if (!(_product?.isVariant ?? false)) _categoryPicker(),
                          // Quincaillerie, alimentation : on choisit tout de suite au mètre, au kilo, au sac…
                          if (!_isService && _unitFirst) ...[
                            const SizedBox(height: 10),
                            Text('Vendu', style: TextStyle(color: AppColors.muted, fontSize: 12.5)),
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                for (final u in const ['pièce', 'mètre', 'kg', 'litre', 'sac', 'carton', 'rouleau'])
                                  Pill(
                                    key: Key('pUnit_$u'),
                                    label: u == 'pièce'
                                        ? 'à la pièce'
                                        : u == 'kg'
                                        ? 'au kilo'
                                        : 'au $u',
                                    selected: _unit == u,
                                    onTap: () => setState(() => _unit = u),
                                  ),
                              ],
                            ),
                          ],
                        ],
                      ),
                      if (!_isService && !(_product?.isVariant ?? false)) ...[
                        const SizedBox(height: 12),
                        _VariantsCard(
                          product: _product,
                          onTap: _editing
                              ? () async {
                                  await context.push('/products/${widget.productId}/variants');
                                  if (!mounted) return;
                                  final p = await ref.refresh(productProvider(widget.productId!).future);
                                  if (mounted) setState(() => _product = p);
                                }
                              : () => _save(thenVariants: true),
                        ),
                      ],
                      const SizedBox(height: 12),
                      // Le reste est replié à la création : un débutant n'a besoin que du nom et du prix.
                      Glass(
                        radius: 22,
                        padding: EdgeInsets.zero,
                        child: InkWell(
                          key: const Key('pMore'),
                          borderRadius: BorderRadius.circular(22),
                          onTap: () => setState(() => _more = !_more),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
                            child: Row(
                              children: [
                                Icon(Icons.tune_rounded, color: AppColors.green),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        'Plus d’options',
                                        style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                                      ),
                                      Text(
                                        'Prix d’achat, unité, carton, prix de gros, catégorie, code-barres, '
                                        'suppléments, péremption, IMEI…',
                                        style: TextStyle(color: AppColors.muted, fontSize: 12.5),
                                      ),
                                    ],
                                  ),
                                ),
                                AnimatedRotation(
                                  turns: _more ? 0.5 : 0,
                                  duration: const Duration(milliseconds: 200),
                                  child: Icon(Icons.expand_more_rounded, color: AppColors.muted),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (_more) ...[
                        const SizedBox(height: 12),
                        _Section(
                          title: 'Vente et unité',
                          children: [
                            InputDecorator(
                              decoration: const InputDecoration(labelText: 'Vendu par'),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  isDense: true,
                                  isExpanded: true,
                                  value: productUnits.contains(_unit) ? _unit : 'pièce',
                                  items: [for (final u in productUnits) colorItem(u)],
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
                            if (!_isService) ...[
                              SwitchListTile(
                                key: const Key('pPack'),
                                contentPadding: EdgeInsets.zero,
                                value: _pack,
                                onChanged: (v) => setState(() => _pack = v),
                                title: const Text(
                                  'Vendu aussi au carton, au sac…',
                                  style: TextStyle(fontWeight: FontWeight.w700),
                                ),
                                subtitle: const Text(
                                  'Le stock reste compté à l’unité ; la caisse propose « 1 carton »',
                                ),
                              ),
                              if (_pack) ...[
                                Row(
                                  children: [
                                    Expanded(
                                      child: InputDecorator(
                                        decoration: const InputDecoration(labelText: 'Conditionnement'),
                                        child: DropdownButtonHideUnderline(
                                          child: DropdownButton<String>(
                                            key: const Key('pPackName'),
                                            isDense: true,
                                            isExpanded: true,
                                            value: packNames.contains(_packName) ? _packName : packNames.first,
                                            items: [for (final n in packNames) colorItem(n)],
                                            onChanged: (n) => setState(() => _packName = n ?? packNames.first),
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: TextField(
                                        key: const Key('pPackSize'),
                                        controller: _packSize,
                                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                        onChanged: (_) => setState(() {}),
                                        decoration: InputDecoration(
                                          labelText: 'Contient',
                                          suffixText: _unit,
                                          errorText: _errors['packSize'],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                TextField(
                                  key: const Key('pPackPrice'),
                                  controller: _packPrice,
                                  keyboardType: TextInputType.number,
                                  inputFormatters: digits,
                                  onChanged: (_) => setState(() {}),
                                  decoration: InputDecoration(
                                    labelText: 'Prix du ${_packName.toLowerCase()} (facultatif)',
                                    suffixText: 'F',
                                    errorText: _errors['packPrice'],
                                    errorMaxLines: 2,
                                    helperText: () {
                                      final size = double.tryParse(_packSize.text.replaceAll(',', '.'));
                                      final unitPrice = _int(_price);
                                      if (size == null || size <= 1 || unitPrice == null) return null;
                                      final pp = _int(_packPrice);
                                      return pp == null
                                          ? 'Sinon : ${qty(size)} × ${moneyShort(unitPrice)} = ${moneyShort((unitPrice * size).round())}'
                                          : 'Soit ${moneyShort((pp / size).round())} ${_unit == 'pièce' ? 'la pièce' : 'le $_unit'}';
                                    }(),
                                  ),
                                ),
                              ],
                            ],
                          ],
                        ),
                        const SizedBox(height: 12),
                        _Section(
                          title: 'Rangement',
                          children: [
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
                            if (_isService) ...[
                              const SizedBox(height: 12),
                              Text(
                                'Durée d’un rendez-vous',
                                style: TextStyle(color: AppColors.muted, fontWeight: FontWeight.w700, fontSize: 13),
                              ),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  for (final m in const [15, 30, 45, 60, 90, 120, 180])
                                    Pill(
                                      key: Key('pDuration$m'),
                                      label: m < 60 ? '$m min' : '${m ~/ 60} h${m % 60 == 0 ? '' : ' ${m % 60}'}',
                                      selected: (_duration ?? 30) == m,
                                      onTap: () => setState(() => _duration = m),
                                    ),
                                ],
                              ),
                            ],
                            if (!_isService) _tradeFields(digits),
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

/// « Tailles, couleurs… » : ouvre les variantes du produit (à la création, enregistre d'abord).
class _VariantsCard extends ConsumerWidget {
  const _VariantsCard({required this.product, required this.onTap});
  final Product? product;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final axes = product?.variantAxes ?? const <VariantAxis>[];
    final count = axes.fold(1, (n, a) => n * a.values.length);
    return Glass(
      radius: 22,
      padding: EdgeInsets.zero,
      child: InkWell(
        key: const Key('pVariants'),
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.softOf(const Color(0xFFF3E8FF), const Color(0xFF7C3AED)),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.style_rounded, color: Color(0xFF7C3AED)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      axes.isEmpty
                          ? variantTitleFor(ref.watch(currentBusinessProvider).value?.category)
                          : 'Variantes · $count',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    Text(
                      axes.isEmpty
                          ? 'Le même article en plusieurs versions, chacune avec son stock'
                          : axes.map((a) => '${a.name} : ${a.values.join(', ')}').join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: AppColors.muted, fontSize: 12.5),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: AppColors.muted),
            ],
          ),
        ),
      ),
    );
  }
}
