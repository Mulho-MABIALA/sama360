import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uuid/uuid.dart';

import '../../core/api/api_client.dart';
import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/repositories.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../catalog/product_photo.dart';
import '../customers/customer_picker.dart';

/// Délais proposés : à réception / N jours (facture), N jours de validité (devis).
const _invoiceTerms = [0, 7, 15, 30];
const _quoteValidity = [15, 30, 60];

/// Création d'un devis ou d'une facture, ou modification d'un devis.
class DocumentEditorScreen extends ConsumerStatefulWidget {
  const DocumentEditorScreen({super.key, required this.kind, this.editId});
  final DocKind kind;

  /// Devis à modifier (null : création).
  final String? editId;

  @override
  ConsumerState<DocumentEditorScreen> createState() => _DocumentEditorScreenState();
}

class _DocumentEditorScreenState extends ConsumerState<DocumentEditorScreen> {
  final _id = const Uuid().v7(); // même identifiant à chaque essai : pas de doublon
  final _discount = TextEditingController();
  final _note = TextEditingController();
  Contact? _customer;
  final _lines = <DocLineDraft>[];
  late int _days = widget.kind == DocKind.quote ? 30 : 0;
  bool _busy = false;
  bool _loaded = false;

  bool get _isQuote => widget.kind == DocKind.quote;
  int get _subtotal => _lines.fold(0, (s, l) => s + l.total);
  int get _discountValue => int.tryParse(_discount.text.replaceAll(' ', '')) ?? 0;
  int get _total => (_subtotal - _discountValue).clamp(0, _subtotal);

  @override
  void initState() {
    super.initState();
    if (widget.editId == null) {
      _loaded = true;
    } else {
      ref.read(documentProvider(widget.editId!).future).then((d) {
        if (!mounted) return;
        setState(() {
          _customer = d.customer;
          _lines.addAll(d.lines.map(DocLineDraft.fromLine));
          if (d.discount > 0) _discount.text = '${d.discount}';
          _note.text = d.note ?? '';
          if (d.dueDate != null) _days = d.dueDate!.difference(d.issueDate).inDays;
          _loaded = true;
        });
      });
    }
  }

  @override
  void dispose() {
    _discount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickCustomer() async {
    final c = await pickCustomer(context);
    if (c != null) setState(() => _customer = c);
  }

  Future<void> _addProduct() async {
    final p = await showModalBottomSheet<Product>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _ProductPicker(),
    );
    if (p == null) return;
    setState(() {
      final i = _lines.indexWhere((l) => l.productId == p.id);
      if (i >= 0) {
        _lines[i] = _lines[i].copyWith(quantity: _lines[i].quantity + 1);
      } else {
        _lines.add(DocLineDraft(productId: p.id, name: p.name, quantity: 1, unitPrice: p.price));
      }
    });
  }

  Future<void> _editLine([int? index]) async {
    final result = await showModalBottomSheet<DocLineDraft?>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _LineSheet(line: index == null ? null : _lines[index]),
    );
    if (result == null) return;
    setState(() => index == null ? _lines.add(result) : _lines[index] = result);
  }

  Future<void> _save() async {
    if (_customer == null) return showInfo(context, 'Choisissez le client');
    if (_lines.isEmpty) return showInfo(context, 'Ajoutez au moins une ligne');
    if (_discountValue > _subtotal) return showInfo(context, 'La remise dépasse le montant');
    final now = DateTime.now();
    final issue = DateTime(now.year, now.month, now.day);
    final body = SamaRepository.documentBody(
      customerId: _customer!.id,
      lines: _lines,
      discount: _discountValue,
      issueDate: widget.editId == null ? issue : null,
      dueDate: _days > 0 ? issue.add(Duration(days: _days)) : null,
      clearDueDate: _days == 0,
      note: _note.text,
    );
    setState(() => _busy = true);
    try {
      final repo = ref.read(repoProvider);
      final doc = widget.editId == null
          ? await repo.createDocument(id: _id, kind: widget.kind, body: body)
          : await repo.updateQuote(widget.editId!, body);
      refreshInvoicing(ref);
      if (!mounted) return;
      if (widget.editId == null) {
        context.pushReplacement('/invoices/${doc.id}');
      } else {
        context.pop();
      }
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.editId != null ? 'Modifier le devis' : (_isQuote ? 'Nouveau devis' : 'Nouvelle facture');
    final terms = _isQuote ? _quoteValidity : _invoiceTerms;
    return AuroraScaffold(
      appBar: AppBar(
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
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
                        title: 'Client',
                        child: _customer == null
                            ? OutlinedButton.icon(
                                onPressed: _pickCustomer,
                                icon: const Icon(Icons.person_add_alt_1_rounded),
                                label: const Text('Choisir le client'),
                              )
                            : ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: Avatar(name: _customer!.name, bg: AppColors.greenSoft, fg: AppColors.green),
                                title: Text(_customer!.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                                subtitle: _customer!.phone == null
                                    ? null
                                    : Text('+221 ${displayPhone(_customer!.phone!)}'),
                                trailing: TextButton(onPressed: _pickCustomer, child: const Text('Changer')),
                              ),
                      ),
                      const SizedBox(height: 12),
                      _Section(
                        title: 'Articles et prestations',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
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
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: _addProduct,
                                    icon: const Icon(Icons.inventory_2_outlined),
                                    label: const Text('Produit'),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: _editLine,
                                    icon: const Icon(Icons.edit_note_rounded),
                                    label: const Text('Ligne libre'),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      _Section(
                        title: _isQuote ? 'Validité du devis' : 'Paiement attendu',
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final d in terms)
                              Pill(
                                label: d == 0 ? 'À réception' : (_isQuote ? '$d jours' : 'Sous $d jours'),
                                selected: _days == d,
                                onTap: () => setState(() => _days = d),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      _Section(
                        title: 'Remise et note',
                        child: Column(
                          children: [
                            TextField(
                              key: const Key('docDiscount'),
                              controller: _discount,
                              keyboardType: TextInputType.number,
                              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                              decoration: const InputDecoration(labelText: 'Remise (facultatif)', suffixText: 'FCFA'),
                              onChanged: (_) => setState(() {}),
                            ),
                            const SizedBox(height: 10),
                            TextField(
                              key: const Key('docNote'),
                              controller: _note,
                              maxLines: 3,
                              minLines: 1,
                              decoration: const InputDecoration(
                                labelText: 'Note pour le client (facultatif)',
                                hintText: 'Ex. livraison sous 72 h, conditions de paiement…',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(10, 4, 10, 8 + MediaQuery.paddingOf(context).bottom),
                  child: Glass(
                    radius: 28,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                _discountValue > 0 ? 'Total après remise' : 'Total',
                                style: const TextStyle(color: AppColors.muted, fontWeight: FontWeight.w600),
                              ),
                            ),
                            Text(money(_total), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                          ],
                        ),
                        const SizedBox(height: 10),
                        BusyButton(
                          label: widget.editId != null
                              ? 'Enregistrer les modifications'
                              : (_isQuote ? 'Créer le devis' : 'Émettre la facture'),
                          busy: _busy,
                          onPressed: _save,
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
  final DocLineDraft line;
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
                if ((line.description ?? '').isNotEmpty)
                  Text(line.description!, style: const TextStyle(fontSize: 12, color: AppColors.muted)),
                Text(
                  '${qty(line.quantity)} × ${moneyShort(line.unitPrice)} = ${moneyShort(line.total)}',
                  style: const TextStyle(fontSize: 13, color: AppColors.muted),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: line.quantity <= 1 ? 'Retirer ${line.name}' : 'Une de moins',
            onPressed: onMinus,
            icon: Icon(line.quantity <= 1 ? Icons.delete_outline_rounded : Icons.remove_circle_outline_rounded),
          ),
          Text(qty(line.quantity), style: const TextStyle(fontWeight: FontWeight.w800)),
          IconButton(tooltip: 'Une de plus', onPressed: onPlus, icon: const Icon(Icons.add_circle_outline_rounded)),
        ],
      ),
    ),
  );
}

/// Ligne libre (prestation, transport…) ou modification d'une ligne.
class _LineSheet extends StatefulWidget {
  const _LineSheet({this.line});
  final DocLineDraft? line;
  @override
  State<_LineSheet> createState() => _LineSheetState();
}

class _LineSheetState extends State<_LineSheet> {
  late final _name = TextEditingController(text: widget.line?.name ?? '');
  late final _desc = TextEditingController(text: widget.line?.description ?? '');
  late final _qty = TextEditingController(text: widget.line == null ? '1' : qty(widget.line!.quantity));
  late final _price = TextEditingController(text: widget.line == null ? '' : '${widget.line!.unitPrice}');
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _desc, _qty, _price]) {
      c.dispose();
    }
    super.dispose();
  }

  void _ok() {
    final q = double.tryParse(_qty.text.replaceAll(',', '.').replaceAll(' ', ''));
    final p = int.tryParse(_price.text.replaceAll(' ', ''));
    if (_name.text.trim().isEmpty || q == null || q <= 0 || p == null) {
      setState(() => _error = 'Désignation, quantité et prix sont nécessaires');
      return;
    }
    Navigator.pop(
      context,
      DocLineDraft(
        productId: widget.line?.productId,
        name: _name.text.trim(),
        description: _desc.text.trim().isEmpty ? null : _desc.text.trim(),
        quantity: q,
        unitPrice: p,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.line == null ? 'Ligne libre' : 'Modifier la ligne',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 14),
        TextField(
          key: const Key('lineName'),
          controller: _name,
          autofocus: widget.line == null,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'Désignation', hintText: 'Ex. Livraison, main-d’œuvre…'),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _desc,
          decoration: const InputDecoration(labelText: 'Détail (facultatif)'),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('lineQty'),
                controller: _qty,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Quantité'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: TextField(
                key: const Key('linePrice'),
                controller: _price,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(labelText: 'Prix unitaire', suffixText: 'FCFA'),
              ),
            ),
          ],
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_error!, style: const TextStyle(color: AppColors.danger)),
          ),
        const SizedBox(height: 16),
        FilledButton(onPressed: _ok, child: const Text('Valider la ligne')),
      ],
    ),
  );
}

/// Choix d'un produit du catalogue.
class _ProductPicker extends ConsumerStatefulWidget {
  const _ProductPicker();
  @override
  ConsumerState<_ProductPicker> createState() => _ProductPickerState();
}

class _ProductPickerState extends ConsumerState<_ProductPicker> {
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
                  final shown = list.where((p) => _q.isEmpty || p.name.toLowerCase().contains(_q)).toList();
                  return ListView.builder(
                    itemCount: shown.length,
                    itemBuilder: (_, i) {
                      final p = shown[i];
                      return ListTile(
                        leading: ProductThumb(name: p.name, fileId: p.imageFileId, size: 44),
                        title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                        trailing: Text(moneyShort(p.price), style: const TextStyle(fontWeight: FontWeight.w800)),
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

/// Date courte « 16 nov. 2026 ».
String shortDocDate(DateTime d) => DateFormat('d MMM yyyy', 'fr').format(d);
