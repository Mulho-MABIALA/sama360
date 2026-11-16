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
    expect(find.text('Caisse du jour'), findsOneWidget);
    expect(find.textContaining('86'), findsWidgets); // 86 500 F
    expect(find.text('12 ventes aujourd’hui'), findsOneWidget);
    expect(find.text('2 produits en stock bas'), findsOneWidget);
    expect(find.text('Bientôt'), findsNWidgets(3)); // Factures, Boutique, Paiements
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

    await tester.tap(find.widgetWithText(OutlinedButton, 'Nouvelle vente'));
    await tester.pumpAndSettle();
    expect(find.text('Encaisser'), findsOneWidget); // panier vidé
  });

  testWidgets('caisse : le crédit exige un client', (tester) async {
    phoneSize(tester);
    final (_, repo) = await pumpSama(tester, location: '/pos');
    await tester.tap(find.text('Savon noir'));
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

  testWidgets('carnet de crédit : total et fiche client', (tester) async {
    phoneSize(tester);
    final (c, _) = await pumpSama(tester, location: '/customers');
    expect(find.text('Fatou Ndiaye'), findsOneWidget);
    expect(find.text('3 client(s) vous doivent de l’argent'), findsOneWidget);
    await tester.tap(find.text('Fatou Ndiaye'));
    await tester.pumpAndSettle();
    expect(find.text('Fiche client'), findsOneWidget);
    expect(find.text('Envoyer un rappel WhatsApp'), findsOneWidget);
    expect(find.text('Remboursement Wave'), findsOneWidget);
    expect(routerOf(c).state.matchedLocation, '/customers/k1');
  });

  testWidgets('nouveau produit avec photo : la photo est envoyée après la création', (tester) async {
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
    expect(find.text('Ajouter une photo'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Choisir une photo du produit'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choisir dans la galerie'));
    await tester.pumpAndSettle();
    expect(find.text('Photo ajoutée'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Nom du produit'), 'Beurre de karité 500 g');
    await tester.enterText(find.widgetWithText(TextField, 'Prix de vente'), '6000');
    await tester.tap(find.text('Enregistrer le produit'));
    await tester.pumpAndSettle();

    expect(repo.createdProducts, ['Beurre de karité 500 g']);
    expect(repo.uploads, {'new-1': png.length});
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
