import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../catalog/barcode_scanner.dart';
import 'cart.dart';

/// Restaurant : suppléments et options d'un plat, puis la quantité. Renvoie la ligne à ajouter.
Future<CartLine?> pickExtras(BuildContext context, Product product) => showModalBottomSheet<CartLine>(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _ExtrasSheet(product: product),
);

class _ExtrasSheet extends StatefulWidget {
  const _ExtrasSheet({required this.product});
  final Product product;
  @override
  State<_ExtrasSheet> createState() => _ExtrasSheetState();
}

class _ExtrasSheetState extends State<_ExtrasSheet> {
  final _chosen = <ProductExtra>{};
  var _qty = 1;

  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    final line = CartLine(
      p,
      _qty.toDouble(),
      extras: [
        for (final e in p.extras)
          if (_chosen.contains(e)) e,
      ],
    );
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(p.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            Text(
              moneyShort(p.price),
              style: TextStyle(color: AppColors.green, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            Text('Suppléments et options', style: TextStyle(color: AppColors.muted, fontSize: 12.5)),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.45),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final e in p.extras)
                    CheckboxListTile(
                      key: Key('extra_${e.name}'),
                      contentPadding: EdgeInsets.zero,
                      value: _chosen.contains(e),
                      onChanged: (v) => setState(() => v == true ? _chosen.add(e) : _chosen.remove(e)),
                      title: Text(e.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                      secondary: Text(
                        e.price == 0 ? 'offert' : '+ ${moneyShort(e.price)}',
                        style: TextStyle(
                          color: e.price == 0 ? AppColors.muted : AppColors.green,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                IconButton.filledTonal(
                  tooltip: 'Un de moins',
                  onPressed: _qty > 1 ? () => setState(() => _qty--) : null,
                  icon: const Icon(Icons.remove_rounded),
                ),
                SizedBox(
                  width: 44,
                  child: Text(
                    '$_qty',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                  ),
                ),
                IconButton.filledTonal(
                  key: const Key('extras_more'),
                  tooltip: 'Un de plus',
                  onPressed: () => setState(() => _qty++),
                  icon: const Icon(Icons.add_rounded),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SizedBox(
                    height: 52,
                    child: FilledButton(
                      key: const Key('extras_ok'),
                      style: accentButtonStyle(),
                      onPressed: () => Navigator.pop(context, line),
                      child: Text('Ajouter · ${moneyShort(line.total)}'),
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

/// Téléphonie : un IMEI / numéro de série par appareil (tapé ou scanné). Renvoie la liste.
Future<List<String>?> pickSerials(BuildContext context, Product product, {List<String> current = const []}) =>
    showModalBottomSheet<List<String>>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _SerialsSheet(product: product, current: current),
    );

class _SerialsSheet extends ConsumerStatefulWidget {
  const _SerialsSheet({required this.product, required this.current});
  final Product product;
  final List<String> current;
  @override
  ConsumerState<_SerialsSheet> createState() => _SerialsSheetState();
}

class _SerialsSheetState extends ConsumerState<_SerialsSheet> {
  late final _list = [...widget.current];
  final _ctrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _add(String raw) {
    final v = raw.trim().replaceAll(RegExp(r'\s'), '');
    if (v.isEmpty) return;
    setState(() {
      if (v.length < 3) {
        _error = 'Numéro trop court';
      } else if (_list.contains(v)) {
        _error = 'Déjà ajouté';
      } else {
        _list.add(v);
        _error = null;
        _ctrl.clear();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    final n = _list.length;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(p.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            Text(
              'IMEI ou numéro de série de chaque appareil vendu'
              '${(p.warrantyMonths ?? 0) > 0 ? ' · garantie ${p.warrantyMonths} mois' : ''}',
              style: TextStyle(color: AppColors.muted, fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('serial_input'),
              controller: _ctrl,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              onSubmitted: _add,
              decoration: InputDecoration(
                labelText: 'IMEI / numéro de série',
                errorText: _error,
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Scanner',
                      icon: const Icon(Icons.qr_code_scanner_rounded),
                      onPressed: () async {
                        final code = await ref.read(barcodeScannerProvider)(context);
                        if (code != null) _add(code);
                      },
                    ),
                    IconButton(
                      key: const Key('serial_add'),
                      tooltip: 'Ajouter',
                      icon: Icon(Icons.add_circle_rounded, color: AppColors.green),
                      onPressed: () => _add(_ctrl.text),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final s in _list)
                  InputChip(
                    avatar: const Icon(Icons.smartphone_rounded, size: 16),
                    label: Text(s, style: const TextStyle(fontWeight: FontWeight.w700)),
                    onDeleted: () => setState(() => _list.remove(s)),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            SizedBox(
              height: 52,
              child: FilledButton(
                key: const Key('serials_ok'),
                style: accentButtonStyle(),
                onPressed: n == 0 ? null : () => Navigator.pop(context, _list),
                child: Text(
                  n == 0
                      ? 'Ajoutez au moins un numéro'
                      : 'Valider $n appareil${n > 1 ? 's' : ''} · ${moneyShort(p.unitPriceFor(n.toDouble()) * n)}',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
