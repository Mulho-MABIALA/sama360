import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/trades.dart';
import '../../core/widgets.dart';
import '../auth/auth_controller.dart';
import '../profile/closure_screens.dart' show DeletedBusinessesList;

/// Ce que la boutique vend surtout : adapte l'accueil et les premiers pas.
const focusLabels = {'products': 'Des produits', 'services': 'Des services', 'both': 'Les deux'};

/// Activité proposée d'après le type d'entreprise (modifiable).
String focusFor(String category) => switch (category) {
  'salon' || 'prestataire' => 'services',
  'restaurant' => 'products',
  'boutique' || 'mode' || 'quincaillerie' || 'alimentation' || 'telephonie' => 'products',
  _ => 'both',
};

/// Choisir une entreprise ou en créer une.
class BusinessScreen extends ConsumerStatefulWidget {
  const BusinessScreen({super.key});
  @override
  ConsumerState<BusinessScreen> createState() => _BusinessScreenState();
}

class _BusinessScreenState extends ConsumerState<BusinessScreen> {
  final _name = TextEditingController();
  late Country _country;
  late final TextEditingController _city;

  /// Code de parrainage : repris du lien d'invitation (…/app/?ref=CODE) sur la version web.
  final _referral = TextEditingController(text: kIsWeb ? (Uri.base.queryParameters['ref'] ?? '') : '');
  String _category = 'boutique';
  String _focus = 'products';
  late bool _showReferral = _referral.text.isNotEmpty;
  bool _otherCity = false;
  bool _creating = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Lu ici (et pas paresseusement) : sinon dispose() créerait le champ avec un ref déjà démonté
    _country = ref.read(loginCountryProvider);
    _city = TextEditingController(text: _country.cities.first);
  }

  @override
  void dispose() {
    _name.dispose();
    _city.dispose();
    _referral.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_name.text.trim().length < 2) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(authProvider.notifier)
          .createBusiness(
            name: _name.text,
            category: _category == 'autre' ? null : _category,
            city: _city.text.trim().isEmpty ? null : _city.text.trim(),
            focus: _focus,
            referralCode: _referral.text.trim().isEmpty ? null : _referral.text.trim().toUpperCase(),
            country: _country.code,
          );
      if (mounted) context.go('/');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider).value;
    final list = auth?.me?.businesses ?? const [];
    final showForm = _creating || list.isEmpty;

    return AuroraScaffold(
      appBar: AppBar(
        title: Text(
          list.isEmpty ? 'Votre activité' : 'Mes entreprises',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        automaticallyImplyLeading: auth?.businessId != null,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          children: [
            if (!showForm) ...[
              for (final b in list)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Card(
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      leading: Avatar(name: b.name, bg: AppColors.greenSoft, fg: AppColors.green),
                      title: Text(b.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                      subtitle: Text(b.roleName),
                      trailing: b.id == auth?.businessId
                          ? Icon(Icons.check_circle, color: AppColors.green)
                          : const Icon(Icons.chevron_right),
                      onTap: () async {
                        await ref.read(authProvider.notifier).selectBusiness(b.id);
                        if (context.mounted) context.go('/');
                      },
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => setState(() => _creating = true),
                icon: const Icon(Icons.add),
                label: const Text('Créer une entreprise'),
              ),
              const DeletedBusinessesList(),
            ] else ...[
              Text(
                'Créez votre espace : boutique, restaurant, salon… Vous pourrez inviter votre équipe ensuite.',
                style: TextStyle(color: AppColors.muted),
              ),
              const SizedBox(height: 20),
              TextField(
                key: const Key('businessName'),
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: "Nom de l'entreprise", hintText: 'Ex. Awa Beauté'),
              ),
              const SizedBox(height: 16),
              const Text('Votre métier', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(
                'Sama360 vous montre les outils de votre métier. Vous pourrez en ajouter ensuite.',
                style: TextStyle(color: AppColors.muted, fontSize: 12.5),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final e in tradeLabels.entries)
                    Pill(
                      label: e.value,
                      selected: _category == e.key,
                      onTap: () => setState(() {
                        _category = e.key;
                        _focus = focusFor(e.key);
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Text('Pays', style: TextStyle(color: AppColors.muted, fontSize: 12.5)),
              const SizedBox(height: 8),
              CountryPills(
                value: _country,
                onChanged: (c) => setState(() {
                  // Ville par défaut du pays précédent : on prend celle du nouveau
                  if (_city.text.trim().isEmpty || Country.values.any((o) => o.cities.contains(_city.text.trim()))) {
                    _city.text = c.cities.first;
                    _otherCity = false;
                  }
                  _country = c;
                }),
              ),
              const SizedBox(height: 16),
              Text('Ville', style: TextStyle(color: AppColors.muted, fontSize: 12.5)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final city in _country.cities.take(5))
                    Pill(
                      label: city,
                      selected: !_otherCity && _city.text == city,
                      onTap: () => setState(() {
                        _otherCity = false;
                        _city.text = city;
                      }),
                    ),
                  Pill(
                    key: const Key('other_city'),
                    label: 'Autre…',
                    selected: _otherCity,
                    onTap: () => setState(() {
                      _otherCity = true;
                      _city.clear();
                    }),
                  ),
                ],
              ),
              if (_otherCity) ...[
                const SizedBox(height: 10),
                TextField(
                  key: const Key('businessCity'),
                  controller: _city,
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Votre ville'),
                ),
              ],
              const SizedBox(height: 12),
              if (_showReferral)
                TextField(
                  key: const Key('referralCode'),
                  controller: _referral,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    labelText: 'Code de parrainage',
                    hintText: 'ex. AWA7K2',
                    helperText: '1 mois Pro offert à vous et à celui qui vous a invité.',
                  ),
                )
              else
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const Key('show_referral'),
                    onPressed: () => setState(() => _showReferral = true),
                    icon: const Icon(Icons.card_giftcard_rounded, size: 18),
                    label: const Text('J’ai un code de parrainage'),
                  ),
                ),
              const SizedBox(height: 20),
              BusyButton(accent: true, label: "Créer l'entreprise", busy: _busy, onPressed: _create),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Logo, téléphone et le reste se règlent plus tard dans « Ma boutique ».',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.muted, fontSize: 12),
                ),
              ),
              if (list.isNotEmpty) ...[
                const SizedBox(height: 12),
                CancelButton(onPressed: () => setState(() => _creating = false)),
              ],
              if (list.isEmpty) ...[
                const DeletedBusinessesList(),
                const SizedBox(height: 12),
                TextButton(
                  key: const Key('open_delete_account'),
                  style: TextButton.styleFrom(foregroundColor: AppColors.danger),
                  onPressed: () => context.push('/account/delete'),
                  child: const Text('Supprimer mon compte'),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
