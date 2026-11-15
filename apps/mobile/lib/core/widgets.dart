import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'format.dart';
import 'providers.dart';
import 'theme.dart';

/// Affiche chargement / erreur (avec « Réessayer ») / données d'un AsyncValue.
class AsyncView<T> extends StatelessWidget {
  const AsyncView({super.key, required this.value, required this.data, this.onRetry, this.loading});
  final AsyncValue<T> value;
  final Widget Function(T data) data;
  final VoidCallback? onRetry;
  final Widget? loading;

  @override
  Widget build(BuildContext context) {
    return switch (value) {
      AsyncData(:final value) => data(value),
      AsyncError(:final error) => ErrorPanel(message: errorMessage(error), onRetry: onRetry),
      _ => loading ?? const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator())),
    };
  }
}

class ErrorPanel extends StatelessWidget {
  const ErrorPanel({super.key, required this.message, this.onRetry});
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_rounded, size: 40, color: AppColors.muted),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.muted)),
          if (onRetry != null) ...[
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onRetry, child: const Text('Réessayer')),
          ],
        ],
      ),
    ),
  );
}

class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.name, this.size = 44, this.bg = AppColors.green, this.fg = Colors.white});
  final String? name;
  final double size;
  final Color bg;
  final Color fg;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
    child: Text(
      initials(name),
      style: TextStyle(color: fg, fontWeight: FontWeight.w800, fontSize: size * 0.36),
    ),
  );
}

/// Petite carte chiffre + libellé (bandeaux de statistiques).
class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.label, required this.value, this.warn = false});
  final String label;
  final String value;
  final bool warn;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: warn ? AppColors.warnBg : Colors.white,
      border: Border.all(color: warn ? AppColors.warnLine : AppColors.line),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: warn ? AppColors.warnText : AppColors.muted)),
        const SizedBox(height: 2),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: warn ? AppColors.warnText : AppColors.ink),
        ),
      ],
    ),
  );
}

/// Pastille de sélection (catégories, moyens de paiement, filtres).
class Pill extends StatelessWidget {
  const Pill({super.key, required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    button: true,
    child: Material(
      color: selected ? AppColors.ink : Colors.white,
      shape: StadiumBorder(side: BorderSide(color: selected ? AppColors.ink : AppColors.line)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
              color: selected ? Colors.white : AppColors.ink,
            ),
          ),
        ),
      ),
    ),
  );
}

void showError(BuildContext context, Object error) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(errorMessage(error)), backgroundColor: AppColors.danger));
}

void showInfo(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Logo texte « Sama360 ».
class SamaLogo extends StatelessWidget {
  const SamaLogo({super.key, this.size = 30});
  final double size;

  @override
  Widget build(BuildContext context) => Text.rich(
    TextSpan(
      children: [
        TextSpan(text: 'Sama', style: TextStyle(color: AppColors.ink, fontSize: size, fontWeight: FontWeight.w800)),
        TextSpan(text: '360', style: TextStyle(color: AppColors.green, fontSize: size, fontWeight: FontWeight.w800)),
      ],
    ),
    semanticsLabel: 'Sama360',
  );
}

/// Bouton plein avec indicateur de chargement intégré.
class BusyButton extends StatelessWidget {
  const BusyButton({super.key, required this.label, required this.busy, required this.onPressed});
  final String label;
  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => FilledButton(
    onPressed: busy ? null : onPressed,
    child: busy
        ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
        : Text(label),
  );
}

/// Lit une permission dans l'entreprise courante.
extension CanX on WidgetRef {
  bool can(String permission) => watch(canProvider(permission));
}
