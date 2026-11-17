import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../auth/auth_controller.dart';

const _categories = {
  'boutique': 'Boutique',
  'restaurant': 'Restaurant',
  'salon': 'Salon / beauté',
  'prestataire': 'Prestataire',
  'autre': 'Autre',
};

/// Ce que la boutique vend surtout : adapte l'accueil et les premiers pas.
const focusLabels = {'products': 'Des produits', 'services': 'Des services', 'both': 'Les deux'};

/// Activité proposée d'après le type d'entreprise (modifiable).
String focusFor(String category) => switch (category) {
  'salon' || 'prestataire' => 'services',
  'restaurant' => 'products',
  'boutique' => 'products',
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
  late final _city = TextEditingController(text: _country.cities.first);
  late Country _country = ref.read(loginCountryProvider);
  String _category = 'boutique';
  String _focus = 'products';
  bool _creating = false;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _city.dispose();
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
              const Text("Type d'activité", style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final e in _categories.entries)
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
              const Text('Vous vendez surtout…', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(
                'Produits : stock et boutique en ligne. Services : rendez-vous et prestations.',
                style: TextStyle(color: AppColors.muted, fontSize: 12.5),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final e in focusLabels.entries)
                    Pill(
                      key: Key('focus_${e.key}'),
                      label: e.value,
                      selected: _focus == e.key,
                      onTap: () => setState(() => _focus = e.key),
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
                  }
                  _country = c;
                }),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _city,
                decoration: const InputDecoration(labelText: 'Ville'),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final city in _country.cities.take(5))
                    Pill(label: city, selected: _city.text == city, onTap: () => setState(() => _city.text = city)),
                ],
              ),
              const SizedBox(height: 24),
              BusyButton(label: "Créer l'entreprise", busy: _busy, onPressed: _create),
              if (list.isNotEmpty) CancelButton(onPressed: () => setState(() => _creating = false)),
            ],
          ],
        ),
      ),
    );
  }
}
