import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/repositories.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// Photo choisie sur le téléphone : octets déjà compressés + nom de fichier.
class PickedPhoto {
  const PickedPhoto(this.bytes, this.filename);
  final List<int> bytes;
  final String filename;
}

/// Choix d'une photo (remplaçable dans les tests).
typedef PhotoPicker = Future<PickedPhoto?> Function(ImageSource source);

/// Photo réduite à 1080 px et compressée sur le téléphone : un envoi rapide même en 3G,
/// et bien sous la limite de l'API (5 Mo).
final photoPickerProvider = Provider<PhotoPicker>((ref) {
  final picker = ImagePicker();
  return (source) async {
    final file = await picker.pickImage(source: source, maxWidth: 1080, maxHeight: 1080, imageQuality: 80);
    if (file == null) return null;
    return PickedPhoto(await file.readAsBytes(), file.name.isEmpty ? 'photo.jpg' : file.name);
  };
});

/// Couverture de la boutique en ligne : grande image (affichée en plein écran sur ordinateur).
final coverPhotoPickerProvider = Provider<PhotoPicker>((ref) {
  final picker = ImagePicker();
  return (source) async {
    final file = await picker.pickImage(source: source, maxWidth: 1920, maxHeight: 1920, imageQuality: 82);
    if (file == null) return null;
    return PickedPhoto(await file.readAsBytes(), file.name.isEmpty ? 'couverture.jpg' : file.name);
  };
});

/// Photo de document (facture) : plus grande, pour que les petits caractères restent lisibles.
final documentPhotoPickerProvider = Provider<PhotoPicker>((ref) {
  final picker = ImagePicker();
  return (source) async {
    final file = await picker.pickImage(source: source, maxWidth: 2000, maxHeight: 2000, imageQuality: 85);
    if (file == null) return null;
    return PickedPhoto(await file.readAsBytes(), file.name.isEmpty ? 'facture.jpg' : file.name);
  };
});

/// Propose « appareil photo » ou « galerie » puis renvoie la photo choisie.
Future<PickedPhoto?> choosePhoto(BuildContext context, WidgetRef ref, {bool document = false}) async {
  final source = await showModalBottomSheet<ImageSource>(
    useRootNavigator: true,
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: Icon(Icons.photo_camera_rounded, color: AppColors.green),
            title: const Text('Prendre une photo'),
            onTap: () => Navigator.pop(ctx, ImageSource.camera),
          ),
          ListTile(
            leading: Icon(Icons.photo_library_rounded, color: AppColors.green),
            title: const Text('Choisir dans la galerie'),
            onTap: () => Navigator.pop(ctx, ImageSource.gallery),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (source == null) return null;
  return ref.read(document ? documentPhotoPickerProvider : photoPickerProvider)(source);
}

/// Vignette d'un produit : sa photo si elle existe, sinon ses initiales.
class ProductThumb extends ConsumerWidget {
  const ProductThumb({
    super.key,
    required this.name,
    this.fileId,
    this.size,
    this.height,
    this.radius = 12,
    this.highlight = false,
  });
  final String name;
  final String? fileId;
  final double? size; // carré
  final double? height; // pleine largeur
  final double radius;
  final bool highlight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final placeholder = Container(
      alignment: Alignment.center,
      color: highlight ? AppColors.greenSoft : (AppColors.isDark ? AppColors.mint : const Color(0xFFEEF4F0)),
      child: Text(
        productInitials(name),
        style: TextStyle(color: AppColors.green, fontWeight: FontWeight.w800, fontSize: (size ?? height ?? 48) * 0.34),
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size ?? double.infinity,
        height: size ?? height,
        child: fileId == null
            ? placeholder
            : Image.network(
                ref.watch(repoProvider).fileUrl(fileId!),
                fit: BoxFit.cover,
                semanticLabel: 'Photo de $name',
                loadingBuilder: (_, child, progress) => progress == null ? child : placeholder,
                errorBuilder: (_, _, _) => placeholder,
              ),
      ),
    );
  }
}

/// Zone de photo du formulaire produit : aperçu + bouton pour choisir / changer / retirer.
class PhotoField extends ConsumerWidget {
  const PhotoField({super.key, required this.photo, required this.onChanged});
  final PickedPhoto? photo;
  final ValueChanged<PickedPhoto?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Future<void> pick() async {
      try {
        final p = await choosePhoto(context, ref);
        if (p != null) onChanged(p);
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text("Impossible d'ouvrir l'appareil photo ou la galerie")));
        }
      }
    }

    return Row(
      children: [
        Semantics(
          button: true,
          label: photo == null ? 'Choisir une photo du produit' : 'Changer la photo du produit',
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: pick,
            child: Container(
              width: 88,
              height: 88,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: AppColors.greenSoft,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.line),
              ),
              child: photo == null
                  ? Icon(Icons.add_a_photo_rounded, color: AppColors.green, size: 30)
                  : Image.memory(
                      Uint8List.fromList(photo!.bytes),
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Icon(Icons.broken_image_outlined, color: AppColors.muted),
                    ),
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                photo == null ? 'Ajouter une photo' : 'Photo ajoutée',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 2),
              Text(
                photo == null
                    ? 'Facultatif — aide à retrouver le produit à la caisse.'
                    : 'Touchez la photo pour la changer.',
                style: TextStyle(color: AppColors.muted, fontSize: 12.5),
              ),
              if (photo != null)
                TextButton(
                  style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 36)),
                  onPressed: () => onChanged(null),
                  child: const Text('Retirer'),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Une photo de la galerie : déjà en ligne (fileId) ou choisie et pas encore envoyée (picked).
class GalleryPhoto {
  const GalleryPhoto({this.fileId, this.picked});
  final String? fileId;
  final PickedPhoto? picked;
}

/// Photos par produit (la première est la principale : caisse, boutique en ligne).
const maxProductPhotos = 5;

/// Envoie les changements de la galerie : retraits, ajouts, puis l'ordre voulu.
Future<void> syncGallery(
  SamaRepository repo,
  String productId, {
  required List<String> server,
  required List<GalleryPhoto> wanted,
}) async {
  final kept = {for (final p in wanted) ?p.fileId};
  var current = [...server];
  for (final f in server) {
    if (!kept.contains(f)) {
      current = (await repo.removeProductImage(productId, f)).images;
    }
  }
  final ids = <String>[];
  for (final p in wanted) {
    if (p.fileId != null) {
      ids.add(p.fileId!);
    } else if (p.picked != null) {
      current = (await repo.addProductImage(productId, p.picked!.bytes, filename: p.picked!.filename)).images;
      ids.add(current.last);
    }
  }
  if (ids.isNotEmpty && ids.join() != current.join()) await repo.orderProductImages(productId, ids);
}

/// Bande de photos : la principale en premier, « + Photo » jusqu'à 5, toucher une photo pour la mettre
/// en principale ou la retirer.
class PhotoGallery extends ConsumerWidget {
  const PhotoGallery({super.key, required this.name, required this.photos, required this.onChanged});
  final String name;
  final List<GalleryPhoto> photos;
  final ValueChanged<List<GalleryPhoto>> onChanged;

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    try {
      final p = await choosePhoto(context, ref);
      if (p != null) onChanged([...photos, GalleryPhoto(picked: p)]);
    } catch (_) {
      if (context.mounted) showInfo(context, 'Photo impossible à ouvrir. Réessayez avec une autre.');
    }
  }

  Future<void> _menu(BuildContext context, int i) async {
    final action = await showModalBottomSheet<String>(
      useRootNavigator: true,
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (i > 0)
              ListTile(
                key: const Key('photo_main'),
                leading: Icon(Icons.star_rounded, color: AppColors.saffron),
                title: const Text('Mettre en photo principale', style: TextStyle(fontWeight: FontWeight.w700)),
                onTap: () => Navigator.pop(ctx, 'main'),
              ),
            ListTile(
              key: const Key('photo_remove'),
              leading: Icon(Icons.delete_outline_rounded, color: AppColors.danger),
              title: Text(
                'Retirer la photo',
                style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.danger),
              ),
              onTap: () => Navigator.pop(ctx, 'remove'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    final list = [...photos];
    if (action == 'main') {
      list.insert(0, list.removeAt(i));
      onChanged(list);
    } else if (action == 'remove') {
      list.removeAt(i);
      onChanged(list);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const size = 82.0;
    Widget frame(Widget child, {bool main = false}) => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: main ? AppColors.green : AppColors.line, width: main ? 2 : 1),
      ),
      child: ClipRRect(borderRadius: BorderRadius.circular(15), child: child),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('Photos', style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(width: 6),
            Text('${photos.length}/$maxProductPhotos', style: TextStyle(color: AppColors.muted, fontSize: 12.5)),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: size,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final (i, p) in photos.indexed) ...[
                GestureDetector(
                  key: Key('photo_$i'),
                  onTap: () => _menu(context, i),
                  child: Stack(
                    children: [
                      frame(
                        p.picked != null
                            ? Image.memory(
                                Uint8List.fromList(p.picked!.bytes),
                                fit: BoxFit.cover,
                                width: size,
                                height: size,
                              )
                            : ProductThumb(name: name, fileId: p.fileId, size: size),
                        main: i == 0,
                      ),
                      if (i == 0)
                        Positioned(
                          left: 6,
                          bottom: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(color: AppColors.green, borderRadius: BorderRadius.circular(6)),
                            child: const Text(
                              'Principale',
                              style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
              ],
              if (photos.length < maxProductPhotos)
                InkWell(
                  key: const Key('photo_add'),
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => _add(context, ref),
                  child: Container(
                    width: size,
                    height: size,
                    decoration: BoxDecoration(
                      color: AppColors.greenSoft,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppColors.green.withValues(alpha: 0.4), width: 1.5),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.add_a_photo_rounded, color: AppColors.green),
                        const SizedBox(height: 4),
                        Text(
                          photos.isEmpty ? 'Photo' : 'Ajouter',
                          style: TextStyle(color: AppColors.green, fontWeight: FontWeight.w800, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (photos.length > 1) ...[
          const SizedBox(height: 6),
          Text(
            'Touchez une photo pour la mettre en principale ou la retirer.',
            style: TextStyle(color: AppColors.muted, fontSize: 12),
          ),
        ],
      ],
    );
  }
}
