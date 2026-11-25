import 'package:flutter_test/flutter_test.dart';
import 'package:sama360/features/catalog/product_photo.dart';

import 'helpers.dart';

/// Galerie d'un produit existant : retirer, ajouter, choisir la principale, en une seule fois à l'enregistrement.
void main() {
  test('retrait, ajout puis nouvel ordre envoyés à l’API', () async {
    final repo = FakeRepo()..galleries['p1'] = ['a', 'b', 'c'];
    await syncGallery(
      repo,
      'p1',
      server: const ['a', 'b', 'c'],
      wanted: const [
        GalleryPhoto(fileId: 'c'),
        GalleryPhoto(picked: PickedPhoto([1, 2, 3], 'n.jpg')),
        GalleryPhoto(fileId: 'a'),
      ],
    );
    expect(repo.galleryOps, ['remove b', 'add g1', 'order c,g1,a']);
    expect(repo.galleries['p1'], ['c', 'g1', 'a']);
  });

  test('rien de changé : aucun appel', () async {
    final repo = FakeRepo();
    await syncGallery(
      repo,
      'p1',
      server: const ['a', 'b'],
      wanted: const [
        GalleryPhoto(fileId: 'a'),
        GalleryPhoto(fileId: 'b'),
      ],
    );
    expect(repo.galleryOps, isEmpty);
  });
}
