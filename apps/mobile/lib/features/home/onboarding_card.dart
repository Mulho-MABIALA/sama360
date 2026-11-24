import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/biometrics.dart';
import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../business/business_logo.dart' show changeBusinessLogo;
import '../business/business_screen.dart' show focusLabels;

/// Une étape du guide : texte, conseil, icône, écran où la faire.
class StepInfo {
  const StepInfo(this.title, this.hint, this.icon, this.route);
  final String title;
  final String hint;
  final IconData icon;
  final String route;
}

StepInfo stepInfo(String key, {BiometricKind? bio}) => switch (key) {
  'add_products' => const StepInfo(
    'Ajouter vos produits',
    'Ou scannez leurs codes-barres',
    Icons.inventory_2_rounded,
    '/products/new',
  ),
  'add_services' => const StepInfo(
    'Ajouter vos prestations',
    'Avec leur prix et leur durée',
    Icons.content_cut_rounded,
    '/products/new?service=1',
  ),
  'first_sale' => const StepInfo(
    'Faire votre première vente',
    'Le reçu part sur WhatsApp',
    Icons.point_of_sale_rounded,
    '/pos',
  ),
  'first_appointment' => const StepInfo(
    'Noter un premier rendez-vous',
    'Rappel WhatsApp au client',
    Icons.event_available_rounded,
    '/booking/new',
  ),
  'logo_phone' => const StepInfo(
    'Ajouter votre logo',
    'Il apparaît sur vos reçus et factures',
    Icons.storefront_rounded,
    '/account',
  ),
  'shop_online' => const StepInfo(
    'Ouvrir votre boutique en ligne',
    'Vos clients commandent depuis leur téléphone',
    Icons.shopping_bag_rounded,
    '/shop',
  ),
  'booking_online' => const StepInfo(
    'Ouvrir la réservation en ligne',
    'Vos clients réservent un créneau seuls',
    Icons.public_rounded,
    '/booking/settings',
  ),
  'invite_member' => const StepInfo(
    'Inviter un vendeur',
    'Chacun sa caisse, ses droits limités',
    Icons.group_add_rounded,
    '/team',
  ),
  'security' => StepInfo(
    bio == BiometricKind.face ? 'Activer Face ID' : 'Activer l’empreinte digitale',
    'Pour ouvrir l’app et confirmer les actions sensibles',
    bio == BiometricKind.face ? Icons.face_retouching_natural_rounded : Icons.fingerprint_rounded,
    '/account',
  ),
  _ => const StepInfo('Étape', '', Icons.check_rounded, '/'),
};

/// Carte « Premiers pas » de l'accueil (patron) : activité, puis étapes cochées d'après les vraies données.
class OnboardingCard extends ConsumerWidget {
  const OnboardingCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final o = ref.watch(onboardingProvider).value;
    if (o == null || o.dismissed) return const SizedBox.shrink();
    if (o.focus == null) return const _FocusQuestion();

    // L'empreinte n'est pas une étape de démarrage : elle reste dans Mon compte → Sécurité.
    final steps = o.steps;
    final done = steps.where((s) => s.done).length;
    final allDone = done == steps.length;

    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Glass(
        key: const Key('onboarding_card'),
        radius: 24,
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        allDone ? 'Tout est prêt 🎉' : 'Vos premiers pas',
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
                      ),
                      Text(
                        allDone
                            ? 'Votre boutique est bien installée sur Sama360.'
                            : '$done sur ${steps.length} · quelques minutes pour bien démarrer',
                        key: const Key('onboarding_progress'),
                        style: TextStyle(color: AppColors.muted, fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
                TextButton.icon(
                  key: const Key('onboarding_dismiss'),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.danger,
                    backgroundColor: AppColors.danger.withValues(alpha: 0.1),
                    minimumSize: const Size(48, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () async {
                    await ref.read(repoProvider).dismissOnboarding();
                    ref.invalidate(onboardingProvider);
                  },
                  icon: const Icon(Icons.close_rounded, size: 18),
                  label: Text(allDone ? 'Fermer' : 'Masquer', style: const TextStyle(fontWeight: FontWeight.w800)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: steps.isEmpty ? 0 : done / steps.length,
                  minHeight: 8,
                  backgroundColor: AppColors.green.withValues(alpha: 0.12),
                  color: AppColors.green,
                ),
              ),
            ),
            if (!allDone) ...[
              const SizedBox(height: 6),
              for (final s in steps) _StepRow(step: s, info: stepInfo(s.key)),
            ],
          ],
        ),
      ),
    );
  }
}

class _StepRow extends ConsumerWidget {
  const _StepRow({required this.step, required this.info});
  final OnboardingStep step;
  final StepInfo info;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final done = step.done;
    return InkWell(
      key: Key('step_${step.key}'),
      borderRadius: BorderRadius.circular(14),
      onTap: done
          ? null
          : () async {
              // Logo : le choix de l'image s'ouvre tout de suite
              final business = ref.read(currentBusinessProvider).value;
              if (step.key == 'logo_phone' && business != null) {
                await changeBusinessLogo(context, ref, business);
                ref.invalidate(onboardingProvider);
                return;
              }
              await context.push(info.route);
              // De retour : les étapes se recochent d'après les données
              ref.invalidate(onboardingProvider);
            },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: done ? AppColors.green : AppColors.green.withValues(alpha: 0.1),
              ),
              child: Icon(
                done ? Icons.check_rounded : info.icon,
                size: 18,
                color: done ? AppColors.onGreen : AppColors.green,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    info.title,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: done ? AppColors.muted : AppColors.ink,
                      decoration: done ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  if (!done) Text(info.hint, style: TextStyle(color: AppColors.muted, fontSize: 12)),
                ],
              ),
            ),
            if (!done) Icon(Icons.chevron_right_rounded, color: AppColors.muted),
          ],
        ),
      ),
    );
  }
}

/// Boutiques créées avant la question : on demande l'activité directement sur l'accueil.
class _FocusQuestion extends ConsumerStatefulWidget {
  const _FocusQuestion();

  @override
  ConsumerState<_FocusQuestion> createState() => _FocusQuestionState();
}

class _FocusQuestionState extends ConsumerState<_FocusQuestion> {
  bool _busy = false;

  Future<void> _pick(String focus) async {
    setState(() => _busy = true);
    try {
      await ref.read(repoProvider).setFocus(focus);
      ref.invalidate(onboardingProvider);
      ref.invalidate(currentBusinessProvider);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: Glass(
      key: const Key('focus_question'),
      radius: 24,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Que vendez-vous surtout ?', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
          const SizedBox(height: 4),
          Text(
            'Sama360 adapte votre accueil et vous guide pas à pas.',
            style: TextStyle(color: AppColors.muted, fontSize: 12.5),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              for (final (i, e) in focusLabels.entries.indexed) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    key: Key('pick_${e.key}'),
                    onPressed: _busy ? null : () => _pick(e.key),
                    style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                    child: Column(
                      children: [
                        Icon(switch (e.key) {
                          'products' => Icons.inventory_2_rounded,
                          'services' => Icons.content_cut_rounded,
                          _ => Icons.dashboard_customize_rounded,
                        }),
                        const SizedBox(height: 4),
                        Text(e.value, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12.5)),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    ),
  );
}
