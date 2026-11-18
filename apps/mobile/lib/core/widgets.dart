import 'dart:math' as math;

import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'api/api_client.dart' show ApiException;
import 'countries.dart';
import 'format.dart';
import 'providers.dart';
import 'skeleton.dart';
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
      // Squelette plutôt qu'un rond qui tourne : l'écran paraît prêt plus vite, surtout en 3G.
      _ => loading ?? const SkeletonList(),
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
          Icon(Icons.cloud_off_rounded, size: 40, color: AppColors.muted),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.muted),
          ),
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
  // Paramètre public « bg », champ privé : la couleur par défaut suit la palette (non constante).
  const Avatar({super.key, required this.name, this.size = 44, Color? bg, this.fg = Colors.white, this.imageUrl})
    // ignore: prefer_initializing_formals
    : _bg = bg;
  final String? name;
  final double size;
  final Color? _bg;
  Color get bg => _bg ?? AppColors.green;
  final Color fg;

  /// Photo de profil ; les initiales s'affichent pendant le chargement ou en cas d'erreur.
  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    final letters = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      // Pas de nom (ou seulement un numéro) : silhouette plutôt que « + » ou « ? »
      child: RegExp(r'[A-Za-zÀ-ÿ]').hasMatch(name ?? '')
          ? Text(
              initials(name),
              style: TextStyle(color: fg, fontWeight: FontWeight.w800, fontSize: size * 0.36),
            )
          : Icon(Icons.person_rounded, color: fg, size: size * 0.56),
    );
    if (imageUrl == null) return letters;
    return ClipOval(
      child: Image.network(
        imageUrl!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        semanticLabel: name == null ? 'Photo de profil' : 'Photo de $name',
        cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
        errorBuilder: (_, _, _) => letters,
        loadingBuilder: (_, child, progress) => progress == null ? child : letters,
      ),
    );
  }
}

/// Petite carte chiffre + libellé (bandeaux de statistiques).
class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.label, required this.value, this.warn = false});
  final String label;
  final String value;
  final bool warn;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: warn
            ? (AppColors.isDark
                  ? [AppColors.warnBg, AppColors.warnBg.withValues(alpha: 0.85)]
                  : const [Color(0xFFFFF4E2), Color(0xEBFDEACC)])
            : [AppColors.surface(0.9), AppColors.surface(0.62)],
      ),
      border: Border.all(color: warn ? AppColors.warnLine : AppColors.glassLine, width: 1.2),
      borderRadius: BorderRadius.circular(18),
      boxShadow: const [BoxShadow(color: Color(0x140B3D2E), blurRadius: 18, offset: Offset(0, 8))],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: warn ? AppColors.warnText : AppColors.muted,
          ),
        ),
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
/// Agrandit la zone à toucher à [min]×[min] (48 par défaut, règle Android) sans changer le dessin.
/// Le libellé d'accessibilité couvre toute la zone.
/// Bouton corbeille : toujours rouge et bien visible (icône pleine sur fond rouge pâle).
class TrashButton extends StatelessWidget {
  const TrashButton({super.key, required this.tooltip, required this.onPressed});
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    style: IconButton.styleFrom(
      backgroundColor: AppColors.danger.withValues(alpha: 0.18),
      disabledBackgroundColor: AppColors.danger.withValues(alpha: 0.05),
    ),
    icon: Icon(
      Icons.delete_rounded,
      color: onPressed == null ? AppColors.danger.withValues(alpha: 0.4) : AppColors.danger,
    ),
  );
}

class TapTarget extends StatelessWidget {
  const TapTarget({super.key, required this.onTap, required this.child, this.min = 48});
  final VoidCallback? onTap;
  final Widget child;
  final double min;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      excludeFromSemantics: true,
      onTap: onTap,
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: min, minHeight: min),
        child: Center(widthFactor: 1, heightFactor: 1, child: child),
      ),
    ),
  );
}

class Pill extends StatelessWidget {
  const Pill({super.key, required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => TapTarget(
    onTap: onTap,
    child: Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? AppColors.ink : AppColors.surface(0.72),
        shape: StadiumBorder(side: BorderSide(color: selected ? AppColors.ink : AppColors.glassLine, width: 1.2)),
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
                color: selected ? AppColors.ground : AppColors.ink,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void showError(BuildContext context, Object error) {
  final text = error is String ? error : errorMessage(error);
  // Fonction Pro : on propose de passer à Pro plutôt qu'une simple erreur
  if (error is ApiException && error.code == 'PRO_REQUIRED') {
    final feature = (error.details as Map?)?['feature'];
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          action: SnackBarAction(
            label: 'Passer à Pro',
            onPressed: () => GoRouter.of(context).push('/pro${feature == null ? '' : '?feature=$feature'}'),
          ),
        ),
      );
    return;
  }
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), backgroundColor: AppColors.danger));
}

void showInfo(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Logo texte « Sama360 ».
class SamaLogo extends StatelessWidget {
  const SamaLogo({super.key, this.size = 30, this.onDark = false});
  final double size;
  final bool onDark;

  @override
  Widget build(BuildContext context) => Text.rich(
    TextSpan(
      children: [
        TextSpan(
          text: 'Sama',
          style: TextStyle(color: onDark ? Colors.white : AppColors.ink, fontSize: size, fontWeight: FontWeight.w800),
        ),
        TextSpan(
          text: '360',
          style: TextStyle(
            color: onDark ? AppColors.glow : AppColors.green,
            fontSize: size,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    ),
    semanticsLabel: 'Sama360',
  );
}

/// Bouton plein avec indicateur de chargement intégré.
class BusyButton extends StatelessWidget {
  const BusyButton({super.key, required this.label, required this.busy, required this.onPressed, this.icon});
  final String label;
  final bool busy;
  final VoidCallback? onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => FilledButton(
    onPressed: busy ? null : onPressed,
    child: busy
        ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
        : icon == null
        ? Text(label)
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22),
              const SizedBox(width: 10),
              Flexible(child: Text(label)),
            ],
          ),
  );
}

/// Lit une permission dans l'entreprise courante.
extension CanX on WidgetRef {
  bool can(String permission) => watch(canProvider(permission));
}

/// Bouton qui renonce (Annuler, Retour, Fermer…) : toujours rouge, partout dans l'app.
/// Bouton « Annuler » : neutre (c'est l'action sans risque, elle ne doit pas inquiéter).
class CancelButton extends StatelessWidget {
  const CancelButton({super.key, this.label = 'Annuler', required this.onPressed});
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => TextButton(
    style: TextButton.styleFrom(
      foregroundColor: AppColors.ink,
      backgroundColor: AppColors.ink.withValues(alpha: 0.07),
      minimumSize: const Size(96, 44),
      padding: const EdgeInsets.symmetric(horizontal: 18),
      shape: const StadiumBorder(),
      textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 15, fontWeight: FontWeight.w700),
    ),
    onPressed: onPressed,
    child: Text(label),
  );
}

/// Bouton qui valide (Valider, Créer, Supprimer, Confirmer…) : toujours vert, partout dans l'app.
/// Bouton de confirmation : vert, ou rouge ([danger]) quand l'action supprime, retire ou déconnecte.
class ConfirmButton extends StatelessWidget {
  const ConfirmButton({super.key, required this.label, required this.onPressed, this.danger = false});
  final String label;
  final VoidCallback? onPressed;
  final bool danger;

  @override
  Widget build(BuildContext context) => FilledButton(
    style: FilledButton.styleFrom(
      backgroundColor: danger ? AppColors.danger : AppColors.green,
      foregroundColor: Colors.white,
      minimumSize: const Size(96, 44),
      padding: const EdgeInsets.symmetric(horizontal: 18),
      shape: const StadiumBorder(),
      textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 15, fontWeight: FontWeight.w800),
    ),
    onPressed: onPressed,
    child: Text(label),
  );
}

/// Petit drapeau dessiné (les émojis drapeaux ne s'affichent pas partout).
class CountryFlag extends StatelessWidget {
  const CountryFlag(this.country, {super.key, this.width = 22});
  final Country country;
  final double width;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(3),
    child: CustomPaint(size: Size(width, width * 2 / 3), painter: _FlagPainter(country)),
  );
}

class _FlagPainter extends CustomPainter {
  _FlagPainter(this.country);
  final Country country;

  @override
  void paint(Canvas canvas, Size s) {
    final p = Paint();
    void band(int i, int n, Color c) =>
        canvas.drawRect(Rect.fromLTWH(s.width * i / n, 0, s.width / n, s.height), p..color = c);
    switch (country) {
      case Country.sn:
        band(0, 3, const Color(0xFF00853F));
        band(1, 3, const Color(0xFFFDEF42));
        band(2, 3, const Color(0xFFE31B23));
        final c = Offset(s.width / 2, s.height / 2);
        final r = s.height * 0.2;
        final star = Path();
        for (var k = 0; k < 10; k++) {
          final rad = k.isEven ? r : r * 0.42;
          final a = -math.pi / 2 + k * math.pi / 5;
          final pt = c + Offset(math.cos(a) * rad, math.sin(a) * rad);
          k == 0 ? star.moveTo(pt.dx, pt.dy) : star.lineTo(pt.dx, pt.dy);
        }
        canvas.drawPath(star..close(), p..color = const Color(0xFF00853F));
      case Country.ci:
        band(0, 3, const Color(0xFFF77F00));
        band(1, 3, Colors.white);
        band(2, 3, const Color(0xFF009E60));
      case Country.cg:
        canvas.drawRect(Offset.zero & s, p..color = const Color(0xFFFBDE4A));
        canvas.drawPath(
          Path()
            ..moveTo(0, 0)
            ..lineTo(s.width * 0.68, 0)
            ..lineTo(0, s.height)
            ..close(),
          p..color = const Color(0xFF009543),
        );
        canvas.drawPath(
          Path()
            ..moveTo(s.width, s.height)
            ..lineTo(s.width * 0.32, s.height)
            ..lineTo(s.width, 0)
            ..close(),
          p..color = const Color(0xFFDC241F),
        );
    }
  }

  @override
  bool shouldRepaint(_FlagPainter old) => old.country != country;
}

/// Choix du pays : Sénégal, Côte d'Ivoire, Congo.
class CountryPills extends StatelessWidget {
  const CountryPills({super.key, required this.value, required this.onChanged});
  final Country value;
  final ValueChanged<Country> onChanged;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 0,
    children: [
      for (final c in Country.values)
        TapTarget(
          onTap: () => onChanged(c),
          child: Semantics(
            button: true,
            selected: value == c,
            child: Material(
              key: Key('country_${c.code}'),
              color: value == c ? AppColors.ink : AppColors.surface(0.72),
              shape: StadiumBorder(
                side: BorderSide(color: value == c ? AppColors.ink : AppColors.glassLine, width: 1.2),
              ),
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: () => onChanged(c),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 14, 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CountryFlag(c),
                      const SizedBox(width: 8),
                      Text(
                        c.name,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: value == c ? FontWeight.w700 : FontWeight.w600,
                          color: value == c ? AppColors.ground : AppColors.ink,
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
