import 'package:material_ui/material_ui.dart';

import 'glass.dart';
import 'theme.dart';

/// Reflet qui balaie les formes grises pendant le chargement (fixe si les animations sont coupées).
class Shimmer extends StatefulWidget {
  const Shimmer({super.key, required this.child});
  final Widget child;
  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1300));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Motion.of(context)) {
      if (!_c.isAnimating) _c.repeat();
    } else {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = AppColors.isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFE2EBE6);
    final light = AppColors.isDark ? Colors.white.withValues(alpha: 0.16) : const Color(0xFFF4F8F6);
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) => ShaderMask(
        blendMode: BlendMode.srcATop,
        shaderCallback: (rect) {
          final t = _c.value * 2 - 0.5; // -0.5 → 1.5 : le reflet traverse toute la largeur
          return LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [base, light, base],
            stops: [(t - 0.3).clamp(0, 1), t.clamp(0, 1), (t + 0.3).clamp(0, 1)],
          ).createShader(rect);
        },
        child: child,
      ),
      child: widget.child,
    );
  }
}

/// Forme grise arrondie (texte, image, montant à venir).
class Bone extends StatelessWidget {
  const Bone({super.key, this.width, this.height = 14, this.radius = 8, this.circle = false});
  final double? width;
  final double height;
  final double radius;
  final bool circle;

  @override
  Widget build(BuildContext context) => Container(
    width: circle ? height : width,
    height: height,
    decoration: BoxDecoration(
      color: Colors.white,
      shape: circle ? BoxShape.circle : BoxShape.rectangle,
      borderRadius: circle ? null : BorderRadius.circular(radius),
    ),
  );
}

/// Squelette par défaut des listes : un bloc de résumé puis des lignes (avatar, deux textes, montant).
class SkeletonList extends StatelessWidget {
  const SkeletonList({super.key, this.rows = 6, this.header = true});
  final int rows;
  final bool header;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Chargement',
    child: Shimmer(
      child: SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (header) ...[const Bone(height: 112, radius: 24, width: double.infinity), const SizedBox(height: 16)],
            for (var i = 0; i < rows; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Row(
                  children: [
                    const Bone(height: 42, circle: true),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Bone(width: 120.0 + (i % 3) * 30, height: 13),
                          const SizedBox(height: 8),
                          Bone(width: 80.0 + (i % 2) * 40, height: 11),
                        ],
                      ),
                    ),
                    const Bone(width: 64, height: 14),
                  ],
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
