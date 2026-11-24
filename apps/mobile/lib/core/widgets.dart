import 'dart:math' as math;

import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'api/api_client.dart' show ApiException;
import 'countries.dart';
import 'format.dart';
import 'models.dart' show PayMethod;
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
      // Boutique suspendue par l'équipe Sama360 : rien à réessayer
      AsyncError(:final error) when error is ApiException && error.code == 'BUSINESS_SUSPENDED' => ErrorPanel(
        message: errorMessage(error),
        icon: Icons.block_rounded,
      ),
      // Limite de la version gratuite (ex. rapports de plus de 30 jours) : on propose Pro, pas « Réessayer »
      AsyncError(:final error) when error is ApiException && error.code == 'PRO_REQUIRED' => ProLockPanel(
        message: errorMessage(error),
        feature: (error.details as Map?)?['feature'] as String?,
      ),
      AsyncError(:final error) => ErrorPanel(message: errorMessage(error), onRetry: onRetry),
      // Squelette plutôt qu'un rond qui tourne : l'écran paraît prêt plus vite, surtout en 3G.
      _ => loading ?? const SkeletonList(),
    };
  }
}

/// Fonction ou limite Pro atteinte, à la place du contenu de l'écran.
class ProLockPanel extends StatelessWidget {
  const ProLockPanel({super.key, required this.message, this.feature});
  final String message;
  final String? feature;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.workspace_premium_rounded, size: 44, color: Color(0xFFFF7A00)),
          const SizedBox(height: 12),
          Text(
            message,
            key: const Key('pro_lock_message'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            key: const Key('pro_lock_open'),
            style: accentButtonStyle(),
            onPressed: () => GoRouter.of(context).push('/pro${feature == null ? '' : '?feature=$feature'}'),
            icon: const Icon(Icons.workspace_premium_rounded, size: 18),
            label: const Text('Voir Sama360 Pro'),
          ),
        ],
      ),
    ),
  );
}

/// Limite gratuite atteinte pendant une action : feuille qui explique et mène à Pro.
Future<void> showProOffer(BuildContext context, {required String message, String? feature}) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.workspace_premium_rounded, size: 44, color: Color(0xFFFF7A00)),
              const SizedBox(height: 10),
              Text(
                message,
                key: const Key('pro_offer_message'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
              ),
              const SizedBox(height: 6),
              Text(
                'Sama360 Pro : tout compris, prix fixe, sans commission. Dès 1 500 F la semaine.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.muted),
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 52,
                child: FilledButton(
                  key: const Key('pro_offer_open'),
                  style: accentButtonStyle(),
                  onPressed: () {
                    Navigator.of(sheet).pop();
                    GoRouter.of(context).push('/pro${feature == null ? '' : '?feature=$feature'}');
                  },
                  child: const Text('Voir Sama360 Pro'),
                ),
              ),
              TextButton(onPressed: () => Navigator.of(sheet).pop(), child: const Text('Plus tard')),
            ],
          ),
        ),
      ),
    );

class ErrorPanel extends StatelessWidget {
  const ErrorPanel({super.key, required this.message, this.onRetry, this.icon = Icons.cloud_off_rounded});
  final String message;
  final VoidCallback? onRetry;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: AppColors.muted),
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
/// Logo d'un moyen de paiement : vrais logos Wave et Orange Money, icône pour les autres.
class PayLogo extends StatelessWidget {
  const PayLogo(this.method, {super.key, this.size = 22, this.color});
  final PayMethod? method; // null = crédit
  final double size;
  final Color? color;

  static const _assets = {
    PayMethod.wave: 'assets/pay/wave.png',
    PayMethod.orangeMoney: 'assets/pay/orange_money.png',
    PayMethod.mtnMomo: 'assets/pay/mtn_momo.png',
    PayMethod.moovMoney: 'assets/pay/moov_money.png',
    PayMethod.airtelMoney: 'assets/pay/airtel_money.png',
  };

  static IconData iconOf(PayMethod? m) => switch (m) {
    null => Icons.menu_book_rounded,
    PayMethod.cash => Icons.payments_rounded,
    PayMethod.card => Icons.credit_card_rounded,
    PayMethod.transfer => Icons.account_balance_rounded,
    PayMethod.cheque => Icons.receipt_rounded,
    _ => Icons.phone_android_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final asset = _assets[method];
    if (asset == null) return Icon(iconOf(method), size: size, color: color);
    return ClipRRect(
      borderRadius: BorderRadius.circular(method == PayMethod.orangeMoney ? size : size * 0.28),
      child: Image.asset(asset, width: size, height: size, fit: BoxFit.cover, semanticLabel: method!.label),
    );
  }
}

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

/// Couleurs de marque d'un moyen de paiement : (fond doux, couleur vive, texte foncé).
(Color, Color, Color) payBrand(PayMethod m) => switch (m) {
  PayMethod.wave => (const Color(0xFFEAF5FE), const Color(0xFF1D9BF0), const Color(0xFF0B4F82)),
  PayMethod.orangeMoney => (const Color(0xFFFFF1E6), const Color(0xFFF07B14), const Color(0xFF8A3D00)),
  PayMethod.freeMoney => (const Color(0xFFFDE8E8), const Color(0xFFCD1E25), const Color(0xFF7A0000)),
  PayMethod.mtnMomo => (const Color(0xFFFFF7D6), const Color(0xFFE0B400), const Color(0xFF5C4A00)),
  PayMethod.moovMoney => (const Color(0xFFE6F1FA), const Color(0xFF0066B3), const Color(0xFF003B66)),
  PayMethod.airtelMoney => (const Color(0xFFFDE8E8), const Color(0xFFE40000), const Color(0xFF7A0000)),
  _ => (AppColors.greenSoft, AppColors.green, AppColors.greenDark),
};

/// Choix d'un moyen de paiement : logo + nom, aux couleurs de la marque quand il est choisi.
class PayMethodChip extends StatelessWidget {
  const PayMethodChip(this.method, {super.key, required this.selected, required this.onTap});
  final PayMethod method;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (soft, strong, text) = payBrand(method);
    final (bg, fg) = AppColors.tone(soft, text);
    return TapTarget(
      onTap: onTap,
      child: Semantics(
        selected: selected,
        button: true,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          decoration: BoxDecoration(
            color: selected ? bg : AppColors.surface(0.85),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: selected ? strong : AppColors.glassLine, width: selected ? 2 : 1.2),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    PayLogo(method, size: 22, color: strong),
                    const SizedBox(width: 8),
                    Text(
                      method.label,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                        color: selected ? (AppColors.isDark ? fg : text) : AppColors.ink,
                      ),
                    ),
                    if (selected) ...[
                      const SizedBox(width: 6),
                      Icon(Icons.check_circle_rounded, size: 16, color: strong),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Boutons d'une boîte de dialogue côte à côte, de même taille (Annuler | Valider).
/// Au-delà de deux boutons, on garde la disposition standard.
List<Widget> dialogActions(List<Widget> children) {
  if (children.length != 2) return children;
  return [
    Row(
      children: [
        Expanded(child: SizedBox(height: 50, child: children[0])),
        const SizedBox(width: 10),
        Expanded(child: SizedBox(height: 50, child: children[1])),
      ],
    ),
  ];
}

void showError(BuildContext context, Object error) {
  final text = error is String ? error : errorMessage(error);
  // Fonction Pro : on propose de passer à Pro plutôt qu'une simple erreur
  if (error is ApiException && error.code == 'PRO_REQUIRED') {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    showProOffer(context, message: text, feature: (error.details as Map?)?['feature'] as String?);
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

/// Style du bouton principal d'un écran (couleur d'accent, légère lueur).
ButtonStyle accentButtonStyle() => FilledButton.styleFrom(
  backgroundColor: AppColors.accent,
  foregroundColor: AppColors.onAccent,
  disabledBackgroundColor: AppColors.accent.withValues(alpha: 0.35),
  disabledForegroundColor: AppColors.onAccent.withValues(alpha: 0.6),
  elevation: 3,
  shadowColor: AppColors.accent.withValues(alpha: 0.5),
);

/// Bouton plein avec indicateur de chargement intégré.
class BusyButton extends StatelessWidget {
  const BusyButton({
    super.key,
    required this.label,
    required this.busy,
    required this.onPressed,
    this.icon,
    this.accent = false,
  });
  final String label;
  final bool busy;
  final VoidCallback? onPressed;
  final IconData? icon;

  /// Bouton principal de l'écran : couleur d'accent ([AppColors.accent]). Un seul par écran,
  /// sinon il n'attire plus l'œil.
  final bool accent;

  @override
  Widget build(BuildContext context) => FilledButton(
    style: accent ? accentButtonStyle() : null,
    onPressed: busy ? null : onPressed,
    child: busy
        ? SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.5, color: accent ? AppColors.onAccent : Colors.white),
          )
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

/// Écran ouvert sans le droit nécessaire (lien direct, notification…).
class AccessDeniedScreen extends StatelessWidget {
  const AccessDeniedScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(),
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_rounded, size: 56, color: AppColors.muted),
            const SizedBox(height: 14),
            const Text('Accès réservé', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 19)),
            const SizedBox(height: 8),
            Text(
              'Votre rôle ne donne pas accès à cet écran. Demandez au propriétaire de la boutique si vous en avez besoin.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.muted, height: 1.35),
            ),
            const SizedBox(height: 20),
            FilledButton(onPressed: () => context.go('/'), child: const Text('Retour à l’accueil')),
          ],
        ),
      ),
    ),
  );
}

/// « En continuant, vous acceptez les conditions… » avec des liens vers les pages publiques
/// du serveur (/cgu, /confidentialite). [open] ouvre le lien dans le navigateur.
class LegalNotice extends StatelessWidget {
  const LegalNotice({super.key, required this.baseUrl, required this.open});
  final String baseUrl;
  final void Function(Uri) open;

  @override
  Widget build(BuildContext context) {
    final base = baseUrl.replaceAll(RegExp(r'/+$'), '');
    final link = TextStyle(color: AppColors.green, fontWeight: FontWeight.w700, decoration: TextDecoration.underline);
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('En continuant, vous acceptez les ', style: TextStyle(color: AppColors.muted, fontSize: 12.5)),
        InkWell(
          key: const Key('legal_terms'),
          onTap: () => open(Uri.parse('$base/cgu')),
          child: Text('conditions d’utilisation', style: link.copyWith(fontSize: 12.5)),
        ),
        Text(' et la ', style: TextStyle(color: AppColors.muted, fontSize: 12.5)),
        InkWell(
          key: const Key('legal_privacy'),
          onTap: () => open(Uri.parse('$base/confidentialite')),
          child: Text('politique de confidentialité', style: link.copyWith(fontSize: 12.5)),
        ),
        Text('.', style: TextStyle(color: AppColors.muted, fontSize: 12.5)),
      ],
    );
  }
}
