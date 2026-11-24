import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/display.dart';
import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../sales/receipt_screen.dart' show receiptActionsProvider, whatsAppUri;
import '../catalog/product_photo.dart';
import 'shop_screen.dart' show shopUrl;

// ───────────────────────────────────────────────────────────── logique

/// Prix promo arrondi à 25 F près (ce qu'on rend facilement en monnaie).
int promoPrice(int price, int percent) {
  if (percent <= 0) return price;
  return ((price * (100 - percent) / 100) / 25).round() * 25;
}

/// Lien de commande : la boutique en ligne (produits en vedette), sinon WhatsApp du commerçant.
String? orderLink({required String apiBase, String? shopPath, String? phone, required List<Product> products}) {
  if (shopPath != null) {
    final ids = products.map((p) => p.id).join(',');
    return '${shopUrl(apiBase, shopPath)}${ids.isEmpty ? '' : '?p=$ids'}';
  }
  final digits = phone?.replaceAll(RegExp(r'\D'), '');
  if (digits == null || digits.isEmpty) return null;
  final names = products.map((p) => p.name).join(', ');
  return 'https://wa.me/$digits?text=${Uri.encodeComponent('Bonjour, je veux commander : $names')}';
}

/// Texte qui accompagne l'image (légende du statut / message de groupe).
String statusCaption({
  required String business,
  required String headline,
  required List<Product> products,
  int percent = 0,
  String? link,
}) {
  final lines = [
    '${percent > 0 ? '🔥' : '✨'} $headline chez $business',
    for (final p in products)
      percent > 0
          ? '• ${p.name} : ${_m(promoPrice(p.price, percent))} au lieu de ${_m(p.price)}'
          : '• ${p.name} : ${_m(p.price)}',
    if (link != null) '👉 Commandez ici : $link',
  ];
  return lines.join('\n');
}

String _m(int v) => moneyShort(v).replaceAll(RegExp(r'[  ]'), ' ');

enum StatusTheme {
  vert('Vert', [Color(0xFF0B6E47), Color(0xFF052E24)], Color(0xFF19B56F)),
  nuit('Nuit', [Color(0xFF1B1F3B), Color(0xFF0B0D1A)], Color(0xFFFFB020)),
  soleil('Soleil', [Color(0xFFFF8A00), Color(0xFFD9381E)], Color(0xFFFFE27A)),
  rose('Rose', [Color(0xFFDB2777), Color(0xFF7A1F5C)], Color(0xFFFFD1E6));

  const StatusTheme(this.label, this.colors, this.accent);
  final String label;
  final List<Color> colors;
  final Color accent;
}

const statusHeadlines = ['Promo du jour', 'Nouveauté', 'Disponible', 'Arrivage', 'Prix choc'];

/// Partage de l'image (remplaçable dans les tests).
class StatusActions {
  const StatusActions();
  Future<void> shareImage(Uint8List png, String caption) => SharePlus.instance.share(
    ShareParams(
      files: [XFile.fromData(png, mimeType: 'image/png', name: 'statut.png')],
      fileNameOverrides: const ['statut.png'],
      text: caption,
    ),
  );
}

final statusActionsProvider = Provider<StatusActions>((ref) => const StatusActions());

/// Photo d'un produit en octets (il faut l'avoir avant de dessiner l'image).
final _photoBytesProvider = FutureProvider.autoDispose.family<Uint8List?, String>((ref, fileId) async {
  final b = await ref.watch(repoProvider).fileBytes(fileId);
  return b == null ? null : Uint8List.fromList(b);
});

// ───────────────────────────────────────────────────────────── écran

class StatusScreen extends ConsumerStatefulWidget {
  const StatusScreen({super.key, this.initialIds = const []});
  final List<String> initialIds;

  @override
  ConsumerState<StatusScreen> createState() => _StatusScreenState();
}

class _StatusScreenState extends ConsumerState<StatusScreen> {
  final _boundary = GlobalKey();
  late final Set<String> _ids = {...widget.initialIds};
  String _headline = statusHeadlines.first;
  int _percent = 0;
  StatusTheme _theme = StatusTheme.vert;
  bool _busy = false;

  List<Product> _selected(List<Product> all) => [for (final id in _ids) ...all.where((p) => p.id == id)];

  Future<Uint8List> _capture() async {
    await WidgetsBinding.instance.endOfFrame;
    final ro = _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await ro.toImage(pixelRatio: 3); // 360 × 640 → 1080 × 1920
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  Future<void> _share(String caption) async {
    setState(() => _busy = true);
    try {
      final png = await _capture();
      await ref.read(statusActionsProvider).shareImage(png, caption);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pick(List<Product> all) async {
    final chosen = await showModalBottomSheet<Set<String>>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => _ProductPicker(products: all, initial: _ids),
    );
    if (chosen != null) {
      setState(() {
        _ids
          ..clear()
          ..addAll(chosen);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final products = ref.watch(catalogProductsProvider);
    final business = ref.watch(currentBusinessProvider);
    final shop = ref.watch(shopProvider);
    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Statut WhatsApp', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: AsyncView<List<Product>>(
        value: products,
        onRetry: () => ref.invalidate(productsProvider),
        data: (all) {
          final sel = _selected(all);
          final b = business.value;
          final shopPath = shop.value?.settings.enabled == true ? shop.value!.path : null;
          final link = orderLink(
            apiBase: ref.watch(apiBaseUrlProvider),
            shopPath: shopPath,
            phone: b?.phone,
            products: sel,
          );
          final caption = statusCaption(
            business: b?.name ?? '',
            headline: _headline,
            products: sel,
            percent: _percent,
            link: link,
          );
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
            children: [
              Glass(
                key: const Key('status_pick'),
                radius: 18,
                onTap: () => _pick(all),
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Icon(Icons.inventory_2_rounded, color: AppColors.green),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        sel.isEmpty ? 'Choisir les produits (1 à 4)' : sel.map((p) => p.name).join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    Icon(Icons.chevron_right_rounded, color: AppColors.muted),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _Label('Titre'),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final h in statusHeadlines)
                    Pill(label: h, selected: _headline == h, onTap: () => setState(() => _headline = h)),
                ],
              ),
              const SizedBox(height: 12),
              _Label('Réduction'),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final p in const [0, 10, 15, 20, 30, 50])
                    Pill(
                      label: p == 0 ? 'Aucune' : '-$p %',
                      selected: _percent == p,
                      onTap: () => setState(() => _percent = p),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              _Label('Couleurs'),
              Row(
                children: [
                  for (final t in StatusTheme.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Semantics(
                        button: true,
                        selected: _theme == t,
                        label: 'Couleurs ${t.label}',
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => setState(() => _theme = t),
                          child: SizedBox(
                            width: 48,
                            height: 48,
                            child: Center(
                              child: Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: LinearGradient(colors: t.colors),
                                  border: Border.all(color: _theme == t ? AppColors.ink : Colors.transparent, width: 3),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              if (sel.isEmpty)
                Glass(
                  radius: 22,
                  padding: const EdgeInsets.all(22),
                  child: Text(
                    'Choisissez un ou plusieurs produits : l’image se crée toute seule, prête pour votre statut '
                    'ou vos groupes WhatsApp.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.muted),
                  ),
                )
              else ...[
                Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: SizedBox(
                      width: 270,
                      height: 480,
                      child: FittedBox(
                        child: RepaintBoundary(
                          key: _boundary,
                          child: StatusCard(
                            business: b,
                            headline: _headline,
                            products: sel,
                            percent: _percent,
                            theme: _theme,
                            link: link,
                            brand: ref.watch(brandColorProvider),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  height: 52,
                  child: BusyButton(
                    key: const Key('status_share'),
                    icon: Icons.ios_share_rounded,
                    label: 'Partager en statut',
                    busy: _busy,
                    onPressed: () => _share(caption),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const Key('status_text'),
                        onPressed: () => ref.read(receiptActionsProvider).openWhatsApp(whatsAppUri(caption)),
                        icon: const Icon(Icons.chat_rounded),
                        label: const Text('Texte seul'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const Key('status_copy'),
                        onPressed: link == null
                            ? null
                            : () async {
                                await Clipboard.setData(ClipboardData(text: link));
                                if (context.mounted) showInfo(context, 'Lien copié');
                              },
                        icon: const Icon(Icons.link_rounded),
                        label: const Text('Copier le lien'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  shopPath != null
                      ? 'Vos clients ouvrent la boutique en ligne avec ces produits en vedette.'
                      : 'Votre boutique en ligne est fermée : le lien ouvre WhatsApp vers votre numéro.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.muted, fontSize: 13),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(2, 0, 2, 6),
    child: Text(text, style: const TextStyle(fontWeight: FontWeight.w800)),
  );
}

class _ProductPicker extends StatefulWidget {
  const _ProductPicker({required this.products, required this.initial});
  final List<Product> products;
  final Set<String> initial;
  @override
  State<_ProductPicker> createState() => _ProductPickerState();
}

class _ProductPickerState extends State<_ProductPicker> {
  late final Set<String> _sel = {...widget.initial};
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final items = widget.products.where((p) => _q.isEmpty || p.name.toLowerCase().contains(_q.toLowerCase())).toList();
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search_rounded), hintText: 'Rechercher'),
                onChanged: (v) => setState(() => _q = v),
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  for (final p in items)
                    CheckboxListTile(
                      key: Key('pick_${p.id}'),
                      value: _sel.contains(p.id),
                      secondary: ProductThumb(name: p.name, fileId: p.imageFileId, size: 48),
                      title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text(
                        moneyShort(p.price),
                        style: TextStyle(color: AppColors.green, fontWeight: FontWeight.w800),
                      ),
                      onChanged: (v) => setState(() {
                        if (v == true) {
                          if (_sel.length < 4) _sel.add(p.id);
                        } else {
                          _sel.remove(p.id);
                        }
                      }),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: SizedBox(
                width: double.infinity,
                height: 50,
                child: FilledButton(
                  key: const Key('pick_done'),
                  onPressed: () => Navigator.pop(context, _sel),
                  child: Text(_sel.isEmpty ? 'Fermer' : 'Valider (${_sel.length}/4)'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────── image 9:16

/// L'image du statut, dessinée en 360 × 640 et capturée en 1080 × 1920.
class StatusCard extends ConsumerWidget {
  const StatusCard({
    super.key,
    required this.business,
    required this.headline,
    required this.products,
    required this.theme,
    required this.brand,
    this.percent = 0,
    this.link,
  });

  final CurrentBusiness? business;
  final String headline;
  final List<Product> products;
  final StatusTheme theme;
  final Color brand;
  final int percent;
  final String? link;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logo = business?.logoFileId == null ? null : ref.watch(_photoBytesProvider(business!.logoFileId!)).value;
    final name = business?.name ?? '';
    return MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.noScaling),
      child: DefaultTextStyle(
        style: const TextStyle(color: Colors.white, fontFamily: 'Roboto', decoration: TextDecoration.none),
        child: Container(
          width: 360,
          height: 640,
          decoration: BoxDecoration(
            gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: theme.colors),
          ),
          padding: const EdgeInsets.fromLTRB(22, 28, 22, 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    clipBehavior: Clip.antiAlias,
                    decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                    alignment: Alignment.center,
                    child: logo != null
                        ? Image.memory(logo, fit: BoxFit.cover, width: 42, height: 42)
                        : Text(
                            productInitials(name),
                            style: TextStyle(color: theme.colors.first, fontWeight: FontWeight.w900, fontSize: 16),
                          ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(color: theme.accent, borderRadius: BorderRadius.circular(999)),
                    child: Text(
                      headline.toUpperCase(),
                      style: TextStyle(
                        color: theme.colors.last,
                        fontWeight: FontWeight.w900,
                        fontSize: 13,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                  if (percent > 0) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(999)),
                      child: Text(
                        '-$percent %',
                        style: const TextStyle(color: Color(0xFFD9381E), fontWeight: FontWeight.w900, fontSize: 13),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: products.length == 1
                    ? _Single(product: products.single, percent: percent, accent: theme.accent)
                    : _Grid(products: products, percent: percent, accent: theme.accent),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)),
                child: Row(
                  children: [
                    if (link != null)
                      QrImageView(
                        data: link!,
                        size: 74,
                        padding: EdgeInsets.zero,
                        eyeStyle: QrEyeStyle(eyeShape: QrEyeShape.square, color: theme.colors.last),
                        dataModuleStyle: QrDataModuleStyle(
                          dataModuleShape: QrDataModuleShape.square,
                          color: theme.colors.last,
                        ),
                      ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Commandez maintenant',
                            style: TextStyle(color: theme.colors.last, fontWeight: FontWeight.w900, fontSize: 16),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            link == null ? 'Écrivez-nous sur WhatsApp' : 'Scannez ou touchez le lien du statut',
                            style: const TextStyle(color: Color(0xFF5E6E66), fontSize: 12.5),
                          ),
                          if ((business?.phone ?? '').isNotEmpty) ...[
                            const SizedBox(height: 3),
                            Row(
                              children: [
                                const Icon(Icons.phone_rounded, size: 14, color: Color(0xFF13241C)),
                                const SizedBox(width: 4),
                                Text(
                                  business!.phone!,
                                  style: const TextStyle(
                                    color: Color(0xFF13241C),
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Photo extends ConsumerWidget {
  const _Photo({required this.product, required this.radius});
  final Product product;
  final double radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = product.imageFileId == null ? null : ref.watch(_photoBytesProvider(product.imageFileId!)).value;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Container(
        color: Colors.white.withValues(alpha: 0.16),
        alignment: Alignment.center,
        child: bytes != null
            ? Image.memory(bytes, fit: BoxFit.cover, width: double.infinity, height: double.infinity)
            : Text(
                productInitials(product.name),
                style: const TextStyle(fontSize: 54, fontWeight: FontWeight.w900, color: Colors.white),
              ),
      ),
    );
  }
}

class _Price extends StatelessWidget {
  const _Price({required this.price, required this.percent, required this.accent, required this.size});
  final int price;
  final int percent;
  final Color accent;
  final double size;

  @override
  Widget build(BuildContext context) => Wrap(
    crossAxisAlignment: WrapCrossAlignment.end,
    spacing: 8,
    children: [
      Text(
        _m(promoPrice(price, percent)),
        style: TextStyle(fontSize: size, fontWeight: FontWeight.w900, color: accent, height: 1.05),
      ),
      if (percent > 0)
        Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Text(
            _m(price),
            style: TextStyle(
              fontSize: size * 0.45,
              color: Colors.white.withValues(alpha: 0.75),
              decoration: TextDecoration.lineThrough,
              decorationColor: Colors.white,
            ),
          ),
        ),
    ],
  );
}

class _Single extends StatelessWidget {
  const _Single({required this.product, required this.percent, required this.accent});
  final Product product;
  final int percent;
  final Color accent;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(child: _Photo(product: product, radius: 24)),
      const SizedBox(height: 14),
      Text(
        product.name,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, height: 1.1),
      ),
      const SizedBox(height: 4),
      _Price(price: product.price, percent: percent, accent: accent, size: 34),
    ],
  );
}

class _Grid extends StatelessWidget {
  const _Grid({required this.products, required this.percent, required this.accent});
  final List<Product> products;
  final int percent;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    Widget tile(Product p) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: _Photo(product: p, radius: 18)),
        const SizedBox(height: 6),
        Text(
          p.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
        ),
        _Price(price: p.price, percent: percent, accent: accent, size: 18),
      ],
    );
    final rows = [
      for (var i = 0; i < products.length; i += 2)
        products.sublist(i, i + 2 > products.length ? products.length : i + 2),
    ];
    return Column(
      children: [
        for (final (i, row) in rows.indexed) ...[
          if (i > 0) const SizedBox(height: 12),
          Expanded(
            child: Row(
              children: [
                for (final (j, p) in row.indexed) ...[if (j > 0) const SizedBox(width: 12), Expanded(child: tile(p))],
                if (row.length == 1 && products.length > 2) ...[const SizedBox(width: 12), const Spacer()],
              ],
            ),
          ),
        ],
      ],
    );
  }
}
