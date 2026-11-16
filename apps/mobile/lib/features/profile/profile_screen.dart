import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../auth/auth_controller.dart';
import '../business/business_logo.dart';
import '../catalog/product_photo.dart';
import '../offline/offline_ui.dart';

/// Version affichée dans « À propos » (même valeur que pubspec.yaml).
const appVersion = '1.0.0';

/// Photo de profil de l'utilisateur connecté (initiales si aucune photo).
class MeAvatar extends ConsumerWidget {
  const MeAvatar({super.key, this.size = 38});
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(authProvider).value?.me;
    final fileId = me?.avatarFileId;
    return Avatar(
      name: me?.fullName,
      size: size,
      imageUrl: fileId == null ? null : ref.read(repoProvider).fileUrl(fileId),
    );
  }
}

enum _PhotoAction { camera, gallery, remove }

/// Page « Mon profil » : photo, informations, entreprise, sécurité, déconnexion.
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});
  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  bool _photoBusy = false;

  Future<void> _changePhoto(Me me) async {
    final action = await showModalBottomSheet<_PhotoAction>(
      useRootNavigator: true,
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('Photo de profil', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_rounded, color: AppColors.green),
              title: const Text('Prendre une photo'),
              onTap: () => Navigator.pop(ctx, _PhotoAction.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_rounded, color: AppColors.green),
              title: const Text('Choisir dans la galerie'),
              onTap: () => Navigator.pop(ctx, _PhotoAction.gallery),
            ),
            if (me.avatarFileId != null)
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded, color: AppColors.danger),
                title: const Text('Retirer la photo', style: TextStyle(color: AppColors.danger)),
                onTap: () => Navigator.pop(ctx, _PhotoAction.remove),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    final auth = ref.read(authProvider.notifier);
    try {
      if (action == _PhotoAction.remove) {
        setState(() => _photoBusy = true);
        await auth.removeAvatar();
        if (mounted) showInfo(context, 'Photo retirée');
        return;
      }
      final photo = await ref.read(photoPickerProvider)(
        action == _PhotoAction.camera ? ImageSource.camera : ImageSource.gallery,
      );
      if (photo == null || !mounted) return;
      setState(() => _photoBusy = true);
      await auth.setAvatar(photo.bytes, photo.filename);
      if (mounted) showInfo(context, 'Photo de profil mise à jour');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _photoBusy = false);
    }
  }

  Future<void> _editInfo(Me me) async {
    final saved = await showModalBottomSheet<bool>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _EditProfileSheet(me: me),
    );
    if (saved == true && mounted) showInfo(context, 'Profil enregistré');
  }

  Future<void> _signOutEverywhere() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Déconnecter tous les appareils ?'),
        content: Text(
          'Vous serez déconnecté de ce téléphone et de tous les autres. '
          'Il faudra recevoir un nouveau code pour vous reconnecter.'
          '${unsentSalesCount(ref) > 0 ? '\n\nLes ventes pas encore envoyées depuis ce téléphone seront perdues.' : ''}',
        ),
        actions: [
          CancelButton(onPressed: () => Navigator.pop(ctx, false)),
          ConfirmButton(label: 'Tout déconnecter', onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(authProvider.notifier).signOutEverywhere();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _signOut() async {
    final unsent = unsentSalesCount(ref);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Se déconnecter ?'),
        content: unsent == 0
            ? null
            : Text(
                unsent == 1
                    ? 'Attention : 1 vente n’a pas encore été envoyée. Elle sera perdue si vous vous déconnectez.'
                    : 'Attention : $unsent ventes n’ont pas encore été envoyées. Elles seront perdues si vous vous déconnectez.',
                style: const TextStyle(color: AppColors.danger),
              ),
        actions: [
          CancelButton(onPressed: () => Navigator.pop(ctx, false)),
          ConfirmButton(label: 'Déconnexion', onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
    );
    if (ok == true) await ref.read(authProvider.notifier).signOut();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider).value;
    final me = auth?.me;
    final link = auth?.business;
    final business = ref.watch(currentBusinessProvider).value;
    if (me == null) return const AuroraScaffold(body: Center(child: CircularProgressIndicator()));

    return AuroraScaffold(
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _Header(
            me: me,
            roleLabel: link == null ? null : '${link.roleName} · ${link.name}',
            busy: _photoBusy,
            onPhoto: () => _changePhoto(me),
          ),
          Transform.translate(
            offset: const Offset(0, -28),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Section(
                    title: 'Informations personnelles',
                    action: TextButton.icon(
                      onPressed: () => _editInfo(me),
                      icon: const Icon(Icons.edit_rounded, size: 18),
                      label: const Text('Modifier'),
                    ),
                    children: [
                      _Row(
                        icon: Icons.badge_rounded,
                        color: AppColors.green,
                        label: 'Nom complet',
                        value: me.fullName ?? '—',
                      ),
                      _Row(
                        icon: Icons.phone_iphone_rounded,
                        color: const Color(0xFF2F6FDB),
                        label: 'Téléphone',
                        value: '+221 ${displayPhone(me.phone)}',
                        hint: 'Sert à vous connecter',
                      ),
                      _Row(
                        icon: Icons.alternate_email_rounded,
                        color: const Color(0xFF7A5AF8),
                        label: 'E-mail',
                        value: me.email ?? 'Non renseigné',
                        muted: me.email == null,
                        onTap: () => _editInfo(me),
                      ),
                      if (me.createdAt != null)
                        _Row(
                          icon: Icons.event_available_rounded,
                          color: const Color(0xFFD9822B),
                          label: 'Membre depuis',
                          value: DateFormat('MMMM yyyy', 'fr').format(me.createdAt!.toLocal()),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _Section(
                    title: 'Mon entreprise',
                    children: [
                      _Row(
                        icon: Icons.storefront_rounded,
                        color: const Color(0xFF0E9384),
                        label: link?.roleName ?? 'Entreprise',
                        value: link?.name ?? 'Aucune entreprise choisie',
                        trailing: const Text(
                          'Changer',
                          style: TextStyle(color: AppColors.green, fontWeight: FontWeight.w800),
                        ),
                        onTap: () => context.push('/business'),
                      ),
                      if (business != null && ref.can('business:update'))
                        InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () => changeBusinessLogo(context, ref, business),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                            child: Row(
                              children: [
                                BusinessLogo(business: business, size: 38, radius: 12),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        'Logo',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: AppColors.muted,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      Text(
                                        business.logoFileId == null ? 'Ajouter un logo' : 'Changer le logo',
                                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                                      ),
                                      const Text(
                                        'Affiché sur vos factures et devis',
                                        style: TextStyle(fontSize: 11.5, color: AppColors.muted),
                                      ),
                                    ],
                                  ),
                                ),
                                const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
                              ],
                            ),
                          ),
                        ),
                      if (business != null)
                        _Row(
                          icon: Icons.language_rounded,
                          color: const Color(0xFF1D7AF0),
                          label: 'Boutique en ligne',
                          value: 'sama360.com/${business.slug}',
                          hint: 'Bientôt disponible',
                        ),
                      if (ref.can('members:read'))
                        _Row(
                          icon: Icons.groups_rounded,
                          color: const Color(0xFFDB2777),
                          label: 'Équipe',
                          value: 'Mon équipe',
                          hint: ref.can('members:invite') ? 'Inviter un vendeur ou un gérant' : null,
                          onTap: () => context.push('/team'),
                        ),
                      if ((me.businesses.length) > 1)
                        _Row(
                          icon: Icons.business_center_rounded,
                          color: AppColors.muted,
                          label: 'Mes entreprises',
                          value: '${me.businesses.length} entreprises',
                          onTap: () => context.push('/business'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _Section(
                    title: 'Sécurité',
                    children: [
                      _Row(
                        icon: Icons.devices_rounded,
                        color: const Color(0xFFE0533D),
                        label: 'Sessions',
                        value: 'Déconnecter tous les appareils',
                        hint: 'Si vous avez perdu un téléphone',
                        onTap: _signOutEverywhere,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const _Section(
                    title: 'Application',
                    children: [
                      _Row(
                        icon: Icons.translate_rounded,
                        color: Color(0xFF0A8453),
                        label: 'Langue',
                        value: 'Français',
                        hint: 'Wolof et anglais bientôt',
                      ),
                      _Row(
                        icon: Icons.info_outline_rounded,
                        color: AppColors.muted,
                        label: 'Version',
                        value: 'Sama360 $appVersion',
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.danger,
                      side: BorderSide(color: AppColors.danger.withValues(alpha: 0.35)),
                    ),
                    onPressed: _signOut,
                    icon: const Icon(Icons.logout_rounded),
                    label: const Text('Se déconnecter'),
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

/// En-tête émeraude : grande photo avec anneau lumineux et bouton appareil photo.
class _Header extends ConsumerWidget {
  const _Header({required this.me, required this.roleLabel, required this.busy, required this.onPhoto});
  final Me me;
  final String? roleLabel;
  final bool busy;
  final VoidCallback onPhoto;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final top = MediaQuery.paddingOf(context).top;
    final canPop = GoRouter.of(context).canPop();
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(36)),
      child: AuroraBackground(
        tone: AuroraTone.deep,
        child: Padding(
          padding: EdgeInsets.fromLTRB(8, top + 4, 8, 52),
          child: Column(
            children: [
              Row(
                children: [
                  if (canPop)
                    IconButton(
                      tooltip: 'Retour',
                      onPressed: () => context.pop(),
                      icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                    )
                  else
                    const SizedBox(width: 48),
                  const Expanded(
                    child: Text(
                      'Mon profil',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800),
                    ),
                  ),
                  const SizedBox(width: 48),
                ],
              ),
              const SizedBox(height: 14),
              Semantics(
                button: true,
                label: me.avatarFileId == null ? 'Ajouter une photo de profil' : 'Changer la photo de profil',
                excludeSemantics: true,
                child: GestureDetector(
                  key: const Key('profilePhoto'),
                  onTap: busy ? null : onPhoto,
                  child: SizedBox(
                    width: 124,
                    height: 124,
                    child: Stack(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: const SweepGradient(
                              colors: [AppColors.glow, Color(0xFFFFC08A), Color(0xFF8E7CF6), AppColors.glow],
                            ),
                            boxShadow: [BoxShadow(color: AppColors.glow.withValues(alpha: 0.35), blurRadius: 28)],
                          ),
                          child: Container(
                            padding: const EdgeInsets.all(3),
                            decoration: const BoxDecoration(color: AppColors.deep, shape: BoxShape.circle),
                            child: busy
                                ? const SizedBox(
                                    width: 110,
                                    height: 110,
                                    child: Center(child: CircularProgressIndicator(color: AppColors.glow)),
                                  )
                                : const MeAvatar(size: 110),
                          ),
                        ),
                        const Positioned(
                          right: 2,
                          bottom: 2,
                          child: GlossyOrb(icon: Icons.photo_camera_rounded, color: AppColors.green, size: 38),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                me.fullName ?? '',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 23,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 2),
              Text('+221 ${displayPhone(me.phone)}', style: const TextStyle(color: Color(0xFFCDE9DD), fontSize: 14)),
              if (roleLabel != null) ...[
                const SizedBox(height: 12),
                Glass(
                  tone: GlassTone.dark,
                  radius: 20,
                  blur: 10,
                  shadow: false,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.verified_rounded, size: 16, color: AppColors.glow),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          roleLabel!,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children, this.action});
  final String title;
  final List<Widget> children;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Glass(
    radius: 24,
    padding: const EdgeInsets.fromLTRB(4, 10, 4, 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 2, 6, 2),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                ),
              ),
              ?action,
            ],
          ),
        ),
        ...children,
      ],
    ),
  );
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
    this.hint,
    this.muted = false,
    this.trailing,
    this.onTap,
  });
  final IconData icon;
  final Color color;
  final String label;
  final String value;
  final String? hint;
  final bool muted;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(16),
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(fontSize: 12, color: AppColors.muted, fontWeight: FontWeight.w600),
                ),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: muted ? AppColors.muted : AppColors.ink,
                  ),
                ),
                if (hint != null) Text(hint!, style: const TextStyle(fontSize: 11.5, color: AppColors.muted)),
              ],
            ),
          ),
          if (trailing != null)
            trailing!
          else if (onTap != null)
            const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
        ],
      ),
    ),
  );
}

class _EditProfileSheet extends ConsumerStatefulWidget {
  const _EditProfileSheet({required this.me});
  final Me me;
  @override
  ConsumerState<_EditProfileSheet> createState() => _EditProfileSheetState();
}

class _EditProfileSheetState extends ConsumerState<_EditProfileSheet> {
  late final _name = TextEditingController(text: widget.me.fullName ?? '');
  late final _email = TextEditingController(text: widget.me.email ?? '');
  String? _nameError;
  String? _emailError;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final email = _email.text.trim();
    setState(() {
      _nameError = name.length < 2 ? 'Entrez votre prénom et votre nom' : null;
      _emailError = email.isNotEmpty && !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)
          ? 'Adresse e-mail invalide'
          : null;
    });
    if (_nameError != null || _emailError != null) return;
    setState(() => _busy = true);
    try {
      await ref.read(authProvider.notifier).updateProfile(fullName: name, email: email);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        showError(context, e);
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Mes informations', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 14),
        TextField(
          key: const Key('profileName'),
          controller: _name,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(labelText: 'Prénom et nom', errorText: _nameError),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('profileEmail'),
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          decoration: InputDecoration(labelText: 'E-mail (facultatif)', errorText: _emailError),
          onSubmitted: (_) => _save(),
        ),
        const SizedBox(height: 16),
        BusyButton(label: 'Enregistrer', busy: _busy, onPressed: _save),
      ],
    ),
  );
}
