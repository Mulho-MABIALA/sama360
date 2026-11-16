import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/api_client.dart';
import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// Demande un nom de catégorie (création ou renommage).
Future<String?> _askName(BuildContext context, {String? initial, required String title}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        key: const Key('categoryName'),
        controller: ctrl,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(hintText: 'Ex. Cosmétiques, Épicerie…'),
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
        TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Valider')),
      ],
    ),
  );
}

/// Choisir une catégorie, en créer une, ou « Sans catégorie » (renvoie une catégorie d'identifiant vide).
Future<Category?> pickOrCreateCategory(BuildContext context, WidgetRef ref, {Category? selected}) async {
  final result = await showModalBottomSheet<Object>(
    useRootNavigator: true,
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => Consumer(
      builder: (ctx, ref, _) {
        final cats = ref.watch(categoriesProvider);
        return SizedBox(
          height: MediaQuery.sizeOf(ctx).height * 0.6,
          child: AsyncView<List<Category>>(
            value: cats,
            onRetry: () => ref.invalidate(categoriesProvider),
            data: (list) => ListView(
              children: [
                ListTile(
                  leading: const Icon(Icons.add_circle_outline_rounded, color: AppColors.green),
                  title: const Text('Nouvelle catégorie', style: TextStyle(fontWeight: FontWeight.w700)),
                  onTap: () => Navigator.pop(ctx, 'new'),
                ),
                ListTile(
                  leading: const Icon(Icons.label_off_outlined),
                  title: const Text('Sans catégorie'),
                  trailing: selected == null ? const Icon(Icons.check_rounded, color: AppColors.green) : null,
                  onTap: () => Navigator.pop(ctx, const Category(id: '', name: '')),
                ),
                for (final c in list)
                  ListTile(
                    leading: const Icon(Icons.label_outline_rounded),
                    title: Text(c.name),
                    trailing: selected?.id == c.id ? const Icon(Icons.check_rounded, color: AppColors.green) : null,
                    onTap: () => Navigator.pop(ctx, c),
                  ),
              ],
            ),
          ),
        );
      },
    ),
  );
  if (result is Category) return result;
  if (result == 'new' && context.mounted) {
    final name = await _askName(context, title: 'Nouvelle catégorie');
    if (name == null || name.isEmpty) return null;
    try {
      final c = await ref.read(repoProvider).createCategory(name);
      ref.invalidate(categoriesProvider);
      return c;
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }
  return null;
}

/// Gestion des catégories : ajouter, renommer, supprimer.
class CategoriesScreen extends ConsumerWidget {
  const CategoriesScreen({super.key});

  Future<void> _run(BuildContext context, WidgetRef ref, Future<void> Function() action, String done) async {
    try {
      await action();
      ref.invalidate(categoriesProvider);
      ref.invalidate(productsProvider);
      if (context.mounted) showInfo(context, done);
    } on ApiException catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cats = ref.watch(categoriesProvider);
    final canWrite = ref.can('catalog:write');
    final repo = ref.read(repoProvider);
    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Catégories', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      floatingActionButton: canWrite
          ? FloatingActionButton.extended(
              backgroundColor: AppColors.green,
              foregroundColor: Colors.white,
              onPressed: () async {
                final name = await _askName(context, title: 'Nouvelle catégorie');
                if (name == null || name.isEmpty || !context.mounted) return;
                await _run(context, ref, () => repo.createCategory(name), 'Catégorie ajoutée');
              },
              icon: const Icon(Icons.add_rounded),
              label: const Text('Ajouter', style: TextStyle(fontWeight: FontWeight.w800)),
            )
          : null,
      body: AsyncView<List<Category>>(
        value: cats,
        onRetry: () => ref.invalidate(categoriesProvider),
        data: (list) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                'Les catégories rangent vos produits dans la caisse et le stock.',
                style: TextStyle(color: AppColors.muted),
              ),
            ),
            for (final c in list)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Glass(
                  radius: 18,
                  blur: 10,
                  padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
                  child: Row(
                    children: [
                      const Icon(Icons.label_rounded, color: AppColors.green),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(c.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                            Text(
                              c.productCount == 0
                                  ? 'Aucun produit'
                                  : '${c.productCount} produit${c.productCount > 1 ? 's' : ''}',
                              style: const TextStyle(fontSize: 12.5, color: AppColors.muted),
                            ),
                          ],
                        ),
                      ),
                      if (canWrite) ...[
                        IconButton(
                          tooltip: 'Renommer ${c.name}',
                          onPressed: () async {
                            final name = await _askName(context, initial: c.name, title: 'Renommer la catégorie');
                            if (name == null || name.isEmpty || name == c.name || !context.mounted) return;
                            await _run(context, ref, () => repo.renameCategory(c.id, name), 'Catégorie renommée');
                          },
                          icon: const Icon(Icons.edit_outlined),
                        ),
                        IconButton(
                          tooltip: 'Supprimer ${c.name}',
                          onPressed: () async {
                            final ok = await showDialog<bool>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: Text('Supprimer « ${c.name} » ?'),
                                content: Text(
                                  c.productCount == 0
                                      ? 'Cette catégorie est vide.'
                                      : 'Ses ${c.productCount} produit(s) restent dans le catalogue, sans catégorie.',
                                ),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
                                  TextButton(
                                    style: TextButton.styleFrom(foregroundColor: AppColors.danger),
                                    onPressed: () => Navigator.pop(ctx, true),
                                    child: const Text('Supprimer'),
                                  ),
                                ],
                              ),
                            );
                            if (ok != true || !context.mounted) return;
                            await _run(context, ref, () => repo.deleteCategory(c.id), 'Catégorie supprimée');
                          },
                          icon: const Icon(Icons.delete_outline_rounded),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
