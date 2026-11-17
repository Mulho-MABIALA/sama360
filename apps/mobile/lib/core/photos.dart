import 'package:material_ui/material_ui.dart';

/// Vraies photos (Unsplash, licence libre) à la place des icônes dessinées.
abstract final class Photos {
  static const livraison = 'assets/photos/livraison.jpg';
  static const ventes = 'assets/photos/ventes.jpg';
  static const stock = 'assets/photos/stock.jpg';
  static const caisse = 'assets/photos/caisse.jpg';
  static const clients = 'assets/photos/clients.jpg';
  static const depenses = 'assets/photos/depenses.jpg';
  static const factures = 'assets/photos/factures.jpg';
  static const rapports = 'assets/photos/rapports.jpg';
  static const reservation = 'assets/photos/reservation.jpg';
  static const boutique = 'assets/photos/boutique.jpg';
  static const equipe = 'assets/photos/equipe.jpg';
  static const achats = 'assets/photos/achats.jpg';
  static const paiements = 'assets/photos/paiements.jpg';
  static const relances = 'assets/photos/relances.jpg';
  static const fidelite = 'assets/photos/fidelite.jpg';
  static const documents = 'assets/photos/documents.jpg';
  static const assistant = 'assets/photos/assistant.jpg';
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
