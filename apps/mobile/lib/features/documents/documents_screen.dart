import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:material_ui/material_ui.dart';

import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../auth/pin_screen.dart' show confirmSensitive;
import '../catalog/product_photo.dart' show PickedPhoto;
import '../sales/receipt_screen.dart' show receiptActionsProvider;

// ---------- Choix du fichier ----------

enum DocSource { camera, gallery, pdf }

/// Choix du fichier (remplaçable dans les tests). Photos de papiers : plus grandes que celles des
/// produits (2000 px) pour que le texte reste lisible.
typedef DocFilePicker = Future<PickedPhoto?> Function(DocSource source);

final docFilePickerProvider = Provider<DocFilePicker>((ref) {
  final images = ImagePicker();
  return (source) async {
    if (source == DocSource.pdf) {
      final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['pdf']);
      if (files.isEmpty) return null;
      return PickedPhoto(await files.first.readAsBytes(), files.first.name);
    }
    final file = await images.pickImage(
      source: source == DocSource.camera ? ImageSource.camera : ImageSource.gallery,
      maxWidth: 2000,
      maxHeight: 2000,
      imageQuality: 85,
    );
    if (file == null) return null;
    return PickedPhoto(await file.readAsBytes(), file.name.isEmpty ? 'document.jpg' : file.name);
  };
});

// ---------- Petits textes ----------

/// « 12 mai 2027 » : les échéances et dates d'ajout peuvent être sur une autre année.
String docDate(DateTime d) => DateFormat('d MMM y', 'fr').format(d);

IconData docCategoryIcon(DocCategory c) => switch (c) {
  DocCategory.admin => Icons.account_balance_rounded,
  DocCategory.supplierInvoice => Icons.receipt_long_rounded,
  DocCategory.contract => Icons.handshake_rounded,
  DocCategory.delivery => Icons.local_shipping_rounded,
  DocCategory.receipt => Icons.bolt_rounded,
  DocCategory.other => Icons.folder_rounded,
};

Color docCategoryColor(DocCategory c) => switch (c) {
  DocCategory.admin => const Color(0xFF2F6FDB),
  DocCategory.supplierInvoice => const Color(0xFF8A5A2B),
  DocCategory.contract => const Color(0xFF7A5AF8),
  DocCategory.delivery => const Color(0xFFD9822B),
  DocCategory.receipt => const Color(0xFF0E9384),
  DocCategory.other => const Color(0xFF6B7280),
};

/// « Expire dans 10 j », « Expire aujourd’hui », « Expiré depuis 3 j », ou « Expire le 12/05/2027 ».
String? expiryLabel(BusinessDocument d) {
  final n = d.expiresInDays;
  if (n == null || d.expiresOn == null) return null;
  if (n < 0) return 'Expiré depuis ${-n} j';
  if (n == 0) return 'Expire aujourd’hui';
  if (n <= 30) return 'Expire dans $n j';
  return 'Expire le ${docDate(d.expiresOn!)}';
}

/// « 245 Ko », « 1,8 Mo ».
String fileSizeLabel(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).ceil()} Ko';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1).replaceAll('.', ',')} Mo';
}

/// Titre proposé à partir du nom de fichier : « bail_boutique.pdf » → « Bail boutique ».
String titleFromFilename(String name) {
  final base = name.replaceAll(RegExp(r'\.[A-Za-z0-9]{2,4}$'), '').replaceAll(RegExp(r'[_\-]+'), ' ').trim();
  if (base.isEmpty || RegExp(r'^(IMG|image|scan|photo|document)?[ \d]*$', caseSensitive: false).hasMatch(base)) {
    return '';
  }
  return base[0].toUpperCase() + base.substring(1);
}

// ---------- Liste ----------

class DocumentsScreen extends ConsumerStatefulWidget {
  const DocumentsScreen({super.key});

  @override
  ConsumerState<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends ConsumerState<DocumentsScreen> {
  DocCategory? _category;
  String _search = '';

  ({DocCategory? category, String search}) get _query => (category: _category, search: _search);

  Future<void> _add() async {
    final source = await showModalBottomSheet<DocSource>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('Ajouter un document', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_rounded),
              title: const Text('Photographier un papier'),
              subtitle: const Text('Facture, reçu, bon de livraison…'),
              onTap: () => Navigator.pop(ctx, DocSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_rounded),
              title: const Text('Choisir une photo'),
              onTap: () => Navigator.pop(ctx, DocSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.picture_as_pdf_rounded),
              title: const Text('Choisir un PDF'),
              onTap: () => Navigator.pop(ctx, DocSource.pdf),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;
    final PickedPhoto? file;
    try {
      file = await ref.read(docFilePickerProvider)(source);
    } catch (e) {
      if (mounted) showError(context, 'Impossible d’ouvrir le fichier');
      return;
    }
    if (file == null || !mounted) return;
    await context.push('/documents/new', extra: file);
  }

  @override
  Widget build(BuildContext context) {
    final docs = ref.watch(storedDocumentsProvider(_query));
    final all = ref.watch(storedDocumentsProvider((category: null, search: ''))).value;
    final canWrite = ref.can('documents:write');
    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Documents', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      floatingActionButton: canWrite
          ? FloatingActionButton.extended(
              key: const Key('add_document'),
              onPressed: _add,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Ajouter'),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(storedDocumentsProvider);
          await ref.read(storedDocumentsProvider(_query).future);
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
          children: [
            if (all != null && all.attention > 0) ...[
              _AttentionBanner(count: all.attention),
              const SizedBox(height: 12),
            ],
            Glass(
              radius: 18,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: TextField(
                key: const Key('documents_search'),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                  icon: Icon(Icons.search_rounded),
                  hintText: 'Rechercher un document',
                ),
                onChanged: (v) => setState(() => _search = v.trim()),
              ),
            ),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Pill(
                      label: all == null ? 'Tous' : 'Tous · ${all.total}',
                      selected: _category == null,
                      onTap: () => setState(() => _category = null),
                    ),
                  ),
                  for (final c in DocCategory.values)
                    if ((all?.counts[c] ?? 0) > 0 || _category == c)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Pill(
                          label: '${c.label} · ${all?.counts[c] ?? 0}',
                          selected: _category == c,
                          onTap: () => setState(() => _category = c),
                        ),
                      ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            AsyncView<DocumentList>(
              value: docs,
              onRetry: () => ref.invalidate(storedDocumentsProvider(_query)),
              data: (l) {
                if (l.items.isEmpty) {
                  return _search.isNotEmpty || _category != null
                      ? Padding(
                          padding: const EdgeInsets.only(top: 40),
                          child: Text(
                            'Aucun document ne correspond',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppColors.muted),
                          ),
                        )
                      : _EmptyDocuments(canWrite: canWrite, onAdd: _add);
                }
                return Column(children: [for (final d in l.items) _DocumentTile(doc: d)]);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _AttentionBanner extends StatelessWidget {
  const _AttentionBanner({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) => Material(
    color: AppColors.warnBg,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: BorderSide(color: AppColors.warnLine),
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        children: [
          Icon(Icons.event_busy_rounded, color: AppColors.warn),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              count == 1
                  ? '1 document arrive à échéance : pensez à le renouveler'
                  : '$count documents arrivent à échéance : pensez à les renouveler',
              key: const Key('documents_attention'),
              style: TextStyle(color: AppColors.warnText, fontWeight: FontWeight.w700, fontSize: 13),
            ),
          ),
        ],
      ),
    ),
  );
}

class _EmptyDocuments extends StatelessWidget {
  const _EmptyDocuments({required this.canWrite, required this.onAdd});
  final bool canWrite;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => Glass(
    radius: 24,
    padding: const EdgeInsets.fromLTRB(18, 22, 18, 18),
    child: Column(
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: AppColors.green.withValues(alpha: 0.12), shape: BoxShape.circle),
          child: Icon(Icons.folder_copy_rounded, size: 34, color: AppColors.green),
        ),
        const SizedBox(height: 12),
        const Text('Rangez vos papiers ici', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text(
          'Registre de commerce, NINEA, factures fournisseurs, bail, reçus… '
          'Toujours sur vous, même si le papier se perd. Sama360 vous prévient avant les échéances.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.muted, height: 1.35),
        ),
        if (canWrite) ...[
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.photo_camera_rounded),
            label: const Text('Ajouter mon premier document'),
          ),
        ],
      ],
    ),
  );
}

class _DocumentTile extends StatelessWidget {
  const _DocumentTile({required this.doc});
  final BusinessDocument doc;

  @override
  Widget build(BuildContext context) {
    final d = doc;
    final color = docCategoryColor(d.category);
    final expiry = expiryLabel(d);
    final warn = d.expiry != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Glass(
        radius: 18,
        onTap: () => context.push('/documents/${d.id}'),
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(color: color.withValues(alpha: 0.13), borderRadius: BorderRadius.circular(14)),
              child: Icon(d.isPdf ? Icons.picture_as_pdf_rounded : docCategoryIcon(d.category), color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    d.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  Text(
                    '${d.category.label} · ${docDate(d.createdAt)}',
                    style: TextStyle(color: AppColors.muted, fontSize: 12.5),
                  ),
                  if (expiry != null)
                    Text(
                      expiry,
                      style: TextStyle(
                        color: d.expiry == 'expired' ? AppColors.danger : (warn ? AppColors.warnText : AppColors.muted),
                        fontWeight: warn ? FontWeight.w800 : FontWeight.w500,
                        fontSize: 12.5,
                      ),
                    ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: AppColors.muted),
          ],
        ),
      ),
    );
  }
}

// ---------- Ajout et modification ----------

class StoredDocumentEditorScreen extends ConsumerStatefulWidget {
  /// [file] : nouveau document ; [documentId] : modification d'un document existant.
  const StoredDocumentEditorScreen({super.key, this.file, this.documentId});
  final PickedPhoto? file;
  final String? documentId;

  @override
  ConsumerState<StoredDocumentEditorScreen> createState() => _StoredDocumentEditorScreenState();
}

class _StoredDocumentEditorScreenState extends ConsumerState<StoredDocumentEditorScreen> {
  final _title = TextEditingController();
  final _note = TextEditingController();
  DocCategory _category = DocCategory.other;
  DateTime? _expires;
  bool _busy = false;
  bool _loaded = false;

  bool get _isNew => widget.documentId == null;

  @override
  void initState() {
    super.initState();
    if (widget.file != null) _title.text = titleFromFilename(widget.file!.filename);
  }

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  void _fill(BusinessDocument d) {
    if (_loaded) return;
    _loaded = true;
    _title.text = d.title;
    _note.text = d.note ?? '';
    _category = d.category;
    _expires = d.expiresOn;
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _expires ?? DateTime(now.year + 1, now.month, now.day),
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 30),
      helpText: 'Date d’échéance',
    );
    if (d != null) setState(() => _expires = d);
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.length < 2) return showInfo(context, 'Donnez un nom au document');
    setState(() => _busy = true);
    final repo = ref.read(repoProvider);
    try {
      if (_isNew) {
        final f = widget.file!;
        final d = await repo.uploadStoredDocument(
          bytes: f.bytes,
          filename: f.filename,
          title: title,
          category: _category,
          note: _note.text.trim(),
          expiresOn: _expires,
        );
        refreshStoredDocuments(ref);
        if (!mounted) return;
        showInfo(context, 'Document rangé');
        context.pushReplacement('/documents/${d.id}');
      } else {
        await repo.updateStoredDocument(
          widget.documentId!,
          title: title,
          category: _category,
          note: _note.text,
          expiresOn: _expires,
        );
        refreshStoredDocuments(ref);
        if (!mounted) return;
        showInfo(context, 'Document modifié');
        context.pop();
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
    if (!_isNew) {
      final doc = ref.watch(storedDocumentProvider(widget.documentId!));
      if (doc.value != null) _fill(doc.value!);
      if (!doc.hasValue) {
        return AuroraScaffold(
          appBar: AppBar(title: const Text('Modifier')),
          body: AsyncView<BusinessDocument>(
            value: doc,
            onRetry: () => ref.invalidate(storedDocumentProvider(widget.documentId!)),
            data: (_) => const SizedBox.shrink(),
          ),
        );
      }
    }
    final f = widget.file;
    final isPdf = f != null && f.bytes.length > 4 && String.fromCharCodes(f.bytes.take(4)) == '%PDF';
    return AuroraScaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'Nouveau document' : 'Modifier', style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        children: [
          if (f != null) ...[
            Glass(
              radius: 20,
              padding: const EdgeInsets.all(10),
              child: isPdf
                  ? Row(
                      children: [
                        Icon(Icons.picture_as_pdf_rounded, size: 36, color: AppColors.danger),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            f.filename,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        Text(fileSizeLabel(f.bytes.length), style: TextStyle(color: AppColors.muted)),
                      ],
                    )
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 220),
                        child: Image.memory(
                          Uint8List.fromList(f.bytes),
                          fit: BoxFit.contain,
                          errorBuilder: (_, _, _) => const SizedBox(height: 80, child: Icon(Icons.image_rounded)),
                        ),
                      ),
                    ),
            ),
            const SizedBox(height: 14),
          ],
          TextField(
            key: const Key('doc_title'),
            controller: _title,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Nom du document', hintText: 'Ex. Bail boutique Sandaga'),
          ),
          const SizedBox(height: 16),
          Text(
            'Catégorie',
            style: TextStyle(color: AppColors.muted, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final c in DocCategory.values)
                Pill(label: c.label, selected: _category == c, onTap: () => setState(() => _category = c)),
            ],
          ),
          const SizedBox(height: 4),
          Text(_category.hint, style: TextStyle(color: AppColors.muted, fontSize: 12)),
          const SizedBox(height: 16),
          Glass(
            radius: 18,
            onTap: _pickDate,
            padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
            child: Row(
              children: [
                Icon(Icons.event_rounded, color: AppColors.green),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Date d’échéance', style: TextStyle(fontWeight: FontWeight.w700)),
                      Text(
                        _expires == null
                            ? 'Facultatif : bail, assurance, autorisation… (rappel 30 jours avant)'
                            : docDate(_expires!),
                        key: const Key('doc_expiry'),
                        style: TextStyle(color: AppColors.muted, fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
                if (_expires != null)
                  IconButton(
                    tooltip: 'Retirer la date',
                    onPressed: () => setState(() => _expires = null),
                    icon: const Icon(Icons.close_rounded),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('doc_note'),
            controller: _note,
            minLines: 2,
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Note (facultatif)'),
          ),
          const SizedBox(height: 22),
          SizedBox(
            height: 52,
            child: BusyButton(
              icon: Icons.check_rounded,
              label: _isNew ? 'Ranger le document' : 'Enregistrer',
              busy: _busy,
              onPressed: _save,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------- Fiche d'un document ----------

class StoredDocumentScreen extends ConsumerStatefulWidget {
  const StoredDocumentScreen({super.key, required this.id});
  final String id;

  @override
  ConsumerState<StoredDocumentScreen> createState() => _StoredDocumentScreenState();
}

class _StoredDocumentScreenState extends ConsumerState<StoredDocumentScreen> {
  bool _busy = false;

  Future<void> _share(BusinessDocument d) async {
    setState(() => _busy = true);
    try {
      final bytes = await ref.read(storedDocumentBytesProvider(d.id).future);
      final ext = d.isPdf ? 'pdf' : (d.mime == 'image/png' ? 'png' : 'jpg');
      await ref.read(receiptActionsProvider).sharePdf(bytes, '${d.title}.$ext');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _print(BusinessDocument d) async {
    setState(() => _busy = true);
    try {
      final bytes = await ref.read(storedDocumentBytesProvider(d.id).future);
      await ref.read(receiptActionsProvider).printPdf(bytes, d.title);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(BusinessDocument d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer ce document ?'),
        content: Text('« ${d.title} » sera supprimé définitivement, fichier compris.'),
        actions: dialogActions([
          CancelButton(onPressed: () => Navigator.pop(ctx, false)),
          ConfirmButton(danger: true, label: 'Supprimer', onPressed: () => Navigator.pop(ctx, true)),
        ]),
      ),
    );
    if (ok != true || !mounted) return;
    if (!await confirmSensitive(context, ref, action: 'Supprimer « ${d.title} »')) return;
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(repoProvider).deleteStoredDocument(d.id);
      refreshStoredDocuments(ref);
      if (!mounted) return;
      showInfo(context, 'Document supprimé');
      context.pop();
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final doc = ref.watch(storedDocumentProvider(widget.id));
    final canWrite = ref.can('documents:write');
    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Document', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          if (canWrite && doc.value != null) ...[
            IconButton(
              tooltip: 'Modifier',
              onPressed: () => context.push('/documents/${widget.id}/edit'),
              icon: const Icon(Icons.edit_rounded),
            ),
            TrashButton(tooltip: 'Supprimer', onPressed: _busy ? null : () => _delete(doc.value!)),
          ],
        ],
      ),
      body: AsyncView<BusinessDocument>(
        value: doc,
        onRetry: () => ref.invalidate(storedDocumentProvider(widget.id)),
        data: (d) {
          final color = docCategoryColor(d.category);
          final expiry = expiryLabel(d);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
            children: [
              _Preview(doc: d),
              const SizedBox(height: 14),
              Glass(
                radius: 20,
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(d.title, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        _Chip(icon: docCategoryIcon(d.category), text: d.category.label, color: color),
                        _Chip(
                          icon: d.isPdf ? Icons.picture_as_pdf_rounded : Icons.image_rounded,
                          text: '${d.isPdf ? 'PDF' : 'Photo'} · ${fileSizeLabel(d.size)}',
                          color: AppColors.muted,
                        ),
                        if (expiry != null)
                          _Chip(
                            icon: Icons.event_rounded,
                            text: expiry,
                            color: d.expiry == 'expired'
                                ? AppColors.danger
                                : (d.expiry == 'soon' ? AppColors.warn : AppColors.green),
                          ),
                      ],
                    ),
                    if ((d.note ?? '').isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(d.note!, style: const TextStyle(height: 1.35)),
                    ],
                    const SizedBox(height: 12),
                    Text(
                      'Ajouté le ${docDate(d.createdAt)}${d.createdByName == null ? '' : ' par ${d.createdByName}'}',
                      style: TextStyle(color: AppColors.muted, fontSize: 12.5),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : () => _share(d),
                      icon: const Icon(Icons.ios_share_rounded),
                      label: const Text('Partager'),
                    ),
                  ),
                  if (d.isPdf) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : () => _print(d),
                        icon: const Icon(Icons.print_rounded),
                        label: const Text('Imprimer'),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.text, required this.color});
  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 5),
        Text(
          text,
          style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12.5),
        ),
      ],
    ),
  );
}

/// Aperçu : la photo elle-même, ou une carte PDF (à ouvrir avec « Partager » ou « Imprimer »).
class _Preview extends ConsumerWidget {
  const _Preview({required this.doc});
  final BusinessDocument doc;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (doc.isPdf) {
      return Glass(
        radius: 22,
        padding: const EdgeInsets.symmetric(vertical: 28),
        child: Column(
          children: [
            Icon(Icons.picture_as_pdf_rounded, size: 64, color: AppColors.danger),
            const SizedBox(height: 8),
            Text(
              'Document PDF',
              style: TextStyle(color: AppColors.muted, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      );
    }
    final bytes = ref.watch(storedDocumentBytesProvider(doc.id));
    return Glass(
      radius: 22,
      padding: const EdgeInsets.all(8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: bytes.when(
          data: (b) => GestureDetector(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  backgroundColor: Colors.black,
                  appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white, title: Text(doc.title)),
                  body: InteractiveViewer(maxScale: 5, child: Center(child: Image.memory(Uint8List.fromList(b)))),
                ),
              ),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: Image.memory(
                Uint8List.fromList(b),
                key: const Key('document_image'),
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const SizedBox(height: 120, child: Icon(Icons.broken_image_rounded)),
              ),
            ),
          ),
          loading: () => const SizedBox(height: 200, child: Center(child: CircularProgressIndicator())),
          error: (_, _) => SizedBox(
            height: 120,
            child: Center(
              child: Text('Aperçu indisponible', style: TextStyle(color: AppColors.muted)),
            ),
          ),
        ),
      ),
    );
  }
}
