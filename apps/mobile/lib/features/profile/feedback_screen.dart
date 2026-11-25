import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/admin_models.dart';
import '../../core/glass.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../auth/auth_controller.dart';
import 'profile_screen.dart' show appVersion;

/// Profil → Suggestions : une idée, un problème… L'équipe Sama360 les lit dans son back office.
class FeedbackScreen extends ConsumerStatefulWidget {
  const FeedbackScreen({super.key});

  @override
  ConsumerState<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends ConsumerState<FeedbackScreen> {
  final _message = TextEditingController();
  FeedbackKind _kind = FeedbackKind.idea;
  bool _busy = false;
  bool _sent = false;

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _message.text.trim();
    if (text.length < 3) {
      showInfo(context, 'Écrivez quelques mots');
      return;
    }
    setState(() => _busy = true);
    try {
      await ref
          .read(repoProvider)
          .sendFeedback(_kind, text, businessId: ref.read(authProvider).value?.business?.id, appVersion: appVersion);
      if (mounted) setState(() => _sent = true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AuroraScaffold(
    appBar: AppBar(
      title: const Text('Suggestions', style: TextStyle(fontWeight: FontWeight.w800)),
    ),
    body: _sent ? _thanks() : _form(),
  );

  Widget _thanks() => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.favorite_rounded, size: 56, color: AppColors.green),
          const SizedBox(height: 14),
          const Text(
            'Merci !',
            key: Key('feedback_thanks'),
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 6),
          Text(
            'L’équipe Sama360 lit chaque message. Vos idées font avancer l’application.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.muted),
          ),
          const SizedBox(height: 20),
          OutlinedButton(
            onPressed: () => setState(() {
              _sent = false;
              _message.clear();
            }),
            child: const Text('Envoyer un autre message'),
          ),
        ],
      ),
    ),
  );

  Widget _form() => ListView(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
    children: [
      Text(
        'Une idée pour améliorer Sama360, un problème, une fonction qui vous manque ? Dites-le-nous.',
        style: TextStyle(color: AppColors.muted),
      ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final k in FeedbackKind.values)
            ChoiceChip(
              key: Key('fb_kind_${k.api}'),
              avatar: Icon(k.icon, size: 18),
              label: Text(k.label),
              selected: _kind == k,
              onSelected: (_) => setState(() => _kind = k),
            ),
        ],
      ),
      const SizedBox(height: 16),
      Glass(
        radius: 20,
        padding: const EdgeInsets.all(4),
        child: TextField(
          key: const Key('fb_message'),
          controller: _message,
          minLines: 6,
          maxLines: 12,
          maxLength: 2000,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            hintText: switch (_kind) {
              FeedbackKind.idea => 'Ex. : pouvoir envoyer le reçu par SMS',
              FeedbackKind.problem => 'Qu’avez-vous fait, et que s’est-il passé ?',
              FeedbackKind.other => 'Votre message',
            },
          ),
        ),
      ),
      const SizedBox(height: 16),
      BusyButton(key: const Key('fb_send'), label: 'Envoyer', busy: _busy, accent: true, onPressed: _send),
    ],
  );
}
