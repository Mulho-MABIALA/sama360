import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/api_client.dart' show ApiException;
import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// Listes toutes prêtes, selon ce que vend le commerçant.
const variantPresets = <(String, String, List<String>)>[
  ('Taille', 'Tailles S à XXL', ['S', 'M', 'L', 'XL', 'XXL']),
  ('Pointure', 'Pointures 36 à 45', ['36', '37', '38', '39', '40', '41', '42', '43', '44', '45']),
  ('Couleur', 'Couleurs courantes', ['Noir', 'Blanc', 'Rouge', 'Bleu', 'Vert']),
  ('Contenance', 'Contenances', ['50 ml', '100 ml', '250 ml', '500 ml', '1 L']),
  ('Taille enfant', 'Tailles enfant', ['2 ans', '4 ans', '6 ans', '8 ans', '10 ans', '12 ans']),
];

const _axisSuggestions = ['Taille', 'Couleur', 'Pointure', 'Contenance', 'Modèle', 'Longueur', 'Diamètre'];

class _Axis {
  _Axis(String name, [List<String>? values]) : name = TextEditingController(text: name), values = [...?values];
  final TextEditingController name;
  final List<String> values;
  final input = TextEditingController();

  void dispose() {
    name.dispose();
    input.dispose();
  }
}

class _Row {
  _Row(this.options, {required int price, this.existing, String? barcode})
    : price = TextEditingController(text: '$price'),
      barcode = TextEditingController(text: barcode ?? '');
  final Map<String, String> options;
  final Product? existing;
  final TextEditingController price;
  final TextEditingController barcode;
  final qty = TextEditingController();
  bool included = true;

  void dispose() {
    price.dispose();
    barcode.dispose();
    qty.dispose();
  }
}

/// Variantes d'un produit : ses options (taille, couleur…) puis chaque combinaison
/// avec son prix, son code-barres et son stock de départ.
class VariantsScreen extends ConsumerStatefulWidget {
  const VariantsScreen({super.key, required this.productId});
  final String productId;

  @override
  ConsumerState<VariantsScreen> createState() => _VariantsScreenState();
}

class _VariantsScreenState extends ConsumerState<VariantsScreen> {
  Product? _product;
  List<Product> _existing = const [];
  Map<String, double> _onHand = const {};
  final _axes = <_Axis>[];
  final _rows = <String, _Row>{};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    Future(() async {
      try {
        final p = await ref.read(productProvider(widget.productId).future);
        final all = await ref.read(productsProvider.future);
        Map<String, double> onHand = const {};
        if (ref.read(canProvider('inventory:read'))) {
          try {
            final s = await ref.read(stockProvider.future);
            onHand = {for (final i in s.items) i.productId: i.onHand};
          } catch (_) {}
        }
        if (!mounted) return;
        setState(() {
          _product = p;
          _existing = variantsOf(p, all);
          _onHand = onHand;
          if (p.hasVariants) {
            _axes.addAll([for (final a in p.variantAxes) _Axis(a.name, a.values)]);
          } else {
            _axes.add(_Axis(p.isService ? 'Durée' : 'Taille'));
          }
          _sync();
        });
      } catch (e) {
        if (mounted) showError(context, e);
      }
    });
  }

  @override
  void dispose() {
    for (final a in _axes) {
      a.dispose();
    }
    for (final r in _rows.values) {
      r.dispose();
    }
    super.dispose();
  }

  List<_Axis> get _ready => _axes.where((a) => a.name.text.trim().isNotEmpty && a.values.isNotEmpty).toList();

  String _key(Map<String, String> o) => _ready.map((a) => (o[a.name.text.trim()] ?? '').toLowerCase()).join('|');

  /// Recalcule les combinaisons en gardant ce qui a déjà été saisi.
  void _sync() {
    final axes = _ready;
    var combos = <Map<String, String>>[{}];
    for (final a in axes) {
      combos = [
        for (final c in combos)
          for (final v in a.values) {...c, a.name.text.trim(): v},
      ];
    }
    if (axes.isEmpty) combos = [];
    final old = Map.of(_rows);
    _rows.clear();
    for (final c in combos) {
      final k = _key(c);
      final kept = old.remove(k);
      if (kept != null) {
        _rows[k] = kept;
        continue;
      }
      final ex = _existing.where((v) => _key(v.options) == k).firstOrNull;
      _rows[k] = _Row(c, price: ex?.price ?? _product!.price, existing: ex, barcode: ex?.barcode);
    }
    for (final r in old.values) {
      r.dispose();
    }
  }

  void _addValues(_Axis a, String text) {
    final parts = text.split(RegExp(r'[,;\n]')).map((s) => s.trim()).where((s) => s.isNotEmpty);
    setState(() {
      for (final v in parts) {
        if (!a.values.any((x) => x.toLowerCase() == v.toLowerCase())) a.values.add(v);
      }
      a.input.clear();
      _sync();
    });
  }

  void _preset((String, String, List<String>) p) => setState(() {
    final (name, _, values) = p;
    final target =
        _axes.where((a) => a.name.text.trim().toLowerCase() == name.toLowerCase()).firstOrNull ??
        _axes.where((a) => a.values.isEmpty).firstOrNull ??
        (_axes.length < 3 ? (_Axis('')..let(_axes.add)) : null);
    if (target == null) return;
    target.name.text = name;
    for (final v in values) {
      if (!target.values.contains(v)) target.values.add(v);
    }
    _sync();
  });

  Future<void> _save() async {
    final axes = _ready;
    final rows = _rows.values.where((r) => r.included).toList();
    final names = axes.map((a) => a.name.text.trim().toLowerCase()).toList();
    if (names.toSet().length != names.length) return showInfo(context, 'Deux options portent le même nom');
    if (axes.isNotEmpty && rows.isEmpty) return showInfo(context, 'Gardez au moins une variante');
    for (final r in rows) {
      if (int.tryParse(r.price.text.replaceAll(' ', '')) == null) {
        return showInfo(context, 'Indiquez le prix de « ${r.options.values.join(' · ')} »');
      }
    }
    if (axes.isEmpty && _existing.isNotEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Retirer toutes les variantes ?'),
          content: Text('« ${_product!.name} » redeviendra un produit simple.'),
          actions: dialogActions([
            CancelButton(onPressed: () => Navigator.pop(ctx, false)),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Retirer')),
          ]),
        ),
      );
      if (ok != true) return;
    }
    setState(() => _busy = true);
    final repo = ref.read(repoProvider);
    try {
      final saved = await repo.setVariants(
        widget.productId,
        [for (final a in axes) VariantAxis(a.name.text.trim(), a.values)],
        [
          for (final r in rows)
            VariantDraft(
              options: r.options,
              price: int.parse(r.price.text.replaceAll(' ', '')),
              barcode: r.barcode.text.trim(),
            ),
        ],
      );
      // Stock de départ des nouvelles variantes
      var stockFailed = false;
      for (final r in rows.where((r) => r.existing == null)) {
        final q = double.tryParse(r.qty.text.replaceAll(',', '.').replaceAll(' ', '')) ?? 0;
        if (q <= 0) continue;
        final v = saved.where((s) => _key(s.options) == _key(r.options)).firstOrNull;
        if (v == null) continue;
        try {
          await repo.addStock(v.id, q, unitCost: _product!.cost > 0 ? _product!.cost : null);
        } catch (_) {
          stockFailed = true;
        }
      }
      refreshBusinessData(ref);
      ref.invalidate(productProvider(widget.productId));
      if (!mounted) return;
      showInfo(
        context,
        stockFailed
            ? 'Variantes enregistrées, mais une partie du stock n’a pas pu l’être'
            : axes.isEmpty
            ? 'Variantes retirées'
            : '${saved.length} variante${saved.length > 1 ? 's' : ''} enregistrée${saved.length > 1 ? 's' : ''}',
      );
      context.canPop() ? context.pop(true) : context.go('/products/${widget.productId}');
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _product;
    final digits = [FilteringTextInputFormatter.digitsOnly];
    final rows = _rows.values.toList();
    final count = rows.where((r) => r.included).length;
    return AuroraScaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Tailles, couleurs…', style: TextStyle(fontWeight: FontWeight.w800)),
            if (p != null)
              Text(
                p.name,
                style: TextStyle(fontSize: 12.5, color: AppColors.muted, fontWeight: FontWeight.w600),
              ),
          ],
        ),
      ),
      body: p == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    children: [
                      Text(
                        'Un même article en plusieurs versions : chaque combinaison a son stock, son prix et son code-barres. '
                        'À la caisse, on touche le produit puis on choisit.',
                        style: TextStyle(color: AppColors.muted, fontSize: 13, height: 1.4),
                      ),
                      const SizedBox(height: 12),
                      Text('Listes toutes prêtes', style: TextStyle(color: AppColors.muted, fontSize: 12.5)),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final pr in variantPresets)
                            ActionChip(
                              key: Key('preset_${pr.$1}'),
                              avatar: Icon(Icons.auto_awesome_rounded, size: 16, color: AppColors.green),
                              label: Text(pr.$2),
                              onPressed: () => _preset(pr),
                            ),
                        ],
                      ),
                      for (final (i, a) in _axes.indexed) ...[
                        const SizedBox(height: 14),
                        Glass(
                          key: Key('axis_$i'),
                          radius: 20,
                          padding: const EdgeInsets.fromLTRB(14, 12, 8, 14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      key: Key('axis_name_$i'),
                                      controller: a.name,
                                      textCapitalization: TextCapitalization.sentences,
                                      onChanged: (_) => setState(_sync),
                                      decoration: InputDecoration(
                                        labelText: 'Option ${i + 1}',
                                        hintText: 'Ex. Taille, Couleur',
                                        isDense: true,
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Retirer cette option',
                                    onPressed: () => setState(() {
                                      _axes.removeAt(i).dispose();
                                      _sync();
                                    }),
                                    icon: Icon(Icons.close_rounded, color: AppColors.muted),
                                  ),
                                ],
                              ),
                              if (a.name.text.trim().isEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Wrap(
                                    spacing: 6,
                                    runSpacing: 6,
                                    children: [
                                      for (final s in _axisSuggestions)
                                        Pill(
                                          label: s,
                                          selected: false,
                                          onTap: () => setState(() {
                                            a.name.text = s;
                                            _sync();
                                          }),
                                        ),
                                    ],
                                  ),
                                ),
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  for (final v in a.values)
                                    InputChip(
                                      label: Text(v, style: const TextStyle(fontWeight: FontWeight.w700)),
                                      onDeleted: () => setState(() {
                                        a.values.remove(v);
                                        _sync();
                                      }),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: TextField(
                                  key: Key('axis_values_$i'),
                                  controller: a.input,
                                  textCapitalization: TextCapitalization.sentences,
                                  onSubmitted: (t) => _addValues(a, t),
                                  decoration: InputDecoration(
                                    hintText: a.values.isEmpty ? 'Ex. S, M, L, XL' : 'Ajouter une valeur',
                                    isDense: true,
                                    suffixIcon: IconButton(
                                      key: Key('axis_add_$i'),
                                      tooltip: 'Ajouter',
                                      icon: Icon(Icons.add_circle_rounded, color: AppColors.green),
                                      onPressed: () => _addValues(a, a.input.text),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      if (_axes.length < 3)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: OutlinedButton.icon(
                            key: const Key('axis_new'),
                            onPressed: () => setState(() => _axes.add(_Axis(''))),
                            icon: const Icon(Icons.add_rounded),
                            label: Text(_axes.isEmpty ? 'Ajouter une option' : 'Ajouter une autre option'),
                          ),
                        ),
                      if (rows.isNotEmpty) ...[
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            Text(
                              '$count variante${count > 1 ? 's' : ''}',
                              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                            ),
                            const Spacer(),
                            Text('prix · stock', style: TextStyle(color: AppColors.muted, fontSize: 12.5)),
                          ],
                        ),
                        const SizedBox(height: 8),
                        for (final r in rows)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _VariantRow(
                              row: r,
                              onHand: r.existing == null ? null : _onHand[r.existing!.id],
                              digits: digits,
                              unit: p.unit,
                              tracked: p.trackStock && !p.isService,
                              onToggle: (v) => setState(() => r.included = v),
                            ),
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
                      key: const Key('variants_save'),
                      accent: true,
                      label: _ready.isEmpty
                          ? (_existing.isEmpty ? 'Enregistrer' : 'Retirer les variantes')
                          : 'Enregistrer $count variante${count > 1 ? 's' : ''}',
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

class _VariantRow extends StatelessWidget {
  const _VariantRow({
    required this.row,
    required this.onHand,
    required this.digits,
    required this.unit,
    required this.tracked,
    required this.onToggle,
  });
  final _Row row;
  final double? onHand;
  final List<TextInputFormatter> digits;
  final String unit;
  final bool tracked;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final label = row.options.values.join(' · ');
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 150),
      opacity: row.included ? 1 : 0.5,
      child: Glass(
        radius: 16,
        padding: const EdgeInsets.fromLTRB(6, 6, 12, 8),
        child: Column(
          children: [
            Row(
              children: [
                Checkbox(key: Key('variant_on_$label'), value: row.included, onChanged: (v) => onToggle(v ?? false)),
                Expanded(
                  child: Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
                ),
                if (row.existing != null && onHand != null)
                  Text(
                    'En stock : ${qty(onHand!)}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: onHand! <= 0 ? AppColors.danger : AppColors.muted,
                    ),
                  ),
              ],
            ),
            if (row.included)
              Padding(
                padding: const EdgeInsets.only(left: 10),
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        key: Key('variant_price_$label'),
                        controller: row.price,
                        keyboardType: TextInputType.number,
                        inputFormatters: digits,
                        decoration: const InputDecoration(labelText: 'Prix', suffixText: 'F', isDense: true),
                      ),
                    ),
                    if (tracked && row.existing == null) ...[
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2,
                        child: TextField(
                          key: Key('variant_qty_$label'),
                          controller: row.qty,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: InputDecoration(
                            labelText: 'Stock',
                            hintText: '0',
                            suffixText: unit == 'pièce' ? null : unit,
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

extension<T> on T {
  T let(void Function(T) f) {
    f(this);
    return this;
  }
}
