import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/display.dart';
import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// Affichage : mode clair / sombre, grands caractères et couleur de la boutique.
class DisplaySettingsScreen extends ConsumerStatefulWidget {
  const DisplaySettingsScreen({super.key});
  @override
  ConsumerState<DisplaySettingsScreen> createState() => _DisplaySettingsScreenState();
}

class _DisplaySettingsScreenState extends ConsumerState<DisplaySettingsScreen> {
  String? _saving; // couleur en cours d'enregistrement

  Future<void> _setBrand(Color? c) async {
    final hex = c == null || c.toARGB32() == defaultBrand.toARGB32() ? null : toHexColor(c);
    setState(() => _saving = hex ?? 'default');
    try {
      await ref.read(repoProvider).updateBrandColor(hex);
      ref.invalidate(currentBusinessProvider);
      await ref.read(currentBusinessProvider.future);
      if (mounted) showInfo(context, 'Couleur de la boutique enregistrée');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _saving = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final display = ref.watch(displaySettingsProvider);
    final notifier = ref.read(displaySettingsProvider.notifier);
    final brand = ref.watch(brandColorProvider);
    final canBrand = ref.can('business:update');
    return AuroraScaffold(
      appBar: AppBar(
        title: const Text('Affichage', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
        children: [
          const _Title('Apparence'),
          Glass(
            radius: 22,
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedButton<ThemeMode>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode_rounded), label: Text('Clair')),
                    ButtonSegment(
                      value: ThemeMode.system,
                      icon: Icon(Icons.brightness_auto_rounded),
                      label: Text('Auto'),
                    ),
                    ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode_rounded), label: Text('Sombre')),
                  ],
                  selected: {display.mode},
                  onSelectionChanged: (s) => notifier.setMode(s.first),
                ),
                const SizedBox(height: 10),
                Text(switch (display.mode) {
                  ThemeMode.system => 'Suit le réglage du téléphone.',
                  ThemeMode.light => 'Fond clair (par défaut) : idéal en plein soleil.',
                  ThemeMode.dark => 'Toujours sombre : repose les yeux et économise la batterie.',
                }, style: TextStyle(color: AppColors.muted, fontSize: 13)),
              ],
            ),
          ),
          const SizedBox(height: 18),
          const _Title('Lecture'),
          Glass(
            radius: 22,
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
            child: Column(
              children: [
                SwitchListTile(
                  value: display.largeText,
                  onChanged: notifier.setLargeText,
                  title: const Text('Grands caractères', style: TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(
                    'Tous les textes de l’app en plus grand.',
                    style: TextStyle(color: AppColors.muted, fontSize: 13),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Text('Aperçu : ', style: TextStyle(color: AppColors.muted)),
                      Text(
                        '${moneyShort(86500)} · 12 ventes',
                        key: const Key('display_preview'),
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (canBrand) ...[
            const SizedBox(height: 18),
            const _Title('Couleur de la boutique'),
            Glass(
              radius: 22,
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Elle colore les boutons de l’app pour toute l’équipe, vos reçus, vos factures et votre boutique en ligne.',
                    style: TextStyle(color: AppColors.muted, fontSize: 13),
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 12,
                    runSpacing: 14,
                    children: [
                      for (final (name, color) in brandChoices)
                        _Swatch(
                          name: name,
                          color: color,
                          selected: brand.toARGB32() == color.toARGB32(),
                          busy:
                              _saving != null &&
                              (_saving == toHexColor(color) || (_saving == 'default' && color == defaultBrand)),
                          onTap: _saving == null ? () => _setBrand(color) : null,
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _BrandPreview(),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Title extends StatelessWidget {
  const _Title(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
    child: Text(text, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
  );
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.name, required this.color, required this.selected, this.busy = false, this.onTap});
  final String name;
  final Color color;
  final bool selected;
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: 'Couleur $name',
    child: InkResponse(
      onTap: onTap,
      radius: 30,
      child: SizedBox(
        width: 56,
        child: Column(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: selected ? AppColors.ink : Colors.transparent, width: 3),
                boxShadow: [
                  BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: 10, offset: const Offset(0, 4)),
                ],
              ),
              child: busy
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white),
                    )
                  : selected
                  ? const Icon(Icons.check_rounded, color: Colors.white)
                  : null,
            ),
            const SizedBox(height: 4),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: AppColors.muted),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Aperçu : bouton, pastille et montant avec la couleur choisie.
class _BrandPreview extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: ConfirmButton(label: 'Encaisser', onPressed: () {}),
      ),
      const SizedBox(width: 12),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(color: AppColors.greenSoft, borderRadius: BorderRadius.circular(999)),
        child: Text(
          'Payée',
          style: TextStyle(color: AppColors.greenDark, fontWeight: FontWeight.w800),
        ),
      ),
    ],
  );
}
