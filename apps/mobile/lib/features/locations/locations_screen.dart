import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uuid/uuid.dart';

import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../purchasing/purchase_editor.dart' show ProductPicker;

/// Après un changement de point de vente ou un transfert : chiffres, stock et listes à jour.
void refreshLocations(WidgetRef ref) {
  ref.invalidate(locationsProvider);
  ref.invalidate(stockRawProvider);
  ref.invalidate(summaryProvider);
}

/// Pastille de l'accueil « point de vente » : visible dès qu'il y en a plusieurs.
class LocationChip extends ConsumerWidget {
  const LocationChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(locationsProvider).value;
    if (s == null || (!s.several && !s.locked)) return const SizedBox.shrink();
    final label = s.locked ? s.nameOf(s.writeTo) : (s.current?.name ?? 'Tous les points de vente');
    return Align(
      alignment: Alignment.centerLeft,
      child: TapTarget(
        onTap: s.locked ? null : () => pickLocation(context, ref),
        child: Glass(
          key: const Key('location_chip'),
          tone: GlassTone.dark,
          radius: 30,
          blur: 12,
          shadow: false,
          onTap: s.locked ? null : () => pickLocation(context, ref),
          padding: const EdgeInsets.fromLTRB(12, 6, 10, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                s.current == null && !s.locked ? Icons.hub_rounded : Icons.place_rounded,
                size: 16,
                color: AppColors.glow,
              ),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13.5),
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                s.locked ? Icons.lock_rounded : Icons.expand_more_rounded,
                size: s.locked ? 14 : 18,
                color: Colors.white70,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Choix du point de vente regardé : un seul, ou tous (chiffres additionnés).
Future<void> pickLocation(BuildContext context, WidgetRef ref) async {
  final s = await ref.read(locationsProvider.future);
  if (!context.mounted) return;
  final canManage = ref.read(canProvider('business:update'));
  final picked = await showModalBottomSheet<String>(
    useRootNavigator: true,
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Point de vente', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
            const SizedBox(height: 4),
            Text(
              'Les chiffres, le stock et la caisse suivent le point de vente choisi.',
              style: TextStyle(color: AppColors.muted, fontSize: 13),
            ),
            const SizedBox(height: 12),
            _PickTile(
              key: const Key('pick_location_all'),
              icon: Icons.hub_rounded,
              title: 'Tous les points de vente',
              subtitle: 'Chiffres et stock additionnés',
              selected: s.currentId == null,
              onTap: () => Navigator.pop(ctx, ''),
            ),
            for (final l in s.list)
              _PickTile(
                key: Key('pick_location_${l.id}'),
                icon: Icons.place_rounded,
                title: l.name,
                subtitle: [if (l.isDefault) 'Principal', 'Aujourd’hui ${moneyShort(l.todayRevenue)}'].join(' · '),
                selected: s.currentId == l.id,
                onTap: () => Navigator.pop(ctx, l.id),
              ),
            if (canManage) ...[
              const SizedBox(height: 4),
              TextButton.icon(
                onPressed: () => Navigator.pop(ctx, '#manage'),
                icon: const Icon(Icons.settings_rounded),
                label: const Text('Gérer les points de vente'),
              ),
            ],
          ],
        ),
      ),
    ),
  );
  if (picked == null || !context.mounted) return;
  if (picked == '#manage') {
    context.push('/locations');
    return;
  }
  await ref.read(locationIdProvider.notifier).select(picked.isEmpty ? null : picked);
}

class _PickTile extends StatelessWidget {
  const _PickTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Glass(
      radius: 18,
      onTap: onTap,
      tint: selected ? AppColors.green.withValues(alpha: 0.10) : null,
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      child: Row(
        children: [
          Icon(icon, color: selected ? AppColors.green : AppColors.muted),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
                Text(subtitle, style: TextStyle(fontSize: 12.5, color: AppColors.muted)),
              ],
            ),
          ),
          if (selected) Icon(Icons.check_circle_rounded, color: AppColors.green),
        ],
      ),
    ),
  );
}

/// Bandeau : où va la vente, la dépense ou le remboursement (quand il y a plusieurs points de vente).
class SellingAtBanner extends ConsumerWidget {
  const SellingAtBanner({super.key, this.prefix = 'Vente à '});

  /// « Vente à », « Dépense de », « Encaissé à »…
  final String prefix;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(locationsProvider).value;
    if (s == null || !s.several) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(Icons.place_rounded, size: 16, color: AppColors.muted),
          const SizedBox(width: 6),
          Expanded(
            child: Text.rich(
              key: const Key('selling_at'),
              TextSpan(
                text: prefix,
                children: [
                  TextSpan(
                    text: s.nameOf(s.writeTo),
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ],
              ),
              style: TextStyle(fontSize: 13.5, color: AppColors.muted),
            ),
          ),
          if (!s.locked) TextButton(onPressed: () => pickLocation(context, ref), child: const Text('Changer')),
        ],
      ),
    );
  }
}

/// Accueil, tous les points de vente regardés : la part de chacun aujourd'hui.
class LocationsOfDay extends ConsumerWidget {
  const LocationsOfDay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(summaryProvider).value?.byLocation ?? const [];
    if (rows.length < 2) return const SizedBox.shrink();
    final best = rows.map((r) => r.revenue).fold<int>(1, (a, b) => b > a ? b : a);
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Points de vente du jour', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
              ),
              TextButton(onPressed: () => context.push('/locations'), child: const Text('Gérer')),
            ],
          ),
          const SizedBox(height: 6),
          Glass(
            key: const Key('locations_of_day'),
            radius: 22,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(
              children: [
                for (final (i, l) in rows.indexed)
                  InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => ref.read(locationIdProvider.notifier).select(l.id),
                    child: Padding(
                      padding: EdgeInsets.only(top: i == 0 ? 4 : 12, bottom: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(l.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                              ),
                              Text(
                                '${l.salesCount} vente${l.salesCount > 1 ? 's' : ''} · ',
                                style: TextStyle(color: AppColors.muted, fontSize: 13),
                              ),
                              Text(moneyShort(l.revenue), style: const TextStyle(fontWeight: FontWeight.w800)),
                            ],
                          ),
                          const SizedBox(height: 5),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: l.revenue / best,
                              minHeight: 6,
                              backgroundColor: AppColors.line,
                              color: AppColors.green,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------
// Gestion des points de vente

class LocationsScreen extends ConsumerWidget {
  const LocationsScreen({super.key});

  Future<void> _add(BuildContext context, WidgetRef ref, LocationsState s) async {
    if (s.list.isNotEmpty && !ref.read(isProProvider)) {
      context.push('/pro?feature=${ProFeature.multiShop.key}');
      return;
    }
    await _edit(context, ref, null);
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, ShopLocation? l) async {
    final done = await showModalBottomSheet<bool>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _LocationEditor(location: l),
    );
    if (done == true) refreshLocations(ref);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(locationsProvider);
    final canManage = ref.watch(canProvider('business:update'));
    final canStock = ref.watch(canProvider('inventory:write'));
    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Points de vente', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      floatingActionButton: canManage && state.hasValue
          ? FloatingActionButton.extended(
              key: const Key('add_location'),
              heroTag: 'addLocation',
              onPressed: () => _add(context, ref, state.value!),
              icon: const Icon(Icons.add_business_rounded),
              label: const Text('Nouveau point de vente'),
            )
          : null,
      body: AsyncView<LocationsState>(
        value: state,
        onRetry: () => ref.invalidate(locationsProvider),
        data: (s) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(locationsProvider),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 120),
            children: [
              Text(
                'Chaque point de vente a son stock, sa caisse et ses ventes. '
                'Le catalogue, les clients et les fournisseurs sont communs.',
                style: TextStyle(color: AppColors.muted, fontSize: 13.5),
              ),
              const SizedBox(height: 12),
              for (final l in s.list) ...[
                Glass(
                  key: Key('location_${l.id}'),
                  radius: 20,
                  onTap: canManage ? () => _edit(context, ref, l) : null,
                  padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                  child: Row(
                    children: [
                      GlossyOrb(
                        icon: l.isDefault ? Icons.storefront_rounded : Icons.place_rounded,
                        color: l.isDefault ? AppColors.green : const Color(0xFF2E90FA),
                        size: 42,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    l.name,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5),
                                  ),
                                ),
                                if (l.isDefault) ...[const SizedBox(width: 6), const _Tag('Principal')],
                              ],
                            ),
                            if ((l.address ?? '').isNotEmpty)
                              Text(l.address!, style: TextStyle(fontSize: 12.5, color: AppColors.muted)),
                            const SizedBox(height: 4),
                            Text(
                              [
                                'Aujourd’hui ${moneyShort(l.todayRevenue)}',
                                'Stock ${moneyShort(l.stockValue)}',
                                if (l.members > 0) '${l.members} vendeur${l.members > 1 ? 's' : ''}',
                              ].join(' · '),
                              style: const TextStyle(fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                      if (canManage) Icon(Icons.chevron_right_rounded, color: AppColors.muted),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
              ],
              if (s.several && canStock) ...[
                const SizedBox(height: 6),
                OutlinedButton.icon(
                  key: const Key('open_transfer'),
                  onPressed: () => context.push('/stock/transfer'),
                  icon: const Icon(Icons.swap_horiz_rounded),
                  label: const Text('Transférer de la marchandise'),
                ),
              ],
              if (!ref.watch(isProProvider) && canManage) ...[
                const SizedBox(height: 14),
                Text(
                  'Plusieurs points de vente fait partie de Sama360 Pro.',
                  style: TextStyle(color: AppColors.muted, fontSize: 12.5),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(color: AppColors.greenSoft, borderRadius: BorderRadius.circular(8)),
    child: Text(
      text,
      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: AppColors.green),
    ),
  );
}

class _LocationEditor extends ConsumerStatefulWidget {
  const _LocationEditor({this.location});
  final ShopLocation? location;

  @override
  ConsumerState<_LocationEditor> createState() => _LocationEditorState();
}

class _LocationEditorState extends ConsumerState<_LocationEditor> {
  late final _name = TextEditingController(text: widget.location?.name);
  late final _address = TextEditingController(text: widget.location?.address);
  late final _phone = TextEditingController(text: widget.location?.phone);
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action, String done) async {
    setState(() => _busy = true);
    try {
      await action();
      if (!mounted) return;
      showInfo(context, done);
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showError(context, e);
      }
    }
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) return showInfo(context, 'Donnez un nom au point de vente');
    String? clean(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
    await _run(
      () => ref
          .read(repoProvider)
          .saveLocation(id: widget.location?.id, name: name, address: clean(_address), phone: clean(_phone)),
      widget.location == null ? 'Point de vente ajouté' : 'Point de vente enregistré',
    );
  }

  Future<void> _archive() async {
    final l = widget.location!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Fermer « ${l.name} » ?'),
        content: const Text(
          'Ses ventes passées restent dans les rapports. Son stock doit être vide '
          '(transférez-le avant) et sa caisse fermée.',
        ),
        actions: [
          CancelButton(onPressed: () => Navigator.pop(ctx, false)),
          ConfirmButton(danger: true, label: 'Fermer', onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() async {
      await ref.read(repoProvider).archiveLocation(l.id);
      if (ref.read(locationIdProvider) == l.id) await ref.read(locationIdProvider.notifier).select(null);
    }, 'Point de vente fermé');
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.location;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l == null ? 'Nouveau point de vente' : l.name,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('location_name'),
              controller: _name,
              autofocus: l == null,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Nom (ex. Boutique Médina)'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('location_address'),
              controller: _address,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Adresse (facultatif)'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Téléphone (facultatif)'),
            ),
            const SizedBox(height: 16),
            BusyButton(
              key: const Key('location_save'),
              label: l == null ? 'Ajouter le point de vente' : 'Enregistrer',
              busy: _busy,
              onPressed: _save,
            ),
            if (l != null && !l.isDefault) ...[
              TextButton(
                key: const Key('location_make_main'),
                onPressed: _busy
                    ? null
                    : () =>
                          _run(() => ref.read(repoProvider).makeMainLocation(l.id), 'Point de vente principal changé'),
                child: const Text('En faire le point de vente principal'),
              ),
              TextButton.icon(
                key: const Key('location_archive'),
                style: TextButton.styleFrom(foregroundColor: AppColors.danger),
                onPressed: _busy ? null : _archive,
                icon: const Icon(Icons.store_mall_directory_outlined),
                label: const Text('Fermer ce point de vente'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------
// Transfert de marchandise

class _TransferLine {
  _TransferLine(this.product, this.quantity);
  final Product product;
  double quantity;
}

class TransferScreen extends ConsumerStatefulWidget {
  const TransferScreen({super.key});

  @override
  ConsumerState<TransferScreen> createState() => _TransferScreenState();
}

class _TransferScreenState extends ConsumerState<TransferScreen> {
  final _id = const Uuid().v7(); // même identifiant à chaque essai : pas de doublon
  String? _from;
  String? _to;
  final _lines = <_TransferLine>[];
  bool _busy = false;

  /// Stock disponible au départ (le serveur donne toujours le détail par point de vente).
  Future<Map<String, double>> _available() async {
    final stock = await ref.read(stockRawProvider.future);
    return {for (final i in stock.items) i.productId: i.byLocation[_from] ?? 0};
  }

  Map<String, double>? _stock;

  Future<void> _loadStock() async {
    if (_from == null) return;
    try {
      final s = await _available();
      if (mounted) setState(() => _stock = s);
    } catch (_) {}
  }

  Future<void> _addProduct() async {
    final p = await showModalBottomSheet<Product>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const ProductPicker(),
    );
    if (p == null || !mounted) return;
    setState(() {
      final i = _lines.indexWhere((l) => l.product.id == p.id);
      if (i >= 0) {
        _lines[i].quantity += 1;
      } else {
        _lines.add(_TransferLine(p, 1));
      }
    });
  }

  Future<void> _send() async {
    if (_from == null || _to == null) return showInfo(context, 'Choisissez le départ et l’arrivée');
    if (_from == _to) return showInfo(context, 'Choisissez deux points de vente différents');
    if (_lines.isEmpty) return showInfo(context, 'Ajoutez au moins un produit');
    setState(() => _busy = true);
    try {
      final t = await ref
          .read(repoProvider)
          .transferStock(
            id: _id,
            fromId: _from!,
            toId: _to!,
            lines: [for (final l in _lines) (productId: l.product.id, quantity: l.quantity)],
          );
      refreshLocations(ref);
      ref.invalidate(transfersProvider);
      if (!mounted) return;
      showInfo(context, '${t.number} : marchandise envoyée à ${t.toName}');
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
    final state = ref.watch(locationsProvider);
    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Transfert de stock', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: BusyButton(
            key: const Key('transfer_send'),
            label: 'Envoyer la marchandise',
            icon: Icons.local_shipping_rounded,
            busy: _busy,
            onPressed: _send,
          ),
        ),
      ),
      body: AsyncView<LocationsState>(
        value: state,
        onRetry: () => ref.invalidate(locationsProvider),
        data: (s) {
          if (_from == null && s.list.isNotEmpty) {
            _from = s.locked ? s.writeTo : (s.currentId ?? s.list.first.id);
            _to = s.list.where((l) => l.id != _from).firstOrNull?.id;
            Future(_loadStock);
          }
          DropdownMenuItem<String> item(ShopLocation l) => DropdownMenuItem(value: l.id, child: Text(l.name));
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              DropdownButtonFormField<String>(
                key: const Key('transfer_from'),
                initialValue: _from,
                decoration: const InputDecoration(labelText: 'Départ', prefixIcon: Icon(Icons.logout_rounded)),
                items: [for (final l in s.list) item(l)],
                onChanged: s.locked
                    ? null
                    : (v) {
                        setState(() {
                          _from = v;
                          _stock = null;
                        });
                        _loadStock();
                      },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: const Key('transfer_to'),
                initialValue: _to,
                decoration: const InputDecoration(labelText: 'Arrivée', prefixIcon: Icon(Icons.login_rounded)),
                items: [for (final l in s.list.where((l) => l.id != _from)) item(l)],
                onChanged: (v) => setState(() => _to = v),
              ),
              const SizedBox(height: 18),
              const Text('Marchandise', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              const SizedBox(height: 8),
              for (final (i, l) in _lines.indexed) ...[
                Glass(
                  key: Key('transfer_line_$i'),
                  radius: 18,
                  padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(l.product.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                            if (_stock != null)
                              Text(
                                '${qty(_stock![l.product.id] ?? 0)} disponible(s) au départ',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: l.quantity > (_stock![l.product.id] ?? 0) ? AppColors.danger : AppColors.muted,
                                ),
                              ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: l.quantity <= 1 ? 'Retirer ${l.product.name}' : 'Un de moins',
                        onPressed: () => setState(() {
                          if (l.quantity <= 1) {
                            _lines.removeAt(i);
                          } else {
                            l.quantity -= 1;
                          }
                        }),
                        icon: l.quantity <= 1
                            ? Icon(Icons.delete_rounded, color: AppColors.danger)
                            : const Icon(Icons.remove_circle_outline_rounded),
                      ),
                      Text(qty(l.quantity), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                      IconButton(
                        key: Key('transfer_plus_$i'),
                        tooltip: 'Un de plus',
                        onPressed: () => setState(() => l.quantity += 1),
                        icon: const Icon(Icons.add_circle_outline_rounded),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
              ],
              OutlinedButton.icon(
                key: const Key('transfer_add'),
                onPressed: _addProduct,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Ajouter un produit'),
              ),
              const SizedBox(height: 22),
              const _RecentTransfers(),
            ],
          );
        },
      ),
    );
  }
}

final transfersProvider = FutureProvider<List<StockTransfer>>((ref) {
  ref.watch(scopeProvider);
  return ref.watch(repoProvider).transfers();
});

class _RecentTransfers extends ConsumerWidget {
  const _RecentTransfers();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(transfersProvider).value ?? const [];
    if (list.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Derniers transferts', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
        const SizedBox(height: 8),
        for (final t in list.take(10))
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Glass(
              radius: 16,
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text('${t.fromName} → ${t.toName}', style: const TextStyle(fontWeight: FontWeight.w800)),
                      ),
                      Text(shortDate(t.createdAt), style: TextStyle(fontSize: 12.5, color: AppColors.muted)),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    t.lines.map((l) => '${qty(l.quantity)} × ${l.name}').join(', '),
                    style: TextStyle(fontSize: 13, color: AppColors.muted),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
