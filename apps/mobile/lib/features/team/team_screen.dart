import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth/pin_screen.dart' show confirmSensitive;
import '../../core/api/api_client.dart';
import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../auth/auth_controller.dart';

/// Couleur d'un rôle (pastilles et étiquettes).
Color roleColor(String role) => switch (role) {
  'owner' => const Color(0xFF0A8453),
  'manager' => const Color(0xFF2F6FDB),
  'cashier' => const Color(0xFFD9822B),
  _ => const Color(0xFF7A5AF8),
};

/// Ouvre WhatsApp (remplaçable dans les tests).
final openUrlProvider = Provider<Future<bool> Function(Uri)>(
  (ref) =>
      (uri) => launchUrl(uri, mode: LaunchMode.externalApplication),
);

/// Message d'invitation à envoyer par WhatsApp.
String inviteMessage({required String business, required String phone, String? name}) =>
    'Bonjour${name == null || name.isEmpty ? '' : ' ${firstName(name)}'}, je t’ai ajouté(e) à l’équipe de $business sur Sama360. '
    'Installe l’application et connecte-toi avec ton numéro ${intlPhone(phone)} : '
    'un code te sera envoyé par SMS.';

class TeamScreen extends ConsumerWidget {
  const TeamScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final members = ref.watch(membersProvider);
    final canInvite = ref.can('members:invite');
    final canManage = ref.can('members:manage');
    final meId = ref.watch(authProvider).value?.me?.id;

    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Mon équipe', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      floatingActionButton: canInvite
          ? FloatingActionButton.extended(
              onPressed: () => _invite(context, ref),
              backgroundColor: AppColors.green,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.person_add_alt_1_rounded),
              label: const Text('Inviter', style: TextStyle(fontWeight: FontWeight.w800)),
            )
          : null,
      body: AsyncView<List<Member>>(
        value: members,
        onRetry: () => ref.invalidate(membersProvider),
        data: (list) {
          final active = list.where((m) => m.status == 'active').length;
          final waiting = list.where((m) => m.status == 'invited').length;
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(membersProvider),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: StatTile(label: 'Membres actifs', value: '$active'),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: StatTile(label: 'Invitations en attente', value: '$waiting', warn: waiting > 0),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                for (final m in list)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _MemberCard(
                      member: m,
                      isMe: m.userId == meId,
                      onTap: canManage && !m.isOwner && m.userId != meId ? () => _manage(context, ref, m) : null,
                    ),
                  ),
                if (list.length <= 1)
                  Padding(
                    padding: EdgeInsets.fromLTRB(12, 12, 12, 0),
                    child: Text(
                      'Ajoutez un vendeur ou un gérant : chacun se connecte avec son propre numéro '
                      'et ne voit que ce que son rôle permet.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.muted),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _invite(BuildContext context, WidgetRef ref) async {
    final invited = await showModalBottomSheet<({String phone, String? name})>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _InviteSheet(),
    );
    if (invited == null || !context.mounted) return;
    ref.invalidate(membersProvider);
    final business = ref.read(authProvider).value?.business?.name ?? 'notre boutique';
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.how_to_reg_rounded, color: AppColors.green, size: 46),
        title: const Text('Invitation enregistrée'),
        content: Text(
          '${invited.name ?? intlPhone(invited.phone)} pourra se connecter avec son numéro. '
          'Prévenez-le par WhatsApp ?',
          textAlign: TextAlign.center,
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.whatsapp,
                  foregroundColor: const Color(0xFF08361A),
                ),
                onPressed: () async {
                  Navigator.pop(ctx);
                  final text = inviteMessage(business: business, phone: invited.phone, name: invited.name);
                  final digits = invited.phone.replaceAll(RegExp(r'\D'), '');
                  await ref.read(openUrlProvider)(Uri.parse('https://wa.me/$digits?text=${Uri.encodeComponent(text)}'));
                },
                icon: const Icon(Icons.chat_rounded),
                label: const Text('Prévenir par WhatsApp'),
              ),
              const SizedBox(height: 8),
              CancelButton(label: 'Plus tard', onPressed: () => Navigator.pop(ctx)),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _manage(BuildContext context, WidgetRef ref, Member m) => showModalBottomSheet<void>(
    useRootNavigator: true,
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ManageSheet(member: m),
  );
}

class _MemberCard extends ConsumerWidget {
  const _MemberCard({required this.member, required this.isMe, this.onTap});
  final Member member;
  final bool isMe;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = member;
    final color = roleColor(m.role);
    final (statusLabel, statusColor) = switch (m.status) {
      'invited' => ('Invité · en attente de connexion', AppColors.warnText),
      'suspended' => ('Accès suspendu', AppColors.danger),
      _ => (null, AppColors.muted),
    };
    return Glass(
      radius: 20,
      blur: 12,
      onTap: onTap,
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Opacity(
            opacity: m.status == 'suspended' ? 0.5 : 1,
            child: Avatar(
              name: m.fullName ?? m.phone,
              size: 48,
              bg: color.withValues(alpha: 0.14),
              fg: color,
              imageUrl: m.avatarFileId == null ? null : ref.read(repoProvider).fileUrl(m.avatarFileId!),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isMe ? '${m.displayName} (moi)' : m.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                ),
                Text(intlPhone(m.phone), style: TextStyle(color: AppColors.muted, fontSize: 13)),
                if (statusLabel != null)
                  Text(
                    statusLabel,
                    style: TextStyle(color: statusColor, fontSize: 12, fontWeight: FontWeight.w700),
                  ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
            child: Text(
              m.roleName,
              style: TextStyle(
                color: HSLColor.fromColor(color).withLightness(0.32).toColor(),
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          if (onTap != null) Icon(Icons.chevron_right_rounded, color: AppColors.muted),
        ],
      ),
    );
  }
}

/// Choix du rôle avec l'explication de ce qu'il permet.
class _RolePicker extends StatelessWidget {
  const _RolePicker({required this.value, required this.onChanged});
  final TeamRole? value;
  final ValueChanged<TeamRole> onChanged;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final r in TeamRole.values)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Semantics(
            selected: value == r,
            button: true,
            child: Material(
              color: value == r ? roleColor(r.api).withValues(alpha: 0.10) : AppColors.surface(0.7),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: value == r ? roleColor(r.api) : AppColors.line, width: value == r ? 2 : 1),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => onChanged(r),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Icon(
                        value == r ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                        color: value == r ? roleColor(r.api) : AppColors.muted,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(r.label, style: const TextStyle(fontWeight: FontWeight.w800)),
                            Text(r.description, style: TextStyle(fontSize: 12.5, color: AppColors.muted)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
    ],
  );
}

class _InviteSheet extends ConsumerStatefulWidget {
  const _InviteSheet();
  @override
  ConsumerState<_InviteSheet> createState() => _InviteSheetState();
}

class _InviteSheetState extends ConsumerState<_InviteSheet> {
  final _phone = TextEditingController();
  final _name = TextEditingController();
  TeamRole _role = TeamRole.cashier;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _phone.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final phone = localPhone(_phone.text, ref.read(countryProvider));
    if (phone == null) {
      setState(() => _error = invalidPhone(ref.read(countryProvider)));
      return;
    }
    final name = _name.text.trim().isEmpty ? null : _name.text.trim();
    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      await ref.read(repoProvider).inviteMember(phone: phone, fullName: name, role: _role);
      if (mounted) Navigator.pop(context, (phone: phone, name: name));
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.code == 'CONFLICT' ? 'Cette personne fait déjà partie de l’équipe.' : e.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Inviter dans l’équipe', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(
            'La personne se connectera avec ce numéro et recevra un code par SMS.',
            style: TextStyle(color: AppColors.muted),
          ),
          const SizedBox(height: 14),
          TextField(
            key: const Key('invitePhone'),
            controller: _phone,
            autofocus: true,
            keyboardType: TextInputType.phone,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[\d ]')),
              LengthLimitingTextInputFormatter(14),
            ],
            decoration: InputDecoration(
              labelText: 'Numéro',
              prefixText: '+${ref.watch(countryProvider).dial}  ',
              errorText: _error,
              errorMaxLines: 2,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('inviteName'),
            controller: _name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Prénom et nom (facultatif)'),
          ),
          const SizedBox(height: 16),
          const Text('Rôle', style: TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          _RolePicker(value: _role, onChanged: (r) => setState(() => _role = r)),
          const SizedBox(height: 8),
          BusyButton(label: 'Envoyer l’invitation', busy: _busy, onPressed: _send),
        ],
      ),
    ),
  );
}

class _ManageSheet extends ConsumerStatefulWidget {
  const _ManageSheet({required this.member});
  final Member member;
  @override
  ConsumerState<_ManageSheet> createState() => _ManageSheetState();
}

class _ManageSheetState extends ConsumerState<_ManageSheet> {
  late TeamRole? _role = TeamRole.fromApi(widget.member.role);
  bool _busy = false;

  Future<void> _run(Future<void> Function() action, String done) async {
    setState(() => _busy = true);
    try {
      await action();
      ref.invalidate(membersProvider);
      if (mounted) {
        Navigator.pop(context);
        showInfo(context, done);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showError(context, e);
      }
    }
  }

  Future<void> _remove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Retirer ${widget.member.displayName} ?'),
        content: const Text(
          'Cette personne n’aura plus accès à l’entreprise. Ses ventes passées restent enregistrées.',
        ),
        actions: [
          CancelButton(onPressed: () => Navigator.pop(ctx, false)),
          ConfirmButton(label: 'Retirer', onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final who = widget.member.fullName ?? widget.member.phone;
    if (!await confirmSensitive(context, ref, action: 'Retirer $who de l’équipe')) return;
    await _run(() => ref.read(repoProvider).removeMember(widget.member.id), 'Membre retiré');
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.member;
    final repo = ref.read(repoProvider);
    final suspended = m.status == 'suspended';
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.paddingOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(m.displayName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            Text(intlPhone(m.phone), style: TextStyle(color: AppColors.muted)),
            const SizedBox(height: 16),
            const Text('Rôle', style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            _RolePicker(value: _role, onChanged: (r) => setState(() => _role = r)),
            BusyButton(
              label: 'Enregistrer le rôle',
              busy: _busy,
              onPressed: _role == null || _role!.api == m.role
                  ? null
                  : () => _run(() => repo.updateMember(m.id, role: _role), 'Rôle mis à jour'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () => _run(
                      () => repo.updateMember(m.id, status: suspended ? 'active' : 'suspended'),
                      suspended ? 'Accès rétabli' : 'Accès suspendu',
                    ),
              icon: Icon(suspended ? Icons.lock_open_rounded : Icons.block_rounded),
              label: Text(suspended ? 'Rétablir l’accès' : 'Suspendre l’accès'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
              onPressed: _busy ? null : _remove,
              icon: const Icon(Icons.person_remove_rounded),
              label: const Text('Retirer de l’équipe'),
            ),
          ],
        ),
      ),
    );
  }
}
