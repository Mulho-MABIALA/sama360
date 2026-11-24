import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import 'product_photo.dart';

/// Choix d'une variante (couleur, taille…) d'un modèle : renvoie la variante choisie.
/// [onHand] : stock par produit (absent = stock non visible pour ce membre).
Future<Product?> pickVariant(
  BuildContext context, {
  required Product parent,
  required List<Product> variants,
  Map<String, double>? onHand,
  String action = 'Ajouter',
}) => showModalBottomSheet<Product>(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _VariantPicker(parent: parent, variants: variants, onHand: onHand, action: action),
);

class _VariantPicker extends ConsumerStatefulWidget {
  const _VariantPicker({required this.parent, required this.variants, this.onHand, required this.action});
  final Product parent;
  final List<Product> variants;
  final Map<String, double>? onHand;
  final String action;

  @override
  ConsumerState<_VariantPicker> createState() => _VariantPickerState();
}

class _VariantPickerState extends ConsumerState<_VariantPicker> {
  late final Map<String, String> _sel = {
    // Une option à une seule valeur est déjà choisie
    for (final a in widget.parent.variantAxes)
      if (a.values.length == 1) a.name: a.values.first,
  };

  Product? get _match {
    if (_sel.length != widget.parent.variantAxes.length) return null;
    for (final v in widget.variants) {
      if (widget.parent.variantAxes.every((a) => v.options[a.name] == _sel[a.name])) return v;
    }
    return null;
  }

  /// Une valeur est grisée quand aucune variante en stock ne la propose avec les choix déjà faits.
  bool _available(VariantAxis axis, String value) {
    final stock = widget.onHand;
    return widget.variants.any(
      (v) =>
          v.options[axis.name] == value &&
          widget.parent.variantAxes.every(
            (a) => a.name == axis.name || _sel[a.name] == null || v.options[a.name] == _sel[a.name],
          ) &&
          (stock == null || !v.trackStock || (stock[v.id] ?? 0) > 0),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.parent;
    final m = _match;
    final complete = _sel.length == p.variantAxes.length;
    final stock = m == null || widget.onHand == null || !m.trackStock ? null : widget.onHand![m.id] ?? 0;
    final prices = widget.variants.map((v) => v.price).toSet();
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ProductThumb(name: p.name, fileId: m?.imageFileId ?? p.imageFileId, size: 56),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(p.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                      Text(
                        m != null
                            ? moneyShort(m.price)
                            : prices.length > 1
                            ? 'dès ${moneyShort(prices.reduce((a, b) => a < b ? a : b))}'
                            : moneyShort(prices.isEmpty ? p.price : prices.first),
                        style: TextStyle(color: AppColors.green, fontWeight: FontWeight.w800, fontSize: 15),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            for (final a in p.variantAxes) ...[
              const SizedBox(height: 16),
              Text(
                _sel[a.name] == null ? a.name : '${a.name} : ${_sel[a.name]}',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final value in a.values)
                    _OptionChip(
                      key: Key('opt_${a.name}_$value'),
                      label: value,
                      selected: _sel[a.name] == value,
                      dimmed: !_available(a, value),
                      onTap: () => setState(() => _sel[a.name] = value),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            if (complete && m == null)
              Text(
                'Cette combinaison n’existe pas',
                style: TextStyle(color: AppColors.danger, fontWeight: FontWeight.w700),
              )
            else if (stock != null)
              Text(
                stock <= 0 ? 'Rupture de stock' : 'En stock : ${qty(stock)}',
                style: TextStyle(color: stock <= 0 ? AppColors.danger : AppColors.muted, fontWeight: FontWeight.w700),
              ),
            const SizedBox(height: 10),
            SizedBox(
              height: 52,
              child: FilledButton.icon(
                key: const Key('variant_add'),
                style: accentButtonStyle(),
                onPressed: m == null ? null : () => Navigator.pop(context, m),
                icon: const Icon(Icons.add_shopping_cart_rounded),
                label: Text(
                  m == null
                      ? 'Choisissez ${p.variantAxes.where((a) => _sel[a.name] == null).map((a) => a.name.toLowerCase()).join(' et ')}'
                      : '${widget.action} · ${moneyShort(m.price)}',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OptionChip extends StatelessWidget {
  const _OptionChip({
    super.key,
    required this.label,
    required this.selected,
    required this.dimmed,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final bool dimmed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    button: true,
    child: Material(
      color: selected ? AppColors.green : AppColors.surface(0.9),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: selected ? AppColors.green : AppColors.line, width: 1.4),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 52, minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Center(
              widthFactor: 1,
              child: Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: selected
                      ? AppColors.onGreen
                      : dimmed
                      ? AppColors.muted.withValues(alpha: 0.6)
                      : AppColors.ink,
                  decoration: dimmed && !selected ? TextDecoration.lineThrough : null,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
