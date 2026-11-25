import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/discount.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// Remise sur un article ou sur toute la vente (facture, devis) : en % ou en francs.
/// Renvoie la remise choisie ([Discount.none] pour la retirer), ou null si on annule.
Future<Discount?> pickDiscount(
  BuildContext context, {
  required String title,
  required int base,
  Discount current = Discount.none,
}) => showModalBottomSheet<Discount>(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _DiscountSheet(title: title, base: base, current: current),
);

class _DiscountSheet extends StatefulWidget {
  const _DiscountSheet({required this.title, required this.base, required this.current});
  final String title;
  final int base;
  final Discount current;

  @override
  State<_DiscountSheet> createState() => _DiscountSheetState();
}

class _DiscountSheetState extends State<_DiscountSheet> {
  late bool _percent = widget.current.isNone || widget.current.isPercent;
  late final _ctrl = TextEditingController(
    text: widget.current.isNone ? '' : '${widget.current.percent ?? widget.current.amount}',
  );

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  int? get _value => int.tryParse(_ctrl.text.replaceAll(RegExp(r'\s'), ''));

  Discount? get _discount {
    final v = _value;
    if (v == null || v <= 0) return null;
    return _percent ? Discount.percent(v) : Discount.amount(v);
  }

  String? get _error {
    final v = _value;
    if (v == null) return null;
    if (_percent && v > 100) return 'Pas plus de 100 %';
    if (!_percent && v > widget.base) return 'Plus grande que le montant (${moneyShort(widget.base)})';
    return null;
  }

  void _set(int v) {
    _ctrl.value = TextEditingValue(
      text: '$v',
      selection: TextSelection.collapsed(offset: '$v'.length),
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final d = _discount;
    final off = d == null || _error != null ? 0 : d.of(widget.base);
    final ok = d != null && _error == null;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            Text(
              'Montant : ${moneyShort(widget.base)}',
              style: TextStyle(color: AppColors.muted, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 14),
            SegmentedButton<bool>(
              key: const Key('discount_kind'),
              segments: const [
                ButtonSegment(value: true, label: Text('En %'), icon: Icon(Icons.percent_rounded)),
                ButtonSegment(value: false, label: Text('En francs'), icon: Icon(Icons.payments_rounded)),
              ],
              selected: {_percent},
              onSelectionChanged: (s) => setState(() {
                _percent = s.first;
                _ctrl.clear();
              }),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('discount_value'),
              controller: _ctrl,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
              textAlign: TextAlign.center,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(hintText: '0', suffixText: _percent ? '%' : 'F', errorText: _error),
            ),
            const SizedBox(height: 10),
            if (_percent)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final p in [5, 10, 15, 20, 25, 50])
                    ActionChip(key: Key('discount_quick_$p'), label: Text('$p %'), onPressed: () => _set(p)),
                ],
              ),
            const SizedBox(height: 14),
            if (off > 0)
              Container(
                key: const Key('discount_preview'),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: AppColors.softOf(const Color(0xFFFFF4E2), const Color(0xFF9A5B00)),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Remise −${moneyShort(off)}',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: AppColors.strongOf(const Color(0xFFFFF4E2), const Color(0xFF9A5B00)),
                        ),
                      ),
                    ),
                    Text(
                      'À payer ${moneyShort(widget.base - off)}',
                      style: TextStyle(fontWeight: FontWeight.w800, color: AppColors.green),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 14),
            Row(
              children: [
                if (!widget.current.isNone) ...[
                  Expanded(
                    child: SizedBox(
                      height: 52,
                      child: OutlinedButton(
                        key: const Key('discount_remove'),
                        onPressed: () => Navigator.pop(context, Discount.none),
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
                      key: const Key('discount_apply'),
                      style: accentButtonStyle(),
                      onPressed: ok ? () => Navigator.pop(context, d) : null,
                      child: Text(ok ? 'Appliquer · −${moneyShort(off)}' : 'Indiquez la remise'),
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

/// Libellé court d'une remise : « 10 % » ou « 5 000 F ».
String discountLabel(Discount d) => d.isPercent ? '${d.percent} %' : moneyShort(d.amount);
