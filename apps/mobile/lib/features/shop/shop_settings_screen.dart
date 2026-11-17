import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// Réglages de la boutique : ouverture, présentation, livraison, retrait, minimum.
class ShopSettingsScreen extends ConsumerStatefulWidget {
  const ShopSettingsScreen({super.key, this.opening = false});

  /// Ouvert depuis « Ouvrir ma boutique » : l'interrupteur est déjà activé.
  final bool opening;

  @override
  ConsumerState<ShopSettingsScreen> createState() => _ShopSettingsScreenState();
}

class _ShopSettingsScreenState extends ConsumerState<ShopSettingsScreen> {
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _whatsapp = TextEditingController();
  final _fee = TextEditingController();
  final _zone = TextEditingController();
  final _min = TextEditingController();
  bool _enabled = false;
  bool _pickup = true;
  bool _delivery = true;
  bool _publishAll = false;
  bool _loaded = false;
  bool _busy = false;
  String? _phoneError;

  @override
  void initState() {
    super.initState();
    Future(() async {
      try {
        final o = await ref.read(shopProvider.future);
        final b = await ref.read(currentBusinessProvider.future);
        final s = o.settings;
        _enabled = s.enabled || widget.opening;
        _title.text = s.title ?? b.name;
        _description.text = s.description ?? '';
        final wa = s.whatsapp ?? b.phone;
        _whatsapp.text = wa == null ? '' : displayPhone(wa.replaceAll(' ', ''));
        _pickup = s.pickup;
        _delivery = s.delivery;
        _fee.text = s.deliveryFee == 0 ? '' : '${s.deliveryFee}';
        _zone.text = s.deliveryZone ?? (b.city ?? '');
        _min.text = s.minOrder == 0 ? '' : '${s.minOrder}';
        // Première ouverture sans produit en ligne : proposer de tout publier
        _publishAll = widget.opening && o.publishedProducts == 0 && o.totalProducts > 0;
      } catch (e) {
        if (mounted) showError(context, e);
      }
      if (mounted) setState(() => _loaded = true);
    });
  }

  @override
  void dispose() {
    for (final c in [_title, _description, _whatsapp, _fee, _zone, _min]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _phoneError = null);
    final phone = _whatsapp.text.trim().isEmpty ? null : senegalPhone(_whatsapp.text);
    if (_whatsapp.text.trim().isNotEmpty && phone == null) {
      setState(() => _phoneError = '9 chiffres, ex. 77 123 45 67');
      return;
    }
    if (!_pickup && !_delivery) return showInfo(context, 'Proposez au moins le retrait ou la livraison');
    setState(() => _busy = true);
    try {
      final repo = ref.read(repoProvider);
      await repo.saveShopSettings(
        ShopSettings(
          enabled: _enabled,
          title: _title.text.trim(),
          description: _description.text.trim(),
          whatsapp: phone,
          pickup: _pickup,
          delivery: _delivery,
          deliveryFee: _delivery ? int.tryParse(_fee.text) ?? 0 : 0,
          deliveryZone: _zone.text.trim(),
          minOrder: int.tryParse(_min.text) ?? 0,
        ),
      );
      if (_publishAll) await repo.publishProducts(published: true);
      refreshShop(ref);
      ref.invalidate(productsProvider);
      if (!mounted) return;
      showInfo(context, widget.opening ? 'Votre boutique est en ligne !' : 'Réglages enregistrés');
      context.canPop() ? context.pop() : context.go('/shop');
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final digits = [FilteringTextInputFormatter.digitsOnly];
    return AuroraScaffold(
      appBar: AppBar(
        title: Text(
          widget.opening ? 'Ouvrir ma boutique' : 'Réglages de la boutique',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
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
                        title: 'Boutique',
                        children: [
                          SwitchListTile(
                            key: const Key('shopEnabled'),
                            contentPadding: EdgeInsets.zero,
                            value: _enabled,
                            onChanged: (v) => setState(() => _enabled = v),
                            title: const Text('Boutique ouverte', style: TextStyle(fontWeight: FontWeight.w700)),
                            subtitle: const Text(
                              'Fermée, la page n’est plus visible et personne ne peut commander',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                          if (widget.opening && _publishAll)
                            CheckboxListTile(
                              key: const Key('publishAll'),
                              contentPadding: EdgeInsets.zero,
                              value: _publishAll,
                              onChanged: (v) => setState(() => _publishAll = v ?? false),
                              title: const Text('Mettre tous mes produits en ligne'),
                              subtitle: const Text('Vous pourrez en retirer ensuite', style: TextStyle(fontSize: 12)),
                            ),
                          const SizedBox(height: 6),
                          TextField(
                            key: const Key('shopTitle'),
                            controller: _title,
                            textCapitalization: TextCapitalization.words,
                            decoration: const InputDecoration(labelText: 'Nom affiché'),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            key: const Key('shopDescription'),
                            controller: _description,
                            minLines: 2,
                            maxLines: 4,
                            textCapitalization: TextCapitalization.sentences,
                            decoration: const InputDecoration(
                              labelText: 'Présentation (facultatif)',
                              hintText: 'Ex. Cosmétiques naturels, livrés partout à Dakar en 24 h',
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            key: const Key('shopWhatsapp'),
                            controller: _whatsapp,
                            keyboardType: TextInputType.phone,
                            decoration: InputDecoration(
                              labelText: 'Numéro WhatsApp des clients',
                              prefixText: '+221 ',
                              errorText: _phoneError,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _Section(
                        title: 'Livraison et retrait',
                        children: [
                          SwitchListTile(
                            key: const Key('shopPickup'),
                            contentPadding: EdgeInsets.zero,
                            value: _pickup,
                            onChanged: (v) => setState(() => _pickup = v),
                            title: const Text('Retrait en boutique', style: TextStyle(fontWeight: FontWeight.w700)),
                          ),
                          SwitchListTile(
                            key: const Key('shopDelivery'),
                            contentPadding: EdgeInsets.zero,
                            value: _delivery,
                            onChanged: (v) => setState(() => _delivery = v),
                            title: const Text('Livraison', style: TextStyle(fontWeight: FontWeight.w700)),
                          ),
                          if (_delivery) ...[
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    key: const Key('shopFee'),
                                    controller: _fee,
                                    keyboardType: TextInputType.number,
                                    inputFormatters: digits,
                                    decoration: const InputDecoration(
                                      labelText: 'Frais de livraison',
                                      suffixText: 'FCFA',
                                      helperText: 'Vide : offerte',
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: TextField(
                                    key: const Key('shopZone'),
                                    controller: _zone,
                                    decoration: const InputDecoration(labelText: 'Zone', hintText: 'Ex. Dakar'),
                                  ),
                                ),
                              ],
                            ),
                          ],
                          const SizedBox(height: 12),
                          TextField(
                            key: const Key('shopMin'),
                            controller: _min,
                            keyboardType: TextInputType.number,
                            inputFormatters: digits,
                            decoration: const InputDecoration(
                              labelText: 'Commande minimum (facultatif)',
                              suffixText: 'FCFA',
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(10, 4, 10, 8 + MediaQuery.paddingOf(context).bottom),
                  child: Glass(
                    radius: 28,
                    padding: const EdgeInsets.all(14),
                    child: BusyButton(
                      label: widget.opening ? 'Mettre ma boutique en ligne' : 'Enregistrer',
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

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;

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
        const SizedBox(height: 6),
        ...children,
      ],
    ),
  );
}

/// Produits visibles en ligne : un interrupteur par produit, tout publier ou tout retirer.
class ShopProductsScreen extends ConsumerStatefulWidget {
  const ShopProductsScreen({super.key});
  @override
  ConsumerState<ShopProductsScreen> createState() => _ShopProductsScreenState();
}

class _ShopProductsScreenState extends ConsumerState<ShopProductsScreen> {
  final _overrides = <String, bool>{}; // changements en cours (affichage immédiat)
  String _q = '';

  Future<void> _set(List<String>? ids, bool published, {List<Product>? all}) async {
    setState(() {
      for (final id in ids ?? all!.map((p) => p.id)) {
        _overrides[id] = published;
      }
    });
    try {
      await ref.read(repoProvider).publishProducts(productIds: ids, published: published);
      ref.invalidate(productsProvider);
      ref.invalidate(shopProvider);
    } catch (e) {
      if (mounted) {
        setState(() => _overrides.clear());
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final products = ref.watch(productsProvider);
    final canWrite = ref.watch(canProvider('catalog:write'));
    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Produits en ligne', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: AsyncView<List<Product>>(
        value: products,
        onRetry: () => ref.invalidate(productsProvider),
        data: (all) {
          bool on(Product p) => _overrides[p.id] ?? p.published;
          final shown = all.where((p) => _q.isEmpty || p.name.toLowerCase().contains(_q)).toList();
          final count = all.where(on).length;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            children: [
              Text(
                '$count produit${count > 1 ? 's' : ''} sur ${all.length} visible${count > 1 ? 's' : ''} dans la boutique',
                style: TextStyle(color: AppColors.muted),
              ),
              const SizedBox(height: 10),
              TextField(
                decoration: const InputDecoration(
                  hintText: 'Rechercher',
                  prefixIcon: Icon(Icons.search),
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
              ),
              if (canWrite) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => _set(null, true, all: all),
                        child: const Text('Tout publier'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => _set(null, false, all: all),
                        child: const Text('Tout retirer'),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 10),
              Card(
                child: Column(
                  children: [
                    for (final (i, p) in shown.indexed) ...[
                      SwitchListTile(
                        key: Key('pub_${p.id}'),
                        value: on(p),
                        onChanged: canWrite ? (v) => _set([p.id], v) : null,
                        title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                        subtitle: Text(moneyShort(p.price), style: const TextStyle(fontSize: 12.5)),
                      ),
                      if (i < shown.length - 1) const Divider(height: 1, indent: 14, endIndent: 14),
                    ],
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
