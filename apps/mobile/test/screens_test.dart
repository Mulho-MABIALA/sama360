import 'dart:convert';
import 'dart:ui' show Tristate;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/features/catalog/product_photo.dart';

import 'helpers.dart';

void main() {
  testWidgets("l'accueil affiche le résumé du jour, l'alerte stock et les services", (tester) async {
    phoneSize(tester);
    await pumpSama(tester);
    expect(find.text('Awa Beauté'), findsOneWidget);
    expect(find.text('Vendu aujourd’hui'), findsOneWidget);
    expect(find.textContaining('86'), findsWidgets); // 86 500 F
    expect(find.text('12 ventes aujourd’hui'), findsOneWidget);
    expect(find.text('2 produits en stock bas'), findsOneWidget);
    expect(find.text('Bientôt'), findsNothing); // le propriétaire voit Rapports et Équipe
    expect(find.text('Rapports'), findsOneWidget);
    expect(find.text('Équipe'), findsWidgets); // le propriétaire voit son équipe
    await tester.scrollUntilVisible(find.text('Plus'), 200, scrollable: find.byType(Scrollable).first);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -120)); // au-dessus de la barre flottante
    await tester.pumpAndSettle();
    await tester.tap(find.text('Plus'));
    await tester.pumpAndSettle();
    expect(find.text('Tous les services'), findsOneWidget);
    expect(find.text('Assistant IA'), findsOneWidget);
  });

  testWidgets('caisse : panier, encaissement comptant, identifiant de vente envoyé', (tester) async {
    phoneSize(tester);
    final (_, repo) = await pumpSama(tester, location: '/pos');

    await tester.tap(find.text('Beurre de karité 250 g'));
    await tester.tap(find.text('Beurre de karité 250 g'));
    await tester.tap(find.text('Huile de coco 500 ml'));
    await tester.pump();
    expect(find.text('×2'), findsOneWidget);
    expect(find.textContaining('Encaisser 11'), findsOneWidget); // 11 000 FCFA

    await tester.tap(find.textContaining('Encaisser 11'));
    await tester.pumpAndSettle();
    expect(find.text('Vente enregistrée'), findsOneWidget);
    expect(find.text('VEN-2026-0001'), findsOneWidget);
    expect(find.text('Voir le reçu'), findsOneWidget);

    expect(repo.sales, hasLength(1));
    final sale = repo.sales.single;
    expect(sale['id'], matches(RegExp(r'^[0-9a-f-]{36}$')));
    expect(sale['payments'], [
      {'method': 'cash', 'amount': 11000},
    ]);

    await tester.tap(find.widgetWithText(TextButton, 'Nouvelle vente'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pos_compact_panel')), findsOneWidget); // panier vidé
  });

  testWidgets('caisse sur ordinateur : panier à droite, + / − sur chaque ligne', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final (_, repo) = await pumpSama(tester, location: '/pos');
    expect(find.byKey(const Key('pos_side_panel')), findsOneWidget);
    expect(find.text('Touchez un produit pour l’ajouter'), findsOneWidget);

    await tester.tap(find.text('Beurre de karité 250 g').first);
    await tester.tap(find.text('Beurre de karité 250 g').first);
    await tester.pump();
    final line = find.byKey(const Key('cart_line_p1'));
    expect(find.descendant(of: line, matching: find.textContaining(RegExp(r'^2 × 3.500 F$'))), findsOneWidget);
    await tester.tap(find.descendant(of: line, matching: find.byTooltip('Retirer un')));
    await tester.pump();
    expect(find.descendant(of: line, matching: find.textContaining(RegExp(r'^1 × 3.500 F$'))), findsOneWidget);
    await tester.tap(find.textContaining('Encaisser 3'));
    await tester.pumpAndSettle();
    expect(find.text('Vente enregistrée'), findsOneWidget);
    expect(repo.sales, hasLength(1));
  });

  testWidgets('caisse : le crédit exige un client', (tester) async {
    phoneSize(tester);
    final (_, repo) = await pumpSama(tester, location: '/pos');
    await tester.tap(find.text('Savon noir'));
    await tester.pump();
    await tester.tap(find.text('Crédit'));
    await tester.pump();
    await tester.tap(find.text('Valider à crédit'));
    await tester.pump();
    expect(find.text('Choisissez le client pour une vente à crédit'), findsOneWidget);
    expect(repo.sales, isEmpty);
  });

  testWidgets('stock : stock bas mis en avant et filtre', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/stock');
    expect(find.text('Parfum Thiouraye'), findsOneWidget);
    expect(find.text('Savon noir'), findsOneWidget);
    await tester.tap(find.widgetWithText(InkWell, 'Stock bas').last);
    await tester.pumpAndSettle();
    expect(find.text('Savon noir'), findsNothing);
    expect(find.text('Huile de coco 500 ml'), findsOneWidget);
  });

  testWidgets('clients : total à encaisser et fiche client', (tester) async {
    phoneSize(tester);
    final (c, _) = await pumpSama(tester, location: '/customers');
    expect(find.text('Fatou Ndiaye'), findsOneWidget);
    await tester.tap(find.text('Fatou Ndiaye'));
    await tester.pumpAndSettle();
    expect(find.text('Fiche client'), findsOneWidget);
    expect(find.text('Envoyer un rappel'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Remboursement Wave'), 200, scrollable: find.byType(Scrollable).first);
    expect(routerOf(c).state.matchedLocation, '/customers/k1');
  });

  testWidgets('nouveau produit avec plusieurs photos : envoyées après la création, principale au choix', (
    tester,
  ) async {
    phoneSize(tester);
    // Remplace la galerie du téléphone par une photo de test
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
    );
    final (_, repo) = await pumpSama(
      tester,
      location: '/stock',
      overrides: [photoPickerProvider.overrideWithValue((_) async => PickedPhoto(png, 'karite.jpg'))],
    );

    await tester.tap(find.text('Nouveau produit'));
    await tester.pumpAndSettle();
    Future<void> addPhoto() async {
      await tester.tap(find.byKey(const Key('photo_add')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choisir dans la galerie'));
      await tester.pumpAndSettle();
    }

    await addPhoto();
    await addPhoto();
    await addPhoto();
    expect(find.text('3/5'), findsOneWidget);
    expect(find.text('Principale'), findsOneWidget);
    // La 3e devient la principale, la 2e est retirée
    await tester.tap(find.byKey(const Key('photo_2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('photo_main')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('photo_2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('photo_remove')));
    await tester.pumpAndSettle();
    expect(find.text('2/5'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('pName')), 'Beurre de karité 500 g');
    await tester.enterText(find.byKey(const Key('pPrice')), '6000');
    await tester.tap(find.text('Ajouter le produit'));
    await tester.pumpAndSettle();

    expect(repo.createdProducts, ['Beurre de karité 500 g']);
    // Deux photos envoyées dans l'ordre choisi : déjà le bon ordre, pas de réordonnancement
    expect(repo.galleryOps, ['add g1', 'add g2']);
    expect(repo.galleries['new-1'], ['g1', 'g2']);
    expect(find.text('Produit ajouté'), findsOneWidget);
  });

  testWidgets("carrousel : 4 bannières, glisser change l'indicateur, l'action ouvre l'écran", (tester) async {
    phoneSize(tester);
    final (c, _) = await pumpSama(tester);
    await tester.scrollUntilVisible(find.text('Passez à Sama360 Pro'), 200, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Bannière 1 sur 4'), findsOneWidget);

    // Glisser vers la gauche : 2e bannière
    await tester.drag(find.text('Passez à Sama360 Pro'), const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(find.text('Ajoutez vos photos'), findsOneWidget);
    final second = tester.getSemantics(find.bySemanticsLabel('Bannière 2 sur 4'));
    expect(second.flagsCollection.isSelected, Tristate.isTrue);

    // L'action de la bannière « photos » ouvre le stock
    await tester.tap(find.text('Ajoutez vos photos'));
    await tester.pumpAndSettle();
    expect(routerOf(c).state.matchedLocation, '/stock');
  });

  testWidgets('carrousel : défilement automatique (désactivé si animations réduites)', (tester) async {
    phoneSize(tester);
    await pumpSama(tester);
    await tester.scrollUntilVisible(find.text('Passez à Sama360 Pro'), 200, scrollable: find.byType(Scrollable).first);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Ajoutez vos photos'), findsOneWidget);
  });
}
