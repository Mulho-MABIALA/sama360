import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

const _violet = Color(0xFF7A5AF8);

/// Texte de l'assistant : **gras** rendu en gras, puces « - » en « • ».
List<TextSpan> assistantSpans(String text) {
  final out = <TextSpan>[];
  final clean = text.replaceAllMapped(RegExp(r'^\s*[-*] ', multiLine: true), (_) => '• ');
  final re = RegExp(r'\*\*([^*]+)\*\*');
  var at = 0;
  for (final m in re.allMatches(clean)) {
    if (m.start > at) out.add(TextSpan(text: clean.substring(at, m.start)));
    out.add(
      TextSpan(
        text: m.group(1),
        style: const TextStyle(fontWeight: FontWeight.w800),
      ),
    );
    at = m.end;
  }
  if (at < clean.length) out.add(TextSpan(text: clean.substring(at)));
  return out;
}

/// Assistant IA : questions sur la boutique, réponses tirées des vraies données.
class AssistantScreen extends ConsumerStatefulWidget {
  const AssistantScreen({super.key});

  @override
  ConsumerState<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends ConsumerState<AssistantScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _toBottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_scroll.hasClients) {
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  });

  Future<void> _send([String? text]) async {
    final q = (text ?? _input.text).trim();
    if (q.isEmpty) return;
    _input.clear();
    HapticFeedback.selectionClick();
    _toBottom();
    try {
      await ref.read(assistantChatProvider.notifier).ask(q);
    } catch (e) {
      if (mounted) showError(context, e);
    }
    _toBottom();
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(assistantStatusProvider);
    final chat = ref.watch(assistantChatProvider);
    final remaining = chat.remaining ?? status.value?.remaining;
    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Assistant IA', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          if (chat.messages.isNotEmpty)
            IconButton(
              tooltip: 'Nouvelle conversation',
              onPressed: chat.busy ? null : () => ref.read(assistantChatProvider.notifier).reset(),
              icon: const Icon(Icons.add_comment_rounded),
            ),
        ],
      ),
      body: AsyncView<AssistantStatus>(
        value: status,
        onRetry: () => ref.invalidate(assistantStatusProvider),
        data: (s) {
          if (!s.enabled) return const _Disabled();
          return Column(
            children: [
              Expanded(
                child: chat.messages.isEmpty
                    ? _Welcome(suggestions: s.suggestions, onAsk: _send)
                    : ListView(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                        children: [
                          for (final m in chat.messages) _Bubble(message: m, onRetry: () => _send(m.text)),
                          if (chat.busy) const _Typing(),
                        ],
                      ),
              ),
              _InputBar(controller: _input, busy: chat.busy, remaining: remaining, onSend: () => _send()),
            ],
          );
        },
      ),
    );
  }
}

class _Disabled extends StatelessWidget {
  const _Disabled();

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Glass(
        radius: 24,
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(Icons.auto_awesome_rounded, size: 40, color: _violet),
            const SizedBox(height: 10),
            const Text(
              'L’assistant arrive bientôt',
              key: Key('assistant_disabled'),
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(
              'Il n’est pas encore activé pour votre boutique. Il répondra à vos questions sur vos ventes, '
              'vos clients et votre stock.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.muted, height: 1.35),
            ),
          ],
        ),
      ),
    ],
  );
}

class _Welcome extends StatelessWidget {
  const _Welcome({required this.suggestions, required this.onAsk});
  final List<String> suggestions;
  final ValueChanged<String> onAsk;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
    children: [
      Center(
        child: Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(colors: [Color(0xFF9B7BFF), _violet, Color(0xFF4F7CFF)]),
            boxShadow: [BoxShadow(color: _violet.withValues(alpha: 0.35), blurRadius: 24, offset: const Offset(0, 8))],
          ),
          child: const Icon(Icons.auto_awesome_rounded, color: Colors.white, size: 34),
        ),
      ),
      const SizedBox(height: 14),
      const Text(
        'Posez une question sur votre boutique',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 6),
      Text(
        'Je lis vos vraies données (ventes, clients, stock) pour vous répondre. En français ou en wolof.',
        textAlign: TextAlign.center,
        style: TextStyle(color: AppColors.muted, height: 1.35),
      ),
      const SizedBox(height: 18),
      for (final q in suggestions)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Glass(
            radius: 16,
            onTap: () => onAsk(q),
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            child: Row(
              children: [
                const Icon(Icons.chat_bubble_outline_rounded, size: 18, color: _violet),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(q, style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
                Icon(Icons.north_east_rounded, size: 18, color: AppColors.muted),
              ],
            ),
          ),
        ),
    ],
  );
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.onRetry});
  final ChatMessage message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final m = message;
    final maxW = MediaQuery.sizeOf(context).width * 0.82;
    if (m.fromUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Container(
                constraints: BoxConstraints(maxWidth: maxW),
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                decoration: BoxDecoration(
                  color: m.failed ? AppColors.muted.withValues(alpha: 0.5) : AppColors.green,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(18),
                    topRight: Radius.circular(18),
                    bottomLeft: Radius.circular(18),
                    bottomRight: Radius.circular(5),
                  ),
                ),
                child: Text(m.text, style: TextStyle(color: AppColors.onGreen, height: 1.35)),
              ),
              if (m.failed)
                TextButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('Non envoyé · Réessayer'),
                ),
            ],
          ),
        ),
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            const _Avatar(),
            const SizedBox(width: 8),
            Flexible(
              child: Container(
                constraints: BoxConstraints(maxWidth: maxW - 40),
                child: Glass(
                  radius: 18,
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                  child: SelectableText.rich(
                    TextSpan(children: assistantSpans(m.text)),
                    style: TextStyle(color: AppColors.ink, height: 1.4),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar();

  @override
  Widget build(BuildContext context) => Container(
    width: 30,
    height: 30,
    decoration: const BoxDecoration(
      shape: BoxShape.circle,
      gradient: LinearGradient(colors: [Color(0xFF9B7BFF), _violet]),
    ),
    child: const Icon(Icons.auto_awesome_rounded, size: 16, color: Colors.white),
  );
}

class _Typing extends StatelessWidget {
  const _Typing();

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const _Avatar(),
        const SizedBox(width: 8),
        Glass(
          radius: 18,
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(
            key: const Key('assistant_typing'),
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: _violet)),
              const SizedBox(width: 10),
              Text('Je regarde vos chiffres…', style: TextStyle(color: AppColors.muted)),
            ],
          ),
        ),
      ],
    ),
  );
}

class _InputBar extends StatelessWidget {
  const _InputBar({required this.controller, required this.busy, required this.remaining, required this.onSend});
  final TextEditingController controller;
  final bool busy;
  final int? remaining;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Glass(
            radius: 24,
            padding: const EdgeInsets.fromLTRB(16, 2, 6, 2),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('assistant_input'),
                    controller: controller,
                    minLines: 1,
                    maxLines: 4,
                    maxLength: 2000,
                    textCapitalization: TextCapitalization.sentences,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => onSend(),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      filled: false,
                      counterText: '',
                      hintText: 'Votre question…',
                    ),
                  ),
                ),
                IconButton.filled(
                  tooltip: 'Envoyer',
                  style: IconButton.styleFrom(backgroundColor: _violet, foregroundColor: Colors.white),
                  onPressed: busy ? null : onSend,
                  icon: const Icon(Icons.arrow_upward_rounded),
                ),
              ],
            ),
          ),
          if (remaining != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                remaining == 0
                    ? 'Plus de questions pour aujourd’hui'
                    : '$remaining question${remaining! > 1 ? 's' : ''} restante${remaining! > 1 ? 's' : ''} aujourd’hui',
                style: TextStyle(color: AppColors.muted, fontSize: 11.5),
              ),
            ),
        ],
      ),
    ),
  );
}
