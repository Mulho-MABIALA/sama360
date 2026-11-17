import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'glass.dart';
import 'theme.dart';

/// Vente à fêter : la première de l'année (…-0001) et chaque centaine (…-0100, …-0200).
String? saleMilestone(String number) {
  final m = RegExp(r'(\d+)$').firstMatch(number);
  if (m == null) return null;
  final n = int.parse(m.group(1)!);
  if (n == 1) return 'Votre première vente sur Sama360 !';
  if (n % 100 == 0) return '$nᵉ vente : bravo !';
  return null;
}

/// Coche qui se dessine dans un cercle qui gonfle, avec une vibration.
class SuccessCheck extends StatefulWidget {
  const SuccessCheck({super.key, this.size = 72});
  final double size;
  @override
  State<SuccessCheck> createState() => _SuccessCheckState();
}

class _SuccessCheckState extends State<SuccessCheck> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));

  @override
  void initState() {
    super.initState();
    HapticFeedback.mediumImpact();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Motion.of(context)) {
      if (_c.value == 0 && !_c.isAnimating) _c.forward();
    } else {
      _c.value = 1;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Réussi',
    child: AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final grow = Curves.elasticOut.transform((_c.value / 0.6).clamp(0, 1));
        final draw = Curves.easeOut.transform(((_c.value - 0.35) / 0.65).clamp(0, 1));
        return Transform.scale(
          scale: 0.4 + 0.6 * grow,
          child: CustomPaint(size: Size.square(widget.size), painter: _CheckPainter(draw, AppColors.green)),
        );
      },
    ),
  );
}

class _CheckPainter extends CustomPainter {
  _CheckPainter(this.progress, this.color);
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    canvas.drawCircle(c, r, Paint()..color = color.withValues(alpha: 0.14));
    canvas.drawCircle(c, r * 0.78, Paint()..color = color);
    final path = Path()
      ..moveTo(size.width * 0.3, size.height * 0.52)
      ..lineTo(size.width * 0.44, size.height * 0.66)
      ..lineTo(size.width * 0.71, size.height * 0.38);
    final metric = path.computeMetrics().first;
    canvas.drawPath(
      metric.extractPath(0, metric.length * progress),
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.width * 0.075
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_CheckPainter old) => old.progress != progress || old.color != color;
}

/// Pluie de confettis aux couleurs de Sama360 (une seule fois, ~2 s). Rien si les animations sont coupées.
class ConfettiBurst extends StatefulWidget {
  const ConfettiBurst({super.key, this.pieces = 70});
  final int pieces;
  @override
  State<ConfettiBurst> createState() => _ConfettiBurstState();
}

class _ConfettiBurstState extends State<ConfettiBurst> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2200));
  late final List<_Piece> _pieces;

  @override
  void initState() {
    super.initState();
    final rnd = math.Random(7);
    const colors = [Color(0xFF19B56F), Color(0xFFF2A93B), Color(0xFF2F6FDB), Color(0xFFE0533D), Color(0xFF7A5AF8)];
    _pieces = [
      for (var i = 0; i < widget.pieces; i++)
        _Piece(
          x: rnd.nextDouble(),
          drift: (rnd.nextDouble() - 0.5) * 0.35,
          speed: 0.7 + rnd.nextDouble() * 0.6,
          spin: (rnd.nextDouble() - 0.5) * 14,
          size: 5 + rnd.nextDouble() * 6,
          color: colors[i % colors.length],
          delay: rnd.nextDouble() * 0.25,
        ),
    ];
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Motion.of(context) && !_c.isAnimating && _c.value == 0) _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!Motion.of(context)) return const SizedBox.shrink();
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => CustomPaint(painter: _ConfettiPainter(_pieces, _c.value), size: Size.infinite),
      ),
    );
  }
}

class _Piece {
  const _Piece({
    required this.x,
    required this.drift,
    required this.speed,
    required this.spin,
    required this.size,
    required this.color,
    required this.delay,
  });
  final double x, drift, speed, spin, size, delay;
  final Color color;
}

class _ConfettiPainter extends CustomPainter {
  _ConfettiPainter(this.pieces, this.t);
  final List<_Piece> pieces;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in pieces) {
      final local = ((t - p.delay) / (1 - p.delay)).clamp(0.0, 1.0);
      if (local <= 0) continue;
      final y = -20 + local * p.speed * (size.height + 40);
      final x = (p.x + p.drift * local + math.sin(local * 9 + p.x * 6) * 0.02) * size.width;
      final opacity = local > 0.8 ? (1 - local) / 0.2 : 1.0;
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(p.spin * local);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: p.size, height: p.size * 0.55),
          const Radius.circular(1.5),
        ),
        Paint()..color = p.color.withValues(alpha: opacity.clamp(0, 1)),
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiPainter old) => old.t != t;
}
