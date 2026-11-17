import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/models.dart';
import 'package:sama360/features/catalog/product_photo.dart' show PickedPhoto;
import 'package:sama360/features/documents/documents_screen.dart';
import 'package:sama360/features/sales/receipt_screen.dart';

import 'helpers.dart';
import 'receipt_test.dart' show RecordingActions;

void main() {
  setUpAll(() async {
    await loadTestFonts();
    await initializeDateFormatting('fr');
  });

  group('textes', () {
    BusinessDocument doc(int? days) => BusinessDocument(
      id: 'x',
      title: 'X',
      category: DocCategory.other,
      expiresOn: days == null ? null : DateTime(2027, 5, 12),
      expiresInDays: days,
      mime: 'image/png',
      size: 1,
      createdAt: DateTime(2026),
    );

    test('échéance', () {
      expect(expiryLabel(doc(null)), isNull);
      expect(expiryLabel(doc(-3)), 'Expiré depuis 3 j');
      expect(expiryLabel(doc(0)), 'Expire aujourd’hui');
      expect(expiryLabel(doc(10)), 'Expire dans 10 j');
      expect(expiryLabel(doc(176)), 'Expire le 12 mai 2027');
    });

    test('taille et titre proposé', () {
      expect(fileSizeLabel(245 * 1024), '245 Ko');
      expect(fileSizeLabel(1900 * 1024), '1,9 Mo');
      expect(titleFromFilename('bail_boutique-2026.pdf'), 'Bail boutique 2026');
      expect(titleFromFilename('IMG_20261117_101530.jpg'), '');
      expect(titleFromFilename('image.jpg'), '');
    });
  });

  testWidgets('liste : échéance à surveiller, catégories, recherche', (tester) async {
    phoneSize(tester);
    final (_, repo) = await pumpSama(tester, location: '/documents');
    expect(find.byKey(const Key('documents_attention')), findsOneWidget);
    expect(find.text('1 document arrive à échéance : pensez à le renouveler'), findsOneWidget);
    expect(find.text('Bail boutique Sandaga'), findsOneWidget);
    expect(find.text('Expire dans 10 j'), findsOneWidget);
    expect(find.text('Contrats · 1'), findsOneWidget);

    await tester.tap(find.text('Administratif · 1'));
    await tester.pumpAndSettle();
    expect(find.text('NINEA'), findsOneWidget);
    expect(find.text('Bail boutique Sandaga'), findsNothing);

    await tester.tap(find.text('Tous · 2'));
    await tester.enterText(find.byKey(const Key('documents_search')), 'bail');
    await tester.pumpAndSettle();
    expect(find.text('NINEA'), findsNothing);
    expect(repo.docQueries.last, (null, 'bail'));
  });

  testWidgets('vide : invitation à ranger ses papiers', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo()..storedDocs.clear();
    await pumpSama(tester, location: '/documents', repo: repo);
    expect(find.text('Rangez vos papiers ici'), findsOneWidget);
    expect(find.text('Ajouter mon premier document'), findsOneWidget);
  });

  testWidgets('ajout : photo, titre proposé, catégorie, rangement puis fiche', (tester) async {
    phoneSize(tester);
    final (c, repo) = await pumpSama(
      tester,
      location: '/documents',
      overrides: [docFilePickerProvider.overrideWithValue((_) async => PickedPhoto(tinyPng, 'facture_ciment.png'))],
    );
    await tester.tap(find.byKey(const Key('add_document')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Photographier un papier'));
    await tester.pumpAndSettle();

    expect(find.text('Nouveau document'), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const Key('doc_title'))).controller!.text, 'Facture ciment');
    await tester.tap(find.text('Factures fournisseurs'));
    await tester.enterText(find.byKey(const Key('doc_note')), 'Payée en espèces');
    await tester.ensureVisible(find.text('Ranger le document'));
    await tester.tap(find.text('Ranger le document'));
    await tester.pumpAndSettle();

    expect(repo.uploadedDocs.single, {
      'filename': 'facture_ciment.png',
      'title': 'Facture ciment',
      'category': DocCategory.supplierInvoice,
      'note': 'Payée en espèces',
      'expiresOn': null,
    });
    expect(routerOf(c).state.uri.path, '/documents/d3');
    expect(find.byKey(const Key('document_image')), findsOneWidget);
    expect(find.text('Payée en espèces'), findsOneWidget);
  });

  testWidgets('fiche PDF : partager, imprimer, supprimer', (tester) async {
    phoneSize(tester);
    final actions = RecordingActions();
    final (c, repo) = await pumpSama(
      tester,
      location: '/documents/d1',
      overrides: [receiptActionsProvider.overrideWithValue(actions)],
    );
    expect(find.text('Document PDF'), findsOneWidget);
    expect(find.text('Contrats'), findsOneWidget);
    expect(find.text('PDF · 245 Ko'), findsOneWidget);
    expect(find.text('Ajouté le 1 sept. 2026 par Awa Diallo'), findsOneWidget);

    await tester.tap(find.text('Partager'));
    await tester.pumpAndSettle();
    expect(actions.sharedName, 'Bail boutique Sandaga.pdf');
    await tester.tap(find.text('Imprimer'));
    await tester.pumpAndSettle();
    expect(actions.printed, isNotNull);

    routerOf(c).go('/documents');
    await tester.pumpAndSettle();
    routerOf(c).push('/documents/d1');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Supprimer'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Supprimer'));
    await tester.pumpAndSettle();
    expect(repo.deletedDocs, ['d1']);
    expect(routerOf(c).state.uri.path, '/documents');
    expect(find.text('Bail boutique Sandaga'), findsNothing);
  });
}
