import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';

/// Illustration originale de l'en-tête : ciel clair, soleil, immeubles de Dakar, baobab et dunes.
/// Dessinée en code (aucune image), elle s'adapte à toutes les largeurs d'écran.
class CityIllustration extends StatelessWidget {
  const CityIllustration({super.key, this.height = 150});
  final double height;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: CustomPaint(size: Size.fromHeight(height), painter: _CityPainter()),
  );
}

class _CityPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final ground = h * 0.86;

    // Soleil et nuages
    canvas.drawCircle(Offset(w * 0.82, h * 0.22), h * 0.11, Paint()..color = const Color(0xFFFFE08A));
    canvas.drawCircle(Offset(w * 0.82, h * 0.22), h * 0.17, Paint()..color = const Color(0x33FFE08A));
    _cloud(canvas, Offset(w * 0.12, h * 0.18), h * 0.07);
    _cloud(canvas, Offset(w * 0.55, h * 0.12), h * 0.055);

    // Immeubles en arrière-plan (menthe pâle)
    final far = Paint()..color = const Color(0xFFCDEBDC);
    final farBuildings = [
      [0.00, 0.42, 0.10],
      [0.09, 0.30, 0.07],
      [0.17, 0.48, 0.08],
      [0.27, 0.36, 0.06],
      [0.34, 0.22, 0.09],
      [0.45, 0.40, 0.07],
      [0.60, 0.33, 0.08],
      [0.70, 0.46, 0.06],
      [0.78, 0.38, 0.09],
      [0.89, 0.28, 0.11],
    ];
    for (final b in farBuildings) {
      canvas.drawRRect(RRect.fromLTRBR(w * b[0], h * b[1], w * (b[0] + b[2]), ground, const Radius.circular(3)), far);
    }

    // Immeubles au premier plan, avec fenêtres
    final colors = [AppColors.leaf, const Color(0xFF7FD3A8), const Color(0xFFF6C177), const Color(0xFF9FDDBE)];
    final nearBuildings = [
      [0.04, 0.56, 0.11],
      [0.19, 0.50, 0.09],
      [0.31, 0.62, 0.12],
      [0.50, 0.54, 0.10],
      [0.64, 0.60, 0.08],
      [0.76, 0.52, 0.10],
      [0.90, 0.64, 0.09],
    ];
    for (var i = 0; i < nearBuildings.length; i++) {
      final b = nearBuildings[i];
      final rect = Rect.fromLTRB(w * b[0], h * b[1], w * (b[0] + b[2]), ground);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(4)),
        Paint()..color = colors[i % colors.length],
      );
      _windows(canvas, rect);
    }

    // Baobab : tronc large et renflé, couronne plate et étalée
    final trunkX = w * 0.465;
    final trunk = Path()
      ..moveTo(trunkX - h * 0.07, ground)
      ..cubicTo(trunkX - h * 0.09, h * 0.70, trunkX - h * 0.03, h * 0.58, trunkX - h * 0.045, h * 0.45)
      ..lineTo(trunkX + h * 0.045, h * 0.45)
      ..cubicTo(trunkX + h * 0.03, h * 0.58, trunkX + h * 0.09, h * 0.70, trunkX + h * 0.07, ground)
      ..close();
    canvas.drawPath(trunk, Paint()..color = const Color(0xFF9B6B43));
    final branch = Paint()
      ..color = const Color(0xFF9B6B43)
      ..strokeWidth = h * 0.025
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(trunkX - h * 0.02, h * 0.47), Offset(trunkX - h * 0.12, h * 0.38), branch);
    canvas.drawLine(Offset(trunkX + h * 0.02, h * 0.47), Offset(trunkX + h * 0.12, h * 0.38), branch);
    canvas.drawLine(Offset(trunkX, h * 0.46), Offset(trunkX, h * 0.34), branch);
    final crown = Paint()..color = AppColors.greenDark;
    for (final c in [
      [-0.15, 0.37, 0.05],
      [-0.07, 0.33, 0.06],
      [0.0, 0.31, 0.065],
      [0.07, 0.33, 0.06],
      [0.15, 0.37, 0.05],
    ]) {
      canvas.drawOval(
        Rect.fromCenter(center: Offset(trunkX + h * c[0], h * c[1]), width: h * c[2] * 2.6, height: h * c[2] * 1.5),
        crown,
      );
    }

    // Sol en dunes
    final dunes = Path()
      ..moveTo(0, ground)
      ..quadraticBezierTo(w * 0.25, ground - h * 0.05, w * 0.5, ground)
      ..quadraticBezierTo(w * 0.75, ground + h * 0.05, w, ground - h * 0.02)
      ..lineTo(w, h)
      ..lineTo(0, h)
      ..close();
    canvas.drawPath(dunes, Paint()..color = const Color(0xFFF3E3C3));
  }

  void _windows(Canvas canvas, Rect r) {
    final p = Paint()..color = Colors.white.withValues(alpha: 0.55);
    const size = 4.0;
    const gap = 5.0;
    final cols = math.max(1, ((r.width - gap) / (size + gap)).floor());
    final rows = math.max(1, ((r.height - 10) / (size + gap * 1.4)).floor());
    final startX = r.left + (r.width - (cols * size + (cols - 1) * gap)) / 2;
    for (var row = 0; row < rows; row++) {
      for (var col = 0; col < cols; col++) {
        final x = startX + col * (size + gap);
        final y = r.top + 6 + row * (size + gap * 1.4);
        canvas.drawRRect(RRect.fromLTRBR(x, y, x + size, y + size + 1, const Radius.circular(1)), p);
      }
    }
  }

  void _cloud(Canvas canvas, Offset c, double r) {
    final p = Paint()..color = Colors.white.withValues(alpha: 0.9);
    canvas.drawCircle(c, r, p);
    canvas.drawCircle(c.translate(r * 0.9, r * 0.2), r * 0.8, p);
    canvas.drawCircle(c.translate(-r * 0.9, r * 0.25), r * 0.7, p);
    canvas.drawRRect(RRect.fromLTRBR(c.dx - r * 1.5, c.dy, c.dx + r * 1.6, c.dy + r * 0.9, Radius.circular(r)), p);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
