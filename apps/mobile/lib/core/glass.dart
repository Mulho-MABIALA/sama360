import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:material_ui/material_ui.dart';

import 'theme.dart';

/// Animations d'ambiance (fond aurora, reflets). Coupées si le téléphone demande
/// moins d'animations, et dans les tests ([enabled] = false).
abstract final class Motion {
  static bool enabled = true;

  static bool of(BuildContext context) {
    final m = MediaQuery.maybeOf(context);
    return enabled && !(m?.disableAnimations ?? false) && !(m?.accessibleNavigation ?? false);
  }
}

enum AuroraTone { light, deep }

class _Blob {
  const _Blob(this.color, this.center, this.radius, this.phase);
  final Color color;
  final Alignment center;
  final double radius; // fraction du plus grand côté
  final double phase;
}

const _lightBlobs = [
  _Blob(Color(0x8C8BE8BC), Alignment(-1.1, -1.0), 0.75, 0.0),
  _Blob(Color(0x6687D8EC), Alignment(1.2, -0.25), 0.62, 1.7),
  _Blob(Color(0x5CFFC59A), Alignment(-1.0, 0.85), 0.62, 3.1),
  _Blob(Color(0x4DC8B9FF), Alignment(1.1, 1.1), 0.58, 4.4),
];

const _deepBlobs = [
  _Blob(Color(0xB321C98A), Alignment(-1.0, -1.1), 0.85, 0.0),
  _Blob(Color(0x8C0FA3A0), Alignment(1.15, -0.5), 0.7, 2.0),
  _Blob(Color(0x66FF9A4D), Alignment(0.9, 1.15), 0.55, 3.6),
  _Blob(Color(0x598E7CF6), Alignment(-1.1, 1.1), 0.6, 5.0),
];

/// Fond en dégradé « aurora » : nappes de couleur floues qui dérivent lentement.
class AuroraBackground extends StatefulWidget {
  const AuroraBackground({super.key, required this.child, this.tone = AuroraTone.light});
  final Widget child;
  final AuroraTone tone;

  @override
  State<AuroraBackground> createState() => _AuroraBackgroundState();
}

class _AuroraBackgroundState extends State<AuroraBackground> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: const Duration(seconds: 24));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Motion.of(context)) {
      if (!_controller.isAnimating) _controller.repeat();
    } else {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final deep = widget.tone == AuroraTone.deep;
    return CustomPaint(
      painter: _AuroraPainter(
        _controller,
        blobs: deep ? _deepBlobs : _lightBlobs,
        base: deep
            ? const [Color(0xFF042A21), Color(0xFF07473A), Color(0xFF0A5F49)]
            : const [Color(0xFFF3FAF6), Color(0xFFEFF6F3)],
      ),
      child: widget.child,
    );
  }
}

class _AuroraPainter extends CustomPainter {
  _AuroraPainter(this.t, {required this.blobs, required this.base}) : super(repaint: t);
  final Animation<double> t;
  final List<_Blob> blobs;
  final List<Color> base;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: base,
        ).createShader(rect),
    );
    final big = math.max(size.width, size.height);
    final a = t.value * 2 * math.pi;
    for (final b in blobs) {
      final c = b.center
          .withinRect(rect)
          .translate(math.sin(a + b.phase) * big * 0.06, math.cos(a * 0.8 + b.phase) * big * 0.05);
      final r = big * b.radius;
      final circle = Rect.fromCircle(center: c, radius: r);
      canvas.drawCircle(
        c,
        r,
        Paint()..shader = RadialGradient(colors: [b.color, b.color.withValues(alpha: 0)]).createShader(circle),
      );
    }
  }

  @override
  bool shouldRepaint(_AuroraPainter old) => old.blobs != blobs || old.base != base;
}

/// Scaffold posé sur le fond aurora (chaque page reste opaque pendant les transitions).
class AuroraScaffold extends StatelessWidget {
  const AuroraScaffold({
    super.key,
    this.appBar,
    this.body,
    this.bottomNavigationBar,
    this.floatingActionButton,
    this.tone = AuroraTone.light,
    this.extendBody = false,
    this.padBottom = true,
  });
  final PreferredSizeWidget? appBar;
  final Widget? body;
  final Widget? bottomNavigationBar;
  final Widget? floatingActionButton;
  final AuroraTone tone;
  final bool extendBody;

  /// Le fond va jusqu'en bas de l'écran (sous la barre de navigation en verre),
  /// le contenu s'arrête au-dessus.
  final bool padBottom;

  @override
  Widget build(BuildContext context) {
    // Hauteur de la barre de navigation flottante (+ zone système), lue avant le Scaffold.
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return AuroraBackground(
      tone: tone,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBody: extendBody,
        appBar: appBar,
        body: body == null || !padBottom
            ? body
            : Builder(
                builder: (context) {
                  final bottom = MediaQuery.paddingOf(context).bottom;
                  return Padding(
                    padding: EdgeInsets.only(bottom: bottom),
                    child: MediaQuery.removePadding(context: context, removeBottom: true, child: body!),
                  );
                },
              ),
        bottomNavigationBar: bottomNavigationBar,
        floatingActionButton: floatingActionButton == null || !padBottom
            ? floatingActionButton
            : Padding(
                padding: EdgeInsets.only(bottom: bottomInset),
                child: floatingActionButton,
              ),
      ),
    );
  }
}

enum GlassTone { light, dark }

/// Verre dépoli : flou de l'arrière-plan, voile translucide, reflet miroir
/// en haut et liseré lumineux.
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.radius = 24,
    this.blur = 22,
    this.tone = GlassTone.light,
    this.padding = EdgeInsets.zero,
    this.onTap,
    this.shadow = true,
    this.tint,
  });
  final Widget child;
  final double radius;
  final double blur;
  final GlassTone tone;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final bool shadow;

  /// Teinte légère facultative (ex. ambre pour une alerte).
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    final dark = tone == GlassTone.dark;
    Widget content = Padding(padding: padding, child: child);
    if (onTap != null) {
      content = Material(
        type: MaterialType.transparency,
        child: InkWell(borderRadius: r, onTap: onTap, child: content),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: r,
        boxShadow: shadow
            ? [
                BoxShadow(
                  color: dark ? const Color(0x33000000) : const Color(0x170B3D2E),
                  blurRadius: 26,
                  spreadRadius: -6,
                  offset: const Offset(0, 12),
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: r,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: CustomPaint(
            painter: _GlassFillPainter(radius: radius, dark: dark, tint: tint),
            foregroundPainter: _GlassBorderPainter(radius: radius, dark: dark),
            child: content,
          ),
        ),
      ),
    );
  }
}

class _GlassFillPainter extends CustomPainter {
  _GlassFillPainter({required this.radius, required this.dark, this.tint});
  final double radius;
  final bool dark;
  final Color? tint;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rr = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    final colors = dark
        ? [Colors.white.withValues(alpha: 0.17), Colors.white.withValues(alpha: 0.07)]
        : [Colors.white.withValues(alpha: 0.86), Colors.white.withValues(alpha: 0.62)];
    canvas.drawRRect(
      rr,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ).createShader(rect),
    );
    if (tint != null) canvas.drawRRect(rr, Paint()..color = tint!.withValues(alpha: 0.14));

    // Reflet miroir : nappe claire sur le haut, bord inférieur incurvé.
    final h = size.height;
    final shine = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, math.min(h * 0.32, 70))
      ..quadraticBezierTo(size.width * 0.5, math.min(h * 0.52, 110), 0, math.min(h * 0.42, 90))
      ..close();
    canvas.save();
    canvas.clipRRect(rr);
    canvas.drawPath(
      shine,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: dark ? 0.16 : 0.55),
            Colors.white.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromLTWH(0, 0, size.width, math.min(h * 0.52, 110))),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GlassFillPainter old) => old.radius != radius || old.dark != dark || old.tint != tint;
}

class _GlassBorderPainter extends CustomPainter {
  _GlassBorderPainter({required this.radius, required this.dark});
  final double radius;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(0.6);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(radius)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? [
                  Colors.white.withValues(alpha: 0.55),
                  Colors.white.withValues(alpha: 0.06),
                  Colors.white.withValues(alpha: 0.25),
                ]
              : [Colors.white, Colors.white.withValues(alpha: 0.35), const Color(0x4D9CC9B3)],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_GlassBorderPainter old) => old.radius != radius || old.dark != dark;
}

/// Reflet de lumière qui traverse la carte en diagonale (effet miroir).
/// Sans animation, le reflet reste posé en haut à gauche.
class Sheen extends StatefulWidget {
  const Sheen({
    super.key,
    required this.child,
    this.radius = 24,
    this.period = const Duration(seconds: 6),
    this.strength = 0.32,
  });
  final Widget child;
  final double radius;
  final Duration period;
  final double strength;

  @override
  State<Sheen> createState() => _SheenState();
}

class _SheenState extends State<Sheen> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: widget.period);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Motion.of(context)) {
      if (!_controller.isAnimating) _controller.repeat();
    } else {
      _controller
        ..stop()
        ..value = 0.16; // position fixe, visible
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      widget.child,
      Positioned.fill(
        child: IgnorePointer(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(widget.radius),
            child: CustomPaint(painter: _SheenPainter(_controller, widget.strength)),
          ),
        ),
      ),
    ],
  );
}

class _SheenPainter extends CustomPainter {
  _SheenPainter(this.t, this.strength) : super(repaint: t);
  final Animation<double> t;
  final double strength;

  @override
  void paint(Canvas canvas, Size size) {
    // Le reflet passe pendant les 35 % du cycle, puis la carte reste calme.
    final p = t.value / 0.35;
    if (p > 1) return;
    final x = -0.4 + p * 1.8;
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: const Alignment(-1, -0.6),
          end: const Alignment(1, 0.6),
          stops: [(x - 0.14).clamp(0, 1), x.clamp(0, 1), (x + 0.02).clamp(0, 1), (x + 0.16).clamp(0, 1)],
          colors: [
            Colors.white.withValues(alpha: 0),
            Colors.white.withValues(alpha: strength),
            Colors.white.withValues(alpha: strength * 0.6),
            Colors.white.withValues(alpha: 0),
          ],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_SheenPainter old) => false;
}

/// Pastille d'icône bombée et brillante (reflet miroir + ombre colorée).
class GlossyOrb extends StatelessWidget {
  const GlossyOrb({super.key, required this.icon, required this.color, this.size = 50, this.iconColor = Colors.white});
  final IconData icon;
  final Color color;
  final double size;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    final hsl = HSLColor.fromColor(color);
    final light = hsl.withLightness((hsl.lightness + 0.16).clamp(0, 1)).toColor();
    final deep = hsl.withLightness((hsl.lightness - 0.12).clamp(0, 1)).toColor();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [light, color, deep]),
        boxShadow: [BoxShadow(color: color.withValues(alpha: 0.38), blurRadius: 16, offset: const Offset(0, 7))],
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned(
            top: size * 0.07,
            left: size * 0.16,
            right: size * 0.16,
            height: size * 0.42,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.vertical(top: Radius.circular(size), bottom: Radius.circular(size * 0.6)),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.white.withValues(alpha: 0.6), Colors.white.withValues(alpha: 0.02)],
                ),
              ),
            ),
          ),
          Icon(icon, color: iconColor, size: size * 0.48),
        ],
      ),
    );
  }
}

/// Reflet du logo, comme posé sur un miroir : la base de la pastille qui
/// s'estompe vers le bas (dégradé, sans calque de masque).
class MirrorReflection extends StatelessWidget {
  const MirrorReflection({super.key, required this.child, required this.size, this.gap = 6, this.opacity = 0.34});
  final Widget child;
  final double size;
  final double gap;
  final double opacity;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      child,
      SizedBox(height: gap),
      ExcludeSemantics(
        child: Container(
          width: size,
          height: size * 0.42,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.vertical(top: Radius.circular(size * 0.32)),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                AppColors.leaf.withValues(alpha: opacity),
                AppColors.leaf.withValues(alpha: 0),
              ],
            ),
          ),
        ),
      ),
    ],
  );
}

/// Logo « S » en pastille brillante.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 34, this.shadow = true});
  final double size;
  final bool shadow;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(size * 0.32),
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF7DF0B5), AppColors.leaf, AppColors.green],
      ),
      boxShadow: [
        BoxShadow(
          color: AppColors.leaf.withValues(alpha: 0.45),
          blurRadius: size * 0.5,
          offset: Offset(0, size * 0.15),
        ),
      ],
    ),
    child: Stack(
      alignment: Alignment.center,
      children: [
        Positioned(
          top: size * 0.06,
          left: size * 0.1,
          right: size * 0.1,
          height: size * 0.42,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(size * 0.26),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.white.withValues(alpha: 0.55), Colors.white.withValues(alpha: 0)],
              ),
            ),
          ),
        ),
        Text(
          'S',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: size * 0.56, height: 1),
        ),
      ],
    ),
  );
}
