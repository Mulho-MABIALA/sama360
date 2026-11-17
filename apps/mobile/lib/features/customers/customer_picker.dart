import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// Ouvre la liste des clients (recherche + création rapide) et renvoie le client choisi.
Future<Contact?> pickCustomer(BuildContext context) => showModalBottomSheet<Contact>(
  useRootNavigator: true,
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => const FractionallySizedBox(heightFactor: 0.85, child: _CustomerPicker()),
);

class _CustomerPicker extends ConsumerStatefulWidget {
  const _CustomerPicker();
  @override
  ConsumerState<_CustomerPicker> createState() => _CustomerPickerState();
}

class _CustomerPickerState extends ConsumerState<_CustomerPicker> {
  String _search = '';
  late Future<List<Contact>> _future = _load();

  Future<List<Contact>> _load() => ref.read(repoProvider).customers(search: _search.isEmpty ? null : _search);

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(16, 0, 16, MediaQuery.viewInsetsOf(context).bottom),
    child: Column(
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('Choisir un client', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            ),
            TextButton.icon(
              onPressed: () async {
                final created = await createCustomerDialog(context, ref, initialName: _search);
                if (created != null && context.mounted) Navigator.pop(context, created);
              },
              icon: const Icon(Icons.person_add_alt_1),
              label: const Text('Nouveau'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          decoration: const InputDecoration(
            hintText: 'Nom ou téléphone',
            prefixIcon: Icon(Icons.search),
            isDense: true,
          ),
          onChanged: (v) => setState(() {
            _search = v.trim();
            _future = _load();
          }),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: FutureBuilder<List<Contact>>(
            future: _future,
            builder: (_, snap) {
              if (snap.hasError) {
                return ErrorPanel(message: errorMessage(snap.error!), onRetry: () => setState(() => _future = _load()));
              }
              if (!snap.hasData) return const Center(child: CircularProgressIndicator());
              final list = snap.data!;
              if (list.isEmpty) {
                return Center(
                  child: Text('Aucun client trouvé', style: TextStyle(color: AppColors.muted)),
                );
              }
              return ListView.separated(
                itemCount: list.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final c = list[i];
                  return ListTile(
                    leading: Avatar(name: c.name, size: 40, bg: AppColors.greenSoft, fg: AppColors.green),
                    title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: c.phone == null && c.creditLimit == null
                        ? null
                        : Text(
                            [
                              if (c.phone != null) displayPhone(c.phone!),
                              if (c.creditLimit != null) 'plafond ${moneyShort(c.creditLimit!)}',
                            ].join(' · '),
                          ),
                    trailing: c.balance > 0
                        ? Text(
                            money(c.balance),
                            style: TextStyle(color: AppColors.warn, fontWeight: FontWeight.w700),
                          )
                        : null,
                    onTap: () => Navigator.pop(context, c),
                  );
                },
              );
            },
          ),
        ),
      ],
    ),
  );
}

/// Création rapide d'un client (nom + téléphone facultatif).
Future<Contact?> createCustomerDialog(BuildContext context, WidgetRef ref, {String initialName = ''}) {
  final name = TextEditingController(text: initialName);
  final phone = TextEditingController();
  return showDialog<Contact>(
    context: context,
    builder: (ctx) {
      var busy = false;
      return StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Nouveau client'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Nom'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: phone,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  labelText: 'Téléphone (facultatif)',
                  prefixText: '+${ref.read(countryProvider).dial} ',
                ),
              ),
            ],
          ),
          actions: [
            CancelButton(onPressed: () => Navigator.pop(ctx)),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(110, 44)),
              onPressed: busy
                  ? null
                  : () async {
                      if (name.text.trim().isEmpty) return;
                      final p = phone.text.trim().isEmpty ? null : localPhone(phone.text, ref.read(countryProvider));
                      if (phone.text.trim().isNotEmpty && p == null) {
                        showInfo(ctx, invalidPhone(ref.read(countryProvider)));
                        return;
                      }
                      setState(() => busy = true);
                      try {
                        final c = await ref.read(repoProvider).createCustomer(name: name.text.trim(), phone: p);
                        if (ctx.mounted) Navigator.pop(ctx, c);
                      } catch (e) {
                        setState(() => busy = false);
                        if (ctx.mounted) showError(ctx, e);
                      }
                    },
              child: const Text('Créer'),
            ),
          ],
        ),
      );
    },
  );
}
