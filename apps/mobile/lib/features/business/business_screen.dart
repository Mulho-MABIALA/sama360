import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/glass.dart';
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

/// Choisir une entreprise ou en créer une.
class BusinessScreen extends ConsumerStatefulWidget {
  const BusinessScreen({super.key});
  @override
  ConsumerState<BusinessScreen> createState() => _BusinessScreenState();
}

class _BusinessScreenState extends ConsumerState<BusinessScreen> {
  final _name = TextEditingController();
  final _city = TextEditingController(text: 'Dakar');
  String _category = 'boutique';
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
                    Pill(label: e.value, selected: _category == e.key, onTap: () => setState(() => _category = e.key)),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _city,
                decoration: const InputDecoration(labelText: 'Ville'),
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
