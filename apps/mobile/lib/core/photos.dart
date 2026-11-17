import 'package:material_ui/material_ui.dart';

/// Vraies photos (Unsplash, licence libre).
abstract final class Photos {
  static const livraison = 'assets/photos/livraison.jpg';
}

/// Vignette photo arrondie ; retombe sur l'icône si l'image manque.
class PhotoThumb extends StatelessWidget {
  const PhotoThumb(this.asset, {super.key, this.size = 52, this.radius = 17, this.fallback, this.color});

  final String asset;
  final double size;
  final double radius;
  final IconData? fallback;
  final Color? color;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: Image.asset(
      asset,
      width: size,
      height: size,
      fit: BoxFit.cover,
      cacheWidth: (size * 3).round(),
      errorBuilder: (_, _, _) => Container(
        width: size,
        height: size,
        color: (color ?? Colors.grey).withValues(alpha: 0.14),
        child: Icon(fallback ?? Icons.image_rounded, color: color, size: size / 2),
      ),
    ),
  );
}
