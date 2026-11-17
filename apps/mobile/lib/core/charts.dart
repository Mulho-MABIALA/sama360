import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'glass.dart';

/// Tendance sur 7 jours par rapport aux 7 jours d'avant (+0,12 = +12 %) ; null sans référence.
double? weekTrend(List<int> last7, int previous7) {
  if (previous7 <= 0) return null;
  final current = last7.fold<int>(0, (s, v) => s + v);
  return (current - previous7) / previous7;
}

/// « +12 % », « −8 % », « = ».
String trendLabel(double t) {
  final pct = (t * 100).round();
  if (pct == 0) return '=';
  return '${pct > 0 ? '+' : '−'}${pct.abs()} %';
}

/// Petite courbe des ventes (7 points), lissée, avec un dégradé dessous et le dernier jour marqué.
class SalesSparkline extends StatelessWidget {
  const SalesSparkline({super.key, required this.values, required this.color, this.height = 40});
  final List<int> values;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Ventes des 7 derniers jours',
    child: SizedBox(
      height: height,
      child: CustomPaint(painter: _SparklinePainter(values, color), size: Size.infinite),
    ),
  );
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter(this.values, this.color);
  final List<int> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final maxV = math.max(1, values.reduce(math.max)).toDouble();
    const pad = 4.0;
    final h = size.height - pad * 2;
    final dx = size.width / (values.length - 1);
    final pts = [for (var i = 0; i < values.length; i++) Offset(i * dx, pad + h - (values[i] / maxV) * h)];
    // Courbe lissée (Catmull-Rom → Bézier)
    final line = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 0; i < pts.length - 1; i++) {
      final p0 = i == 0 ? pts[i] : pts[i - 1];
      final p1 = pts[i], p2 = pts[i + 1];
      final p3 = i + 2 < pts.length ? pts[i + 2] : p2;
      final c1 = p1 + (p2 - p0) / 6;
      final c2 = p2 - (p3 - p1) / 6;
      line.cubicTo(c1.dx, math.max(pad, c1.dy), c2.dx, math.max(pad, c2.dy), p2.dx, p2.dy);
    }
    final area = Path.from(line)
      ..lineTo(pts.last.dx, size.height)
      ..lineTo(pts.first.dx, size.height)
      ..close();
    canvas.drawPath(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.35), color.withValues(alpha: 0)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawCircle(pts.last, 4.2, Paint()..color = color);
    canvas.drawCircle(pts.last, 7.5, Paint()..color = color.withValues(alpha: 0.25));
  }

  @override
  bool shouldRepaint(_SparklinePainter old) => old.color != color || !_same(old.values, values);

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Montant qui défile jusqu'à sa valeur (0 → total au premier affichage, ancien → nouveau ensuite).
/// Sans animation (réglage du téléphone, tests) : la valeur s'affiche directement.
class CountUp extends StatelessWidget {
  const CountUp({super.key, required this.value, required this.builder});
  final int value;
  final Widget Function(BuildContext context, int shown) builder;

  @override
  Widget build(BuildContext context) {
    if (!Motion.of(context)) return builder(context, value);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: value.toDouble()),
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeOutCubic,
      builder: (context, v, _) => builder(context, v.round()),
    );
  }
}
