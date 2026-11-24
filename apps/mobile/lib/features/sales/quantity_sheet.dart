import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// Quantité tapée à la main : 2,5 m de câble, 1 carton de 24, 50 pièces…
/// Renvoie la nouvelle quantité (0 : retirer du panier), ou null si on annule.
Future<double?> pickQuantity(BuildContext context, {required Product product, double current = 0, double? onHand}) =>
    showModalBottomSheet<double>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _QuantitySheet(product: product, current: current, onHand: onHand),
    );

/// Quantité lue dans le champ : virgule ou point, espaces ignorés.
double? parseQuantity(String text) {
  final v = double.tryParse(text.replaceAll(',', '.').replaceAll(RegExp(r'\s'), ''));
  if (v == null || v < 0) return null;
  return (v * 1000).round() / 1000;
}

class _QuantitySheet extends StatefulWidget {
  const _QuantitySheet({required this.product, required this.current, this.onHand});
  final Product product;
  final double current;
  final double? onHand;

  @override
  State<_QuantitySheet> createState() => _QuantitySheetState();
}

class _QuantitySheetState extends State<_QuantitySheet> {
  late final _ctrl = TextEditingController(text: widget.current > 0 ? qty(widget.current).replaceAll('.', ',') : '');

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _set(double v) {
    final t = qty(v).replaceAll('.', ',');
    _ctrl.value = TextEditingValue(
      text: t,
      selection: TextSelection.collapsed(offset: t.length),
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    final q = parseQuantity(_ctrl.text);
    final unit = p.unit == 'pièce' ? '' : p.unit;
    final pack = p.hasPack ? p.packSize! : null;
    final packs = pack == null || q == null || q == 0 ? null : q / pack;
    final total = q == null ? null : (p.unitPriceFor(q) * q).round();
    final tooMuch = widget.onHand != null && p.trackStock && q != null && q > widget.onHand!;
    final quick = p.decimalUnit ? [0.5, 1.0, 2.0, 5.0, 10.0] : [1.0, 2.0, 5.0, 10.0, 20.0];
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(p.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            Text(
              '${moneyShort(p.price)}${unit.isEmpty ? ' la pièce' : ' le $unit'}'
              '${p.hasWholesale ? ' · ${moneyShort(p.wholesalePrice!)} dès ${qty(p.wholesaleMinQty!)}' : ''}',
              style: TextStyle(color: AppColors.muted, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 14),
            TextField(
              key: const Key('qty_input'),
              controller: _ctrl,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
              textAlign: TextAlign.center,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (q != null) Navigator.pop(context, q);
              },
              decoration: InputDecoration(
                hintText: '0',
                suffixText: unit.isEmpty ? 'pièce${(q ?? 0) > 1 ? 's' : ''}' : unit,
                helperText: packs != null && packs >= 1
                    ? '= ${qty((packs * 100).round() / 100)} ${p.packName!.toLowerCase()}${packs >= 2 ? 's' : ''} de ${qty(pack!)}'
                    : null,
              ),
            ),
            const SizedBox(height: 12),
            if (pack != null) ...[
              Text(
                'Par ${p.packName!.toLowerCase()} (${qty(pack)}${unit.isEmpty ? '' : ' $unit'})',
                style: TextStyle(color: AppColors.muted, fontSize: 12.5),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final n in [1, 2, 5, 10])
                    ActionChip(
                      key: Key('qty_pack_$n'),
                      avatar: Icon(Icons.inventory_2_rounded, size: 16, color: AppColors.accent),
                      label: Text('$n ${p.packName!.toLowerCase()}${n > 1 ? 's' : ''}'),
                      onPressed: () => _set(n * pack),
                    ),
                ],
              ),
              const SizedBox(height: 10),
            ],
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final v in quick)
                  ActionChip(
                    key: Key('qty_quick_${qty(v)}'),
                    label: Text('${qty(v).replaceAll('.', ',')}${unit.isEmpty ? '' : ' $unit'}'),
                    onPressed: () => _set(v),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            if (tooMuch)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Il n’en reste que ${qty(widget.onHand!)} en stock',
                  style: TextStyle(color: AppColors.warnText, fontWeight: FontWeight.w700),
                ),
              ),
            Row(
              children: [
                if (widget.current > 0) ...[
                  Expanded(
                    child: SizedBox(
                      height: 52,
                      child: OutlinedButton(
                        key: const Key('qty_remove'),
                        onPressed: () => Navigator.pop(context, 0.0),
                        child: Text('Retirer', style: TextStyle(color: AppColors.danger)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  flex: 2,
                  child: SizedBox(
                    height: 52,
                    child: FilledButton(
                      key: const Key('qty_ok'),
                      style: accentButtonStyle(),
                      onPressed: q == null || q == 0 ? null : () => Navigator.pop(context, q),
                      child: Text(q == null || q == 0 ? 'Indiquez la quantité' : 'Valider · ${moneyShort(total!)}'),
                    ),
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
