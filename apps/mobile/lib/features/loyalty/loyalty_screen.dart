import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../sales/receipt_screen.dart' show receiptActionsProvider, whatsAppUri;

/// « 1 point pour 1 000 F · 100 points = 2 000 F de remise (2 %) ».
String loyaltyRuleText(LoyaltySettings s) {
  final pct = (s.rate * 100);
  final pctText = pct == pct.roundToDouble() ? pct.toStringAsFixed(0) : pct.toStringAsFixed(1).replaceAll('.', ',');
  return '1 point pour ${moneyShort(s.earnPer)} · ${s.rewardPoints} points = ${moneyShort(s.rewardValue)} de réduction '
      '($pctText % reversé)';
}

/// « aujourd’hui », « demain », « dans 5 j » — et la date.
String birthdayWhen(UpcomingBirthday b) {
  final date = DateFormat('d MMMM', 'fr').format(DateTime(2000, b.month, b.day));
  return switch (b.inDays) {
    0 => 'Aujourd’hui · $date',
    1 => 'Demain · $date',
    _ => 'Dans ${b.inDays} j · $date',
  };
}

/// Message d'anniversaire, avec les points du client s'il en a.
String birthdayMessage(UpcomingBirthday b, String business) {
  final name = firstName(b.name);
  final points = b.points > 0 ? ' Vous avez ${b.points} points fidélité à utiliser chez nous.' : '';
  return 'Joyeux anniversaire $name ! Toute l’équipe de $business vous souhaite une belle journée.$points À bientôt !';
}

class LoyaltyScreen extends ConsumerWidget {
  const LoyaltyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dash = ref.watch(loyaltyDashboardProvider);
    final canManage = ref.can('sales:void');
    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Fidélité', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          if (canManage)
            IconButton(
              tooltip: 'Réglages du programme',
              onPressed: () => context.push('/loyalty/settings'),
              icon: const Icon(Icons.tune_rounded),
            ),
        ],
      ),
      body: AsyncView<LoyaltyDashboard>(
        value: dash,
        onRetry: () => ref.invalidate(loyaltyDashboardProvider),
        data: (d) => RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(loyaltyDashboardProvider);
            await ref.read(loyaltyDashboardProvider.future);
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
            children: [
              if (!d.settings.enabled) _Launch(canManage: canManage) else ...[_ProgramCard(dashboard: d)],
              const SizedBox(height: 18),
              _Header(icon: Icons.cake_rounded, title: 'Anniversaires', subtitle: 'Les 30 prochains jours'),
              if (d.birthdays.isEmpty)
                _Hint(
                  text:
                      'Ajoutez la date d’anniversaire dans la fiche de vos clients pour leur souhaiter un bon anniversaire.',
                )
              else
                for (final b in d.birthdays) _BirthdayTile(birthday: b),
              const SizedBox(height: 18),
              _Header(icon: Icons.emoji_events_rounded, title: 'Meilleurs clients', subtitle: '90 derniers jours'),
              if (d.top.isEmpty)
                _Hint(text: 'Choisissez le client au moment de la vente : ses achats et ses points apparaîtront ici.')
              else
                for (final (i, t) in d.top.indexed) _TopTile(rank: i + 1, customer: t, showPoints: d.settings.enabled),
            ],
          ),
        ),
      ),
    );
  }
}

class _Launch extends StatelessWidget {
  const _Launch({required this.canManage});
  final bool canManage;

  @override
  Widget build(BuildContext context) => Glass(
    radius: 24,
    padding: const EdgeInsets.all(18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const GlossyOrb(icon: Icons.stars_rounded, color: Color(0xFFF2A93B), size: 46),
            const SizedBox(width: 12),
            const Expanded(
              child: Text('Faites revenir vos clients', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          'Vos clients gagnent des points à chaque achat et les échangent contre une réduction. '
          'Exemple : 1 point pour 1 000 F, 100 points = 2 000 F de réduction.',
          style: TextStyle(color: AppColors.muted, height: 1.35),
        ),
        const SizedBox(height: 14),
        if (canManage)
          FilledButton.icon(
            onPressed: () => context.push('/loyalty/settings'),
            icon: const Icon(Icons.rocket_launch_rounded),
            label: const Text('Lancer le programme'),
          )
        else
          Text(
            'Demandez au gérant de lancer le programme.',
            style: TextStyle(color: AppColors.muted, fontWeight: FontWeight.w700),
          ),
      ],
    ),
  );
}

class _ProgramCard extends StatelessWidget {
  const _ProgramCard({required this.dashboard});
  final LoyaltyDashboard dashboard;

  @override
  Widget build(BuildContext context) {
    final d = dashboard;
    return Sheen(
      radius: 26,
      child: Glass(
        tone: GlassTone.dark,
        radius: 26,
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.stars_rounded, color: Color(0xFFFFC857)),
                SizedBox(width: 8),
                Text(
                  'Programme actif',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(loyaltyRuleText(d.settings), style: const TextStyle(color: Color(0xFFCDE9DD), fontSize: 12.5)),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: _Stat(label: 'Clients avec des points', value: '${d.members}'),
                ),
                Expanded(
                  child: _Stat(label: 'Points en cours', value: '${d.pointsOutstanding}'),
                ),
                Expanded(
                  child: _Stat(label: 'Points utilisés', value: '${d.pointsRedeemed}'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        value,
        style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800),
      ),
      Text(label, style: const TextStyle(color: Color(0xFFCDE9DD), fontSize: 11.5)),
    ],
  );
}

class _Header extends StatelessWidget {
  const _Header({required this.icon, required this.title, required this.subtitle});
  final IconData icon;
  final String title;
  final String subtitle;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
    child: Row(
      children: [
        Icon(icon, size: 20, color: AppColors.green),
        const SizedBox(width: 8),
        Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
        const Spacer(),
        Text(subtitle, style: TextStyle(color: AppColors.muted, fontSize: 12)),
      ],
    ),
  );
}

class _Hint extends StatelessWidget {
  const _Hint({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Glass(
    radius: 18,
    padding: const EdgeInsets.all(14),
    child: Text(text, style: TextStyle(color: AppColors.muted)),
  );
}

class _BirthdayTile extends ConsumerWidget {
  const _BirthdayTile({required this.birthday});
  final UpcomingBirthday birthday;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final b = birthday;
    final today = b.inDays == 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Glass(
        radius: 18,
        tint: today ? const Color(0xFFF2A93B) : null,
        onTap: () => context.push('/customers/${b.customerId}'),
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Row(
          children: [
            Avatar(name: b.name, size: 42),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(b.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                  Text(
                    birthdayWhen(b),
                    style: TextStyle(
                      color: today ? AppColors.warn : AppColors.muted,
                      fontWeight: today ? FontWeight.w800 : FontWeight.w500,
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ),
            ),
            if ((b.phone ?? '').isNotEmpty)
              IconButton.filledTonal(
                tooltip: 'Souhaiter l’anniversaire de ${b.name}',
                onPressed: () async {
                  final business = (await ref.read(currentBusinessProvider.future)).name;
                  HapticFeedback.selectionClick();
                  final ok = await ref
                      .read(receiptActionsProvider)
                      .openWhatsApp(whatsAppUri(birthdayMessage(b, business), phone: b.phone));
                  if (!ok && context.mounted) showInfo(context, 'Impossible d’ouvrir WhatsApp');
                },
                icon: const Icon(Icons.cake_rounded),
              ),
          ],
        ),
      ),
    );
  }
}

class _TopTile extends StatelessWidget {
  const _TopTile({required this.rank, required this.customer, required this.showPoints});
  final int rank;
  final TopCustomer customer;
  final bool showPoints;

  @override
  Widget build(BuildContext context) {
    final c = customer;
    final medal = switch (rank) {
      1 => const Color(0xFFE0A100),
      2 => const Color(0xFF9AA5AE),
      3 => const Color(0xFFB0703A),
      _ => null,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Glass(
        radius: 18,
        onTap: () => context.push('/customers/${c.customerId}'),
        padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: medal != null
                  ? Icon(Icons.emoji_events_rounded, color: medal, size: 24)
                  : Text(
                      '$rank',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.muted, fontWeight: FontWeight.w800),
                    ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(c.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                  Text(
                    '${c.visits} achat${c.visits > 1 ? 's' : ''}${showPoints ? ' · ${c.points} pts' : ''}',
                    style: TextStyle(color: AppColors.muted, fontSize: 12.5),
                  ),
                ],
              ),
            ),
            Text(moneyShort(c.spent), style: const TextStyle(fontWeight: FontWeight.w800)),
          ],
        ),
      ),
    );
  }
}

/// Réglages du programme : activer, points gagnés, valeur d'une récompense.
class LoyaltySettingsScreen extends ConsumerStatefulWidget {
  const LoyaltySettingsScreen({super.key});
  @override
  ConsumerState<LoyaltySettingsScreen> createState() => _LoyaltySettingsScreenState();
}

class _LoyaltySettingsScreenState extends ConsumerState<LoyaltySettingsScreen> {
  final _earnPer = TextEditingController();
  final _rewardPoints = TextEditingController();
  final _rewardValue = TextEditingController();
  bool _enabled = true;
  bool _loaded = false;
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_earnPer, _rewardPoints, _rewardValue]) {
      c.dispose();
    }
    super.dispose();
  }

  void _load(LoyaltySettings s) {
    if (_loaded) return;
    _loaded = true;
    // Ouvrir cet écran, c'est vouloir lancer ou régler le programme : actif par défaut.
    _enabled = true;
    _earnPer.text = '${s.earnPer}';
    _rewardPoints.text = '${s.rewardPoints}';
    _rewardValue.text = '${s.rewardValue}';
  }

  LoyaltySettings? get _draft {
    final e = int.tryParse(_earnPer.text), p = int.tryParse(_rewardPoints.text), v = int.tryParse(_rewardValue.text);
    if (e == null || p == null || v == null || e < 50 || p < 1 || v < 50) return null;
    return LoyaltySettings(enabled: _enabled, earnPer: e, rewardPoints: p, rewardValue: v);
  }

  Future<void> _save() async {
    final d = _draft;
    if (d == null) return showInfo(context, 'Vérifiez les montants');
    if (d.rate > 1) return showInfo(context, 'La réduction ne peut pas dépasser ce que le client a dépensé');
    setState(() => _saving = true);
    try {
      await ref.read(repoProvider).saveLoyaltySettings(d);
      refreshLoyalty(ref);
      if (!mounted) return;
      showInfo(context, d.enabled ? 'Programme de fidélité enregistré' : 'Programme de fidélité désactivé');
      context.pop();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(loyaltySettingsProvider);
    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Programme de fidélité', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: AsyncView<LoyaltySettings>(
        value: settings,
        onRetry: () => ref.invalidate(loyaltySettingsProvider),
        data: (s) {
          _load(s);
          final d = _draft;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
            children: [
              Glass(
                radius: 22,
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
                child: SwitchListTile(
                  value: _enabled,
                  onChanged: (v) => setState(() => _enabled = v),
                  title: const Text('Programme actif', style: TextStyle(fontWeight: FontWeight.w800)),
                  subtitle: Text(
                    _enabled ? 'Les clients gagnent des points à chaque achat' : 'Les points restent gardés',
                    style: TextStyle(color: AppColors.muted, fontSize: 13),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Glass(
                radius: 22,
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _NumberField(
                      key: const Key('earnPer'),
                      controller: _earnPer,
                      label: 'Montant dépensé pour gagner 1 point',
                      suffix: 'F',
                      onChanged: () => setState(() {}),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _NumberField(
                            key: const Key('rewardPoints'),
                            controller: _rewardPoints,
                            label: 'Points pour une récompense',
                            suffix: 'pts',
                            onChanged: () => setState(() {}),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _NumberField(
                            key: const Key('rewardValue'),
                            controller: _rewardValue,
                            label: 'Réduction offerte',
                            suffix: 'F',
                            onChanged: () => setState(() {}),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    if (d != null)
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(color: AppColors.greenSoft, borderRadius: BorderRadius.circular(14)),
                        child: Text(
                          'Un client qui dépense ${moneyShort(d.earnPer * d.rewardPoints)} gagne '
                          '${moneyShort(d.rewardValue)} de réduction.\n${loyaltyRuleText(d)}',
                          key: const Key('loyalty_preview'),
                          style: TextStyle(color: AppColors.greenDark, fontWeight: FontWeight.w700, height: 1.35),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              BusyButton(label: 'Enregistrer', busy: _saving, onPressed: _save),
            ],
          );
        },
      ),
    );
  }
}

class _NumberField extends StatelessWidget {
  const _NumberField({super.key, required this.controller, required this.label, required this.suffix, this.onChanged});
  final TextEditingController controller;
  final String label;
  final String suffix;
  final VoidCallback? onChanged;
  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    keyboardType: TextInputType.number,
    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
    decoration: InputDecoration(labelText: label, suffixText: suffix),
    onChanged: (_) => onChanged?.call(),
  );
}
