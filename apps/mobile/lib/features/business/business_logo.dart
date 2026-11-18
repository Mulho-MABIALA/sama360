import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/format.dart';
import '../../core/glass.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../catalog/product_photo.dart';

/// Logo de l'entreprise : l'image si elle existe, sinon les initiales sur fond vert.
class BusinessLogo extends ConsumerWidget {
  const BusinessLogo({super.key, required this.business, this.size = 56, this.radius = 14});
  final CurrentBusiness business;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final placeholder = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: AppColors.greenSoft, borderRadius: BorderRadius.circular(radius)),
      child: Text(
        initials(business.name),
        style: TextStyle(color: AppColors.green, fontWeight: FontWeight.w900, fontSize: size * 0.36),
      ),
    );
    final id = business.logoFileId;
    if (id == null) return placeholder;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.network(
        ref.read(repoProvider).fileUrl(id),
        width: size,
        height: size,
        fit: BoxFit.contain,
        semanticLabel: 'Logo de ${business.name}',
        errorBuilder: (_, _, _) => placeholder,
      ),
    );
  }
}

enum _LogoAction { camera, gallery, remove }

/// Choisir, remplacer ou retirer le logo de l'entreprise.
Future<void> changeBusinessLogo(BuildContext context, WidgetRef ref, CurrentBusiness business) async {
  final action = await showModalBottomSheet<_LogoAction>(
    useRootNavigator: true,
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Text('Logo de l’entreprise', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              'Il apparaît en haut de vos factures et devis. Une image carrée sur fond blanc rend le mieux.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.muted),
            ),
          ),
          ListTile(
            leading: Icon(Icons.photo_library_rounded, color: AppColors.green),
            title: const Text('Choisir dans la galerie'),
            onTap: () => Navigator.pop(ctx, _LogoAction.gallery),
          ),
          ListTile(
            leading: Icon(Icons.photo_camera_rounded, color: AppColors.green),
            title: const Text('Prendre une photo'),
            onTap: () => Navigator.pop(ctx, _LogoAction.camera),
          ),
          if (business.logoFileId != null)
            ListTile(
              leading: Icon(Icons.delete_rounded, color: AppColors.danger),
              title: Text('Retirer le logo', style: TextStyle(color: AppColors.danger)),
              onTap: () => Navigator.pop(ctx, _LogoAction.remove),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (action == null || !context.mounted) return;
  final repo = ref.read(repoProvider);
  try {
    if (action == _LogoAction.remove) {
      await repo.deleteBusinessLogo();
    } else {
      final photo = await ref.read(photoPickerProvider)(
        action == _LogoAction.camera ? ImageSource.camera : ImageSource.gallery,
      );
      if (photo == null) return;
      await repo.uploadBusinessLogo(photo.bytes, filename: photo.filename);
    }
    ref.invalidate(currentBusinessProvider);
    if (context.mounted) showInfo(context, action == _LogoAction.remove ? 'Logo retiré' : 'Logo enregistré');
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

/// Invitation à ajouter son logo (reçus, factures et devis), pour qui peut modifier l'entreprise.
class AddLogoHint extends ConsumerWidget {
  const AddLogoHint({super.key, this.message = 'Il apparaîtra sur vos reçus, factures et devis.'});
  final String message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final b = ref.watch(currentBusinessProvider).value;
    if (b == null || b.logoFileId != null || !ref.can('business:update')) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Glass(
        radius: 18,
        onTap: () => changeBusinessLogo(context, ref, b),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(
          children: [
            const GlossyOrb(icon: Icons.add_photo_alternate_rounded, color: Color(0xFF7A5AF8), size: 36),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Ajoutez votre logo', style: TextStyle(fontWeight: FontWeight.w800)),
                  Text(message, style: TextStyle(fontSize: 12.5, color: AppColors.muted)),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: AppColors.muted),
          ],
        ),
      ),
    );
  }
}
