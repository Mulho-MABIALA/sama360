import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/admin_models.dart';
import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/trades.dart';
import '../../core/widgets.dart';
import 'admin_widgets.dart';

/// Back office : suggestions envoyées par les commerçants depuis leur profil.
class AdminFeedbackScreen extends ConsumerStatefulWidget {
  const AdminFeedbackScreen({super.key});

  @override
  ConsumerState<AdminFeedbackScreen> createState() => _AdminFeedbackScreenState();
}

class _AdminFeedbackScreenState extends ConsumerState<AdminFeedbackScreen> {
  FeedbackStatus _status = FeedbackStatus.fresh;

  Future<void> _set(AdminFeedback f, FeedbackStatus status) async {
    try {
      await ref.read(repoProvider).adminSetFeedback(f.id, status);
      ref.invalidate(adminFeedbackProvider);
      ref.invalidate(adminOverviewProvider);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= adminWide;
    final pad = wide ? 28.0 : 16.0;
    final data = ref.watch(adminFeedbackProvider(_status));
    final counts = data.value?.counts;
    return AdminShell(
      section: AdminSection.feedback,
      title: 'Suggestions',
      subtitle: 'Ce que les commerçants vous écrivent',
      actions: [
        IconButton(
          tooltip: 'Actualiser',
          onPressed: () => ref.invalidate(adminFeedbackProvider),
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: pad),
            child: Row(
              children: [
                for (final s in FeedbackStatus.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Pill(
                      key: Key('fb_tab_${s.api}'),
                      label: counts == null ? s.label : '${s.label} (${counts[s] ?? 0})',
                      selected: _status == s,
                      onTap: () => setState(() => _status = s),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: AsyncView(
              value: data,
              onRetry: () => ref.invalidate(adminFeedbackProvider(_status)),
              data: (d) => d.items.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.inbox_rounded, size: 48, color: AppColors.leaf),
                          const SizedBox(height: 8),
                          Text(
                            _status == FeedbackStatus.fresh ? 'Aucune nouvelle suggestion' : 'Rien ici',
                            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                          ),
                        ],
                      ),
                    )
                  : ListView(
                      padding: EdgeInsets.fromLTRB(pad, 0, pad, wide ? 32 : 110),
                      children: [
                        for (final f in d.items)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _FeedbackCard(f: f, onSet: (s) => _set(f, s)),
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

class _FeedbackCard extends StatelessWidget {
  const _FeedbackCard({required this.f, required this.onSet});
  final AdminFeedback f;
  final void Function(FeedbackStatus) onSet;

  @override
  Widget build(BuildContext context) {
    final color = switch (f.kind) {
      FeedbackKind.idea => const Color(0xFFFF7A00),
      FeedbackKind.problem => AppColors.danger,
      FeedbackKind.other => AppColors.muted,
    };
    final who = [if (f.userName != null && f.userName!.isNotEmpty) f.userName!, intlPhone(f.userPhone)].join(' · ');
    final shop = [
      if (f.businessName != null) f.businessName!,
      if (tradeLabels[f.category] != null) tradeLabels[f.category]!,
      if (f.appVersion != null) 'v${f.appVersion}',
    ].join(' · ');
    return Glass(
      key: Key('fb_${f.id}'),
      radius: 20,
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(f.kind.icon, size: 18, color: color),
              const SizedBox(width: 6),
              Text(
                f.kind.label,
                style: TextStyle(color: color, fontWeight: FontWeight.w800),
              ),
              const Spacer(),
              Text(
                DateFormat('d MMM · HH:mm', 'fr').format(f.createdAt),
                style: TextStyle(color: AppColors.muted, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(f.message, style: const TextStyle(fontSize: 15, height: 1.35)),
          const SizedBox(height: 10),
          Text(who, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
          if (shop.isNotEmpty) Text(shop, style: TextStyle(color: AppColors.muted, fontSize: 12.5)),
          const SizedBox(height: 4),
          Wrap(
            spacing: 4,
            children: [
              if (f.businessId != null)
                TextButton.icon(
                  onPressed: () => context.push('/admin/merchants/${f.businessId}'),
                  icon: const Icon(Icons.storefront_rounded, size: 18),
                  label: const Text('Boutique'),
                ),
              if (f.status != FeedbackStatus.read)
                TextButton(
                  key: Key('fb_read_${f.id}'),
                  onPressed: () => onSet(FeedbackStatus.read),
                  child: const Text('Marquer lue'),
                ),
              if (f.status != FeedbackStatus.done)
                TextButton(
                  key: Key('fb_done_${f.id}'),
                  onPressed: () => onSet(FeedbackStatus.done),
                  child: const Text('Traitée'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
