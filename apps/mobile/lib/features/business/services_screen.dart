import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/trades.dart';
import '../../core/widgets.dart';

/// Services Pro (badge « PRO » à côté de l'interrupteur).
const _proServices = {
  BizService.delivery: ProFeature.delivery,
  BizService.shop: ProFeature.shop,
  BizService.team: ProFeature.team,
  BizService.documents: ProFeature.documents,
  BizService.assistant: ProFeature.assistant,
};

/// Métier et services : l'accueil ne montre que les outils dont le commerce a besoin.
class ServicesScreen extends ConsumerStatefulWidget {
  const ServicesScreen({super.key});

  @override
  ConsumerState<ServicesScreen> createState() => _ServicesScreenState();
}

class _ServicesScreenState extends ConsumerState<ServicesScreen> {
  bool _busy = false;

  Future<void> _save(Future<void> Function() call, {String? done}) async {
    setState(() => _busy = true);
    try {
      await call();
      ref.invalidate(currentBusinessProvider);
      await ref.read(currentBusinessProvider.future);
      if (mounted && done != null) showInfo(context, done);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final business = ref.watch(currentBusinessProvider);
    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Métier et services', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: AsyncView<CurrentBusiness>(
        value: business,
        onRetry: () => ref.invalidate(currentBusinessProvider),
        data: (b) {
          final enabled = enabledServices(b);
          final repo = ref.read(repoProvider);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
            children: [
              const Text('Votre métier', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              const SizedBox(height: 4),
              Text(
                'Choisir un métier remet les services qui vont avec.',
                style: TextStyle(color: AppColors.muted, fontSize: 13),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final e in tradeLabels.entries)
                    Pill(
                      key: Key('trade_${e.key}'),
                      label: e.value,
                      selected: (b.category ?? 'autre') == e.key,
                      onTap: _busy || (b.category ?? 'autre') == e.key
                          ? () {}
                          : () => _save(
                              () => repo.updateTrade(category: e.key, resetServices: true),
                              done: 'Services adaptés : ${e.value}',
                            ),
                    ),
                ],
              ),
              const SizedBox(height: 22),
              const Text('Vos services', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              const SizedBox(height: 4),
              Text(
                'Toujours là : ventes, caisse, stock, clients, dépenses et rapports.',
                style: TextStyle(color: AppColors.muted, fontSize: 13),
              ),
              const SizedBox(height: 10),
              Glass(
                radius: 22,
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  children: [
                    for (final s in BizService.values)
                      SwitchListTile(
                        key: Key('svc_${s.key}'),
                        value: enabled.contains(s),
                        onChanged: _busy
                            ? null
                            : (on) {
                                final next = {...enabled};
                                on ? next.add(s) : next.remove(s);
                                _save(
                                  () => repo.updateTrade(
                                    services: [
                                      for (final x in BizService.values)
                                        if (next.contains(x)) x.key,
                                    ],
                                  ),
                                );
                              },
                        title: Row(
                          children: [
                            Flexible(
                              child: Text(s.label, style: const TextStyle(fontWeight: FontWeight.w700)),
                            ),
                            if (_proServices.containsKey(s)) ...[const SizedBox(width: 6), const _ProBadge()],
                          ],
                        ),
                        subtitle: Text(s.hint, style: const TextStyle(fontSize: 12.5)),
                      ),
                  ],
                ),
              ),
              if (b.services != null) ...[
                const SizedBox(height: 12),
                Center(
                  child: TextButton.icon(
                    key: const Key('services_reset'),
                    onPressed: _busy
                        ? null
                        : () => _save(
                            () => repo.updateTrade(resetServices: true),
                            done: 'Services de votre métier remis',
                          ),
                    icon: const Icon(Icons.restart_alt_rounded, size: 18),
                    label: const Text('Revenir aux services de mon métier'),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _ProBadge extends StatelessWidget {
  const _ProBadge();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(color: const Color(0xFFFF7A00), borderRadius: BorderRadius.circular(6)),
    child: const Text(
      'PRO',
      style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w900),
    ),
  );
}
