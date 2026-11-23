import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../auth/auth_controller.dart';
import '../auth/pin_screen.dart' show confirmSensitive;

/// Mot à taper pour supprimer son compte (identique au serveur).
const accountConfirmWord = 'SUPPRIMER';

/// Nom tapé pour confirmer : casse, accents et espaces ignorés (comme le serveur).
bool sameBusinessName(String typed, String name) {
  String n(String s) => s
      .toLowerCase()
      .replaceAll(RegExp('[àâäá]'), 'a')
      .replaceAll(RegExp('[éèêë]'), 'e')
      .replaceAll(RegExp('[îïí]'), 'i')
      .replaceAll(RegExp('[ôöó]'), 'o')
      .replaceAll(RegExp('[ûüùú]'), 'u')
      .replaceAll('ç', 'c')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return n(typed).isNotEmpty && n(typed) == n(name);
}

/// Écran commun : ce qui va se passer, champ de confirmation, bouton rouge.
class _ClosureScaffold extends StatelessWidget {
  const _ClosureScaffold({
    required this.title,
    required this.intro,
    required this.points,
    required this.field,
    required this.button,
  });
  final String title;
  final String intro;
  final List<(IconData, String)> points;
  final Widget field;
  final Widget button;

  @override
  Widget build(BuildContext context) => AuroraScaffold(
    appBar: AppBar(
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
    ),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.danger.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppColors.danger.withValues(alpha: 0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: AppColors.danger),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      intro,
                      style: TextStyle(color: AppColors.danger, fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              for (final (icon, text) in points)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(icon, size: 19, color: AppColors.ink),
                      const SizedBox(width: 10),
                      Expanded(child: Text(text, style: const TextStyle(height: 1.3))),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Glass(radius: 22, padding: const EdgeInsets.all(16), child: field),
        const SizedBox(height: 16),
        button,
      ],
    ),
  );
}

Widget _dangerButton({required Key key, required String label, required bool busy, VoidCallback? onPressed}) =>
    SizedBox(
      height: 54,
      child: FilledButton.icon(
        key: key,
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.danger,
          foregroundColor: Colors.white,
          disabledBackgroundColor: AppColors.danger.withValues(alpha: 0.35),
          disabledForegroundColor: Colors.white,
        ),
        onPressed: busy ? null : onPressed,
        icon: busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              )
            : const Icon(Icons.delete_forever_rounded),
        label: Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
    );

// ───────────────────────────────────────────────────────────── Boutique

class DeleteBusinessScreen extends ConsumerStatefulWidget {
  const DeleteBusinessScreen({super.key});
  @override
  ConsumerState<DeleteBusinessScreen> createState() => _DeleteBusinessScreenState();
}

class _DeleteBusinessScreenState extends ConsumerState<DeleteBusinessScreen> {
  final _name = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _delete(BusinessLink b) async {
    if (!await confirmSensitive(context, ref, action: 'Supprimer ${b.name}')) return;
    setState(() => _busy = true);
    try {
      await ref.read(authProvider.notifier).deleteCurrentBusiness(_name.text);
      ref.invalidate(deletedBusinessesProvider);
      if (!mounted) return;
      showInfo(context, '${b.name} est supprimée. Vous avez 30 jours pour la restaurer.');
      final auth = ref.read(authProvider).value;
      context.go(auth?.businessId == null ? '/business' : '/');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = ref.watch(authProvider).value?.business;
    if (b == null) return const AuroraScaffold(body: Center(child: CircularProgressIndicator()));
    if (b.role != 'owner') {
      return AuroraScaffold(
        appBar: AppBar(),
        body: const Center(child: Text('Seul le propriétaire peut supprimer la boutique.')),
      );
    }
    final pro = ref.watch(subscriptionProvider).value;
    final ok = sameBusinessName(_name.text, b.name);
    return _ClosureScaffold(
      title: 'Supprimer la boutique',
      intro: 'Vous allez supprimer « ${b.name} »',
      points: [
        (Icons.group_off_rounded, 'Elle disparaît tout de suite pour vous et toute votre équipe.'),
        (Icons.storefront_rounded, 'Votre boutique en ligne et la réservation en ligne ferment.'),
        (
          Icons.inventory_2_rounded,
          'Ventes, produits, stock, clients, crédits, factures et photos sont effacés pour de bon après 30 jours.',
        ),
        (Icons.restore_rounded, 'Pendant 30 jours, vous pouvez la restaurer avec toutes ses données.'),
        if (pro?.state == ProState.active)
          (Icons.workspace_premium_rounded, 'Votre abonnement Pro en cours n’est pas remboursé.'),
      ],
      field: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Pour confirmer, tapez le nom de la boutique :', style: TextStyle(color: AppColors.muted)),
          const SizedBox(height: 4),
          Text(b.name, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
          const SizedBox(height: 10),
          TextField(
            key: const Key('confirm_business_name'),
            controller: _name,
            autocorrect: false,
            decoration: InputDecoration(labelText: 'Nom de la boutique', hintText: b.name),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      button: _dangerButton(
        key: const Key('delete_business'),
        label: 'Supprimer la boutique',
        busy: _busy,
        onPressed: ok ? () => _delete(b) : null,
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────── Compte

class DeleteAccountScreen extends ConsumerStatefulWidget {
  const DeleteAccountScreen({super.key});
  @override
  ConsumerState<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends ConsumerState<DeleteAccountScreen> {
  final _word = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _word.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    if (!await confirmSensitive(context, ref, action: 'Supprimer mon compte')) return;
    setState(() => _busy = true);
    try {
      await ref.read(authProvider.notifier).deleteAccount(_word.text);
      // La session est effacée : le routeur ramène à la connexion
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(authProvider).value?.me;
    final owned = me?.businesses.where((b) => b.role == 'owner').map((b) => b.name).toList() ?? const <String>[];
    final ok = _word.text.trim().toUpperCase() == accountConfirmWord;
    return _ClosureScaffold(
      title: 'Supprimer mon compte',
      intro: 'Vous allez supprimer votre compte Sama360',
      points: [
        if (owned.isNotEmpty)
          (
            Icons.storefront_rounded,
            owned.length == 1
                ? 'Votre boutique « ${owned.single} » est supprimée avec lui.'
                : 'Vos ${owned.length} boutiques sont supprimées avec lui : ${owned.join(', ')}.',
          ),
        (Icons.group_remove_rounded, 'Vous quittez les équipes dont vous faites partie.'),
        (Icons.logout_rounded, 'Vous êtes déconnecté de tous vos téléphones.'),
        (Icons.restore_rounded, 'Changé d’avis ? Reconnectez-vous avec votre numéro dans les 30 jours : tout revient.'),
        (Icons.delete_forever_rounded, 'Après 30 jours, votre compte et vos boutiques sont effacés pour de bon.'),
      ],
      field: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              text: 'Pour confirmer, tapez ',
              style: TextStyle(color: AppColors.muted),
              children: const [
                TextSpan(
                  text: accountConfirmWord,
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const Key('confirm_account_word'),
            controller: _word,
            autocorrect: false,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(hintText: accountConfirmWord),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      button: _dangerButton(
        key: const Key('delete_account'),
        label: 'Supprimer mon compte',
        busy: _busy,
        onPressed: ok ? _delete : null,
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────── Restaurer

/// Boutiques supprimées encore restaurables (écran « Mes entreprises »).
class DeletedBusinessesList extends ConsumerStatefulWidget {
  const DeletedBusinessesList({super.key});
  @override
  ConsumerState<DeletedBusinessesList> createState() => _DeletedBusinessesListState();
}

class _DeletedBusinessesListState extends ConsumerState<DeletedBusinessesList> {
  String? _busy;

  Future<void> _restore(DeletedBusiness b) async {
    setState(() => _busy = b.id);
    try {
      await ref.read(authProvider.notifier).restoreBusiness(b.id);
      ref.invalidate(deletedBusinessesProvider);
      if (!mounted) return;
      showInfo(context, '${b.name} est restaurée');
      context.go('/');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = ref.watch(deletedBusinessesProvider).value ?? const [];
    if (list.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Boutiques supprimées', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          const SizedBox(height: 2),
          Text('Restaurables avec toutes leurs données.', style: TextStyle(color: AppColors.muted, fontSize: 12.5)),
          const SizedBox(height: 8),
          for (final b in list)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Glass(
                key: Key('deleted_${b.id}'),
                radius: 18,
                padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                child: Row(
                  children: [
                    Icon(Icons.delete_outline_rounded, color: AppColors.muted),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(b.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                          Text(
                            b.daysLeft <= 1 ? 'Effacée demain' : 'Effacée dans ${b.daysLeft} jours',
                            style: TextStyle(color: AppColors.danger, fontSize: 12.5, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                    TextButton.icon(
                      key: Key('restore_${b.id}'),
                      onPressed: _busy == null ? () => _restore(b) : null,
                      icon: _busy == b.id
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.restore_rounded),
                      label: const Text('Restaurer', style: TextStyle(fontWeight: FontWeight.w800)),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
