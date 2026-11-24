import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/api_client.dart';
import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../catalog/product_photo.dart';
import 'purchase_editor.dart';

/// Facture fournisseur en photo : vérifie Pro, fait choisir la photo, puis ouvre la vérification.
/// [replace] : depuis l'écran « Nouvel achat » vide, la facture le remplace (pas deux saisies empilées).
Future<void> startInvoiceScan(BuildContext context, WidgetRef ref, {bool replace = false}) async {
  if (!ref.read(isProProvider)) {
    context.push('/pro?feature=${ProFeature.invoiceScan.key}');
    return;
  }
  final photo = await choosePhoto(context, ref, document: true);
  if (photo == null || !context.mounted) return;
  if (replace) {
    context.pushReplacement('/purchases/scan', extra: photo);
  } else {
    context.push('/purchases/scan', extra: photo);
  }
}

/// Carte « Facture en photo » (liste des achats).
class ScanInvoiceBanner extends ConsumerWidget {
  const ScanInvoiceBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pro = ref.watch(isProProvider);
    return Glass(
      key: const Key('scan_invoice_banner'),
      radius: 20,
      onTap: () => startInvoiceScan(context, ref),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      child: Row(
        children: [
          const GlossyOrb(icon: Icons.document_scanner_rounded, color: Color(0xFF7A5AF8), size: 44),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Flexible(
                      child: Text('Facture en photo', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
                    ),
                    if (!pro) ...[const SizedBox(width: 6), const _ProBadge()],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  'Photographiez la facture du fournisseur : l’achat et le stock se remplissent tout seuls.',
                  style: TextStyle(fontSize: 13, color: AppColors.muted),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, color: AppColors.muted),
        ],
      ),
    );
  }
}

class _ProBadge extends StatelessWidget {
  const _ProBadge();
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(color: AppColors.ink, borderRadius: BorderRadius.circular(6)),
    child: Text(
      'PRO',
      style: TextStyle(color: AppColors.ground, fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 0.5),
    ),
  );
}

/// « RIZ BRISE PARFUME 25KG » → « Riz brise parfume 25kg » (nom proposé pour un nouveau produit).
String tidyLabel(String label) {
  final t = label.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (t.isEmpty) return t;
  final lower = t == t.toUpperCase() ? t.toLowerCase() : t;
  return lower[0].toUpperCase() + lower.substring(1);
}

/// Une ligne de la facture en cours de vérification.
class _Line {
  _Line(ScannedLine s)
    : label = s.label,
      quantity = s.quantity,
      unitCost = s.unitCost,
      confidence = s.confidence,
      candidates = s.candidates,
      productId = s.product?.id,
      productName = s.product?.name,
      unit = s.product?.unit ?? 'pièce';
  final String label;
  double quantity;
  int unitCost;
  ScanConfidence confidence;
  final List<ScanCandidate> candidates;
  String? productId;
  String? productName;
  String unit;
  bool included = true;

  int get total => (quantity * unitCost).round();
  bool get ready => !included || productId != null;

  void assign(String id, String name, String unit, {ScanConfidence confidence = ScanConfidence.high}) {
    productId = id;
    productName = name;
    this.unit = unit;
    this.confidence = confidence;
  }
}

/// Lecture puis vérification d'une facture fournisseur, avant de créer l'achat.
class InvoiceScanScreen extends ConsumerStatefulWidget {
  const InvoiceScanScreen({super.key, required this.photo});
  final PickedPhoto? photo;

  @override
  ConsumerState<InvoiceScanScreen> createState() => _InvoiceScanScreenState();
}

class _InvoiceScanScreenState extends ConsumerState<InvoiceScanScreen> {
  late PickedPhoto? _photo = widget.photo;
  InvoiceScan? _scan;
  Object? _error;
  bool _loading = false;
  bool _busy = false;
  final _lines = <_Line>[];
  Contact? _supplier; // fournisseur existant choisi ou reconnu
  String? _newSupplier; // sinon : nom lu, créé à la validation

  @override
  void initState() {
    super.initState();
    if (_photo != null) Future(_read);
  }

  Future<void> _read() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final s = await ref.read(repoProvider).scanInvoice(_photo!.bytes, filename: _photo!.filename);
      if (!mounted) return;
      setState(() {
        _scan = s;
        _lines
          ..clear()
          ..addAll(s.lines.map(_Line.new));
        _supplier = s.supplierId == null ? null : Contact(id: s.supplierId!, name: s.supplierName ?? 'Fournisseur');
        _newSupplier = s.supplierId == null ? s.supplierName : null;
      });
    } catch (e) {
      if (!mounted) return;
      if (e is ApiException && e.code == 'PRO_REQUIRED') {
        context.pushReplacement('/pro?feature=${ProFeature.invoiceScan.key}');
        return;
      }
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _retake() async {
    final p = await choosePhoto(context, ref, document: true);
    if (p == null || !mounted) return;
    setState(() => _photo = p);
    await _read();
  }

  void _manual() => context.pushReplacement('/purchases/new');

  // ------------------------------------------------------------------ actions sur les lignes

  Future<void> _pickProduct(_Line l) async {
    final p = await showModalBottomSheet<Product>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const ProductPicker(),
    );
    if (p != null && mounted) setState(() => l.assign(p.id, p.name, p.unit));
  }

  Future<void> _createProduct(_Line l) async {
    final p = await showDialog<Product>(
      context: context,
      builder: (_) => _NewProductDialog(name: tidyLabel(l.label), cost: l.unitCost),
    );
    if (p != null && mounted) setState(() => l.assign(p.id, p.name, p.unit));
  }

  Future<void> _editAmounts(_Line l) async {
    final qtyField = TextEditingController(text: qty(l.quantity));
    final cost = TextEditingController(text: '${l.unitCost}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Quantité et prix'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('« ${l.label} »', style: TextStyle(color: AppColors.muted, fontSize: 13)),
            const SizedBox(height: 12),
            TextField(
              key: const Key('scan_qty'),
              controller: qtyField,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Quantité'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('scan_cost'),
              controller: cost,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'Prix d’achat unitaire', suffixText: 'F'),
            ),
          ],
        ),
        actions: dialogActions([
          CancelButton(onPressed: () => Navigator.pop(ctx, false)),
          ConfirmButton(label: 'Valider', onPressed: () => Navigator.pop(ctx, true)),
        ]),
      ),
    );
    if (ok != true || !mounted) return;
    final q = double.tryParse(qtyField.text.replaceAll(',', '.'));
    final c = int.tryParse(cost.text);
    if (q == null || q <= 0 || c == null) return showInfo(context, 'Quantité ou prix invalide');
    setState(() {
      l.quantity = q;
      l.unitCost = c;
    });
  }

  Future<void> _pickSupplier() async {
    final s = await showModalBottomSheet<Contact>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const FractionallySizedBox(heightFactor: 0.8, child: SupplierPicker()),
    );
    if (s != null && mounted) {
      setState(() {
        _supplier = s;
        _newSupplier = null;
      });
    }
  }

  // ------------------------------------------------------------------ validation

  int get _missing => _lines.where((l) => !l.ready).length;
  List<_Line> get _kept => _lines.where((l) => l.included).toList();

  Future<void> _continue() async {
    final s = _scan!;
    setState(() => _busy = true);
    try {
      var supplier = _supplier;
      if (supplier == null) {
        final name = (_newSupplier ?? '').trim();
        if (name.isEmpty) {
          setState(() => _busy = false);
          await _pickSupplier();
          return;
        }
        final phone = s.supplierPhone == null ? null : localPhone(s.supplierPhone!, ref.read(countryProvider));
        supplier = await ref
            .read(repoProvider)
            .saveCustomer(
              CustomerDraft(name: name, phone: phone),
              type: 'supplier',
              withLimit: false,
            );
        refreshPurchasing(ref);
      }
      final note = [
        if (s.number != null) 'Facture ${s.number}',
        if (s.date != null) 'du ${DateFormat('dd/MM/yyyy').format(s.date!)}',
      ].join(' ');
      if (!mounted) return;
      context.pushReplacement(
        '/purchases/new',
        extra: PurchasePrefill(
          supplier: supplier,
          note: note.isEmpty ? null : note,
          lines: [
            for (final l in _kept)
              PurchaseLineDraft(
                productId: l.productId!,
                name: l.productName!,
                quantity: l.quantity,
                unitCost: l.unitCost,
                unit: l.unit,
                scanLabel: l.label,
              ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showError(context, e);
      }
    }
  }

  // ------------------------------------------------------------------ affichage

  @override
  Widget build(BuildContext context) {
    final appBar = AppBar(
      title: const Text('Facture en photo', style: TextStyle(fontWeight: FontWeight.w800)),
    );
    if (_photo == null) {
      return AuroraScaffold(
        appBar: appBar,
        body: _Message(
          icon: Icons.photo_camera_outlined,
          title: 'Aucune photo',
          text: 'Prenez en photo la facture ou le bon de livraison de votre fournisseur.',
          primary: ('Prendre la photo', _retake),
        ),
      );
    }
    if (_loading) {
      return AuroraScaffold(
        appBar: appBar,
        body: _Reading(photo: _photo!),
      );
    }
    if (_error != null) {
      return AuroraScaffold(
        appBar: appBar,
        body: _Message(
          icon: Icons.cloud_off_rounded,
          title: 'Lecture impossible',
          text: errorMessage(_error!),
          primary: ('Réessayer', _read),
          secondary: ('Saisir l’achat à la main', _manual),
        ),
      );
    }
    final s = _scan;
    if (s == null) return AuroraScaffold(appBar: appBar, body: const SizedBox.shrink());
    if (!s.readable) {
      return AuroraScaffold(
        appBar: appBar,
        body: _Message(
          icon: Icons.blur_on_rounded,
          title: 'Facture illisible',
          text:
              'Posez la facture bien à plat, en pleine lumière, et cadrez-la en entier. '
              'Évitez les reflets et le flou.',
          primary: ('Reprendre la photo', _retake),
          secondary: ('Saisir l’achat à la main', _manual),
        ),
      );
    }

    final kept = _kept;
    final linesTotal = kept.fold<int>(0, (t, l) => t + l.total);
    final recognized = _lines.where((l) => l.included && l.productId != null).length;
    final mismatch = s.total != null && kept.length == _lines.length && (s.total! - linesTotal).abs() > 1;

    return AuroraScaffold(
      appBar: appBar,
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_missing > 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    _missing == 1
                        ? 'Associez la ligne en rouge à un produit (ou ignorez-la)'
                        : 'Associez les $_missing lignes en rouge à un produit (ou ignorez-les)',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: AppColors.danger, fontWeight: FontWeight.w600),
                  ),
                ),
              SizedBox(
                width: double.infinity,
                child: BusyButton(
                  key: const Key('scan_continue'),
                  label: 'Continuer · ${moneyShort(linesTotal)}',
                  icon: Icons.arrow_forward_rounded,
                  busy: _busy,
                  onPressed: _missing > 0 || kept.isEmpty ? null : _continue,
                ),
              ),
            ],
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          _SupplierCard(
            name: _supplier?.name ?? _newSupplier,
            known: _supplier != null,
            number: s.number,
            date: s.date,
            onChange: _pickSupplier,
          ),
          const SizedBox(height: 12),
          Text(
            '${_lines.length} ligne${_lines.length > 1 ? 's' : ''} lue${_lines.length > 1 ? 's' : ''} · '
            '$recognized reconnue${recognized > 1 ? 's' : ''}',
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
          ),
          const SizedBox(height: 8),
          for (final (i, l) in _lines.indexed) ...[
            _LineCard(
              key: Key('scan_line_$i'),
              index: i,
              line: l,
              onPick: () => _pickProduct(l),
              onCreate: () => _createProduct(l),
              onSuggest: (c) => setState(() => l.assign(c.id, c.name, c.unit)),
              onAmounts: () => _editAmounts(l),
              onToggle: () => setState(() => l.included = !l.included),
            ),
            const SizedBox(height: 10),
          ],
          if (mismatch)
            Glass(
              key: const Key('scan_mismatch'),
              radius: 18,
              tint: AppColors.warnBg,
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: AppColors.warn),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Total de la facture : ${moneyShort(s.total!)}, total des lignes : ${moneyShort(linesTotal)}. '
                      'Vérifiez les quantités et les prix (réduction, transport ?).',
                      style: const TextStyle(fontSize: 13.5),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Text(
            'Rien n’est enregistré avant l’étape suivante. '
            'Les produits que vous associez seront reconnus automatiquement sur les prochaines factures de ce fournisseur.',
            style: TextStyle(fontSize: 12.5, color: AppColors.muted),
          ),
        ],
      ),
    );
  }
}

class _Reading extends StatelessWidget {
  const _Reading({required this.photo});
  final PickedPhoto photo;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Image.memory(
              Uint8List.fromList(photo.bytes),
              height: 220,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const SizedBox(height: 220, width: 160),
            ),
          ),
          const SizedBox(height: 24),
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          const Text('Lecture de la facture…', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
          const SizedBox(height: 6),
          Text(
            'Fournisseur, articles, quantités et prix. Cela prend environ 20 secondes.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.muted),
          ),
        ],
      ),
    ),
  );
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.title, required this.text, required this.primary, this.secondary});
  final IconData icon;
  final String title;
  final String text;
  final (String, VoidCallback) primary;
  final (String, VoidCallback)? secondary;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: AppColors.muted),
          const SizedBox(height: 14),
          Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 19)),
          const SizedBox(height: 8),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.muted, height: 1.35),
          ),
          const SizedBox(height: 20),
          FilledButton(onPressed: primary.$2, child: Text(primary.$1)),
          if (secondary != null) TextButton(onPressed: secondary!.$2, child: Text(secondary!.$1)),
        ],
      ),
    ),
  );
}

class _SupplierCard extends StatelessWidget {
  const _SupplierCard({
    required this.name,
    required this.known,
    required this.number,
    required this.date,
    required this.onChange,
  });
  final String? name;
  final bool known;
  final String? number;
  final DateTime? date;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    final details = [
      if (number != null) 'Facture $number',
      if (date != null) DateFormat('dd/MM/yyyy').format(date!),
    ].join(' · ');
    return Glass(
      radius: 20,
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      child: Row(
        children: [
          const GlossyOrb(icon: Icons.local_shipping_rounded, color: Color(0xFF2E90FA), size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name ?? 'Fournisseur non lu',
                  key: const Key('scan_supplier'),
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                ),
                const SizedBox(height: 2),
                Text(
                  name == null
                      ? 'Choisissez le fournisseur'
                      : known
                      ? 'Fournisseur connu${details.isEmpty ? '' : ' · $details'}'
                      : 'Nouveau : sera ajouté${details.isEmpty ? '' : ' · $details'}',
                  style: TextStyle(
                    fontSize: 13,
                    color: known ? AppColors.green : AppColors.warnText,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          TextButton(key: const Key('scan_change_supplier'), onPressed: onChange, child: const Text('Changer')),
        ],
      ),
    );
  }
}

class _LineCard extends StatelessWidget {
  const _LineCard({
    super.key,
    required this.index,
    required this.line,
    required this.onPick,
    required this.onCreate,
    required this.onSuggest,
    required this.onAmounts,
    required this.onToggle,
  });
  final int index;
  final _Line line;
  final VoidCallback onPick;
  final VoidCallback onCreate;
  final ValueChanged<ScanCandidate> onSuggest;
  final VoidCallback onAmounts;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final l = line;
    final (color, icon, status) = switch ((l.productId, l.confidence)) {
      (null, _) => (AppColors.danger, Icons.help_outline_rounded, 'Pas encore dans votre stock'),
      (_, ScanConfidence.memory) => (AppColors.green, Icons.check_circle_rounded, 'Reconnu (déjà associé)'),
      (_, ScanConfidence.low) => (AppColors.warnText, Icons.error_outline_rounded, 'À vérifier'),
      _ => (AppColors.green, Icons.check_circle_rounded, 'Reconnu'),
    };
    final suggestions = l.productId == null ? l.candidates : const <ScanCandidate>[];

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '« ${l.label} »',
                style: TextStyle(fontSize: 12.5, color: AppColors.muted, fontStyle: FontStyle.italic),
              ),
            ),
            IconButton(
              key: Key('scan_toggle_$index'),
              tooltip: l.included ? 'Ignorer cette ligne' : 'Reprendre cette ligne',
              onPressed: onToggle,
              icon: Icon(l.included ? Icons.close_rounded : Icons.undo_rounded, size: 20, color: AppColors.muted),
            ),
          ],
        ),
        if (!l.included)
          Text(
            'Ligne ignorée',
            style: TextStyle(color: AppColors.muted, fontWeight: FontWeight.w700),
          )
        else ...[
          Row(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l.productName ?? status,
                  style: TextStyle(fontWeight: FontWeight.w800, color: l.productId == null ? color : AppColors.ink),
                ),
              ),
            ],
          ),
          if (l.productId != null)
            Padding(
              padding: const EdgeInsets.only(left: 28, top: 2),
              child: Text(
                status,
                style: TextStyle(fontSize: 12.5, color: color, fontWeight: FontWeight.w600),
              ),
            ),
          const SizedBox(height: 8),
          InkWell(
            key: Key('scan_amounts_$index'),
            borderRadius: BorderRadius.circular(10),
            onTap: onAmounts,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Text('${qty(l.quantity)} × ${moneyShort(l.unitCost)}', style: const TextStyle(fontSize: 14.5)),
                  const SizedBox(width: 6),
                  Icon(Icons.edit_rounded, size: 16, color: AppColors.muted),
                  const Spacer(),
                  Text(moneyShort(l.total), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                ],
              ),
            ),
          ),
          if (suggestions.isNotEmpty) ...[
            Text('C’est peut-être :', style: TextStyle(fontSize: 12.5, color: AppColors.muted)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              children: [
                for (final c in suggestions)
                  ActionChip(
                    key: Key('scan_suggest_${index}_${c.id}'),
                    label: Text(c.name),
                    onPressed: () => onSuggest(c),
                  ),
              ],
            ),
            const SizedBox(height: 4),
          ],
          Row(
            children: [
              if (l.productId == null) ...[
                Expanded(
                  child: FilledButton.tonalIcon(
                    key: Key('scan_create_$index'),
                    onPressed: onCreate,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Créer', maxLines: 1),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(key: Key('scan_pick_$index'), onPressed: onPick, child: const Text('Choisir')),
                ),
              ] else
                TextButton.icon(
                  key: Key('scan_pick_$index'),
                  onPressed: onPick,
                  icon: const Icon(Icons.swap_horiz_rounded),
                  label: const Text('Changer de produit'),
                ),
            ],
          ),
        ],
      ],
    );

    return Opacity(
      opacity: l.included ? 1 : 0.55,
      child: Glass(
        radius: 20,
        tint: l.included && l.productId == null ? AppColors.danger.withValues(alpha: 0.06) : null,
        padding: const EdgeInsets.fromLTRB(14, 0, 4, 12),
        child: Padding(padding: const EdgeInsets.only(right: 10), child: content),
      ),
    );
  }
}

/// Création d'un produit à partir d'une ligne de facture (nom et coût déjà remplis).
class _NewProductDialog extends ConsumerStatefulWidget {
  const _NewProductDialog({required this.name, required this.cost});
  final String name;
  final int cost;

  @override
  ConsumerState<_NewProductDialog> createState() => _NewProductDialogState();
}

class _NewProductDialogState extends ConsumerState<_NewProductDialog> {
  late final _name = TextEditingController(text: widget.name);
  late final _cost = TextEditingController(text: '${widget.cost}');
  final _price = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _cost.dispose();
    _price.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final price = int.tryParse(_price.text);
    final cost = int.tryParse(_cost.text) ?? 0;
    if (name.isEmpty) return showInfo(context, 'Donnez un nom au produit');
    if (price == null) return showInfo(context, 'Indiquez le prix de vente');
    setState(() => _busy = true);
    try {
      final p = await ref.read(repoProvider).createProduct(name: name, price: price, cost: cost);
      ref.invalidate(productsProvider);
      if (mounted) Navigator.pop(context, p);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Nouveau produit'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('new_product_name'),
            controller: _name,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Nom dans votre stock'),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('new_product_cost'),
            controller: _cost,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(labelText: 'Prix d’achat', suffixText: 'F'),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('new_product_price'),
            controller: _price,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(labelText: 'Prix de vente', suffixText: 'F'),
          ),
        ],
      ),
    ),
    actions: dialogActions([
      CancelButton(onPressed: () => Navigator.pop(context)),
      ConfirmButton(key: const Key('new_product_save'), label: _busy ? '…' : 'Créer', onPressed: _busy ? null : _save),
    ]),
  );
}
