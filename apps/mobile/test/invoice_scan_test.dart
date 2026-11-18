// Facture fournisseur en photo → vérification → achat pré-rempli.
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/api/api_client.dart';
import 'package:sama360/core/format.dart';
import 'package:sama360/core/models.dart';
import 'package:sama360/features/catalog/product_photo.dart';
import 'package:sama360/features/purchasing/invoice_scan_screen.dart';

import 'helpers.dart';

final _photo = PickedPhoto(List<int>.filled(64, 1), 'facture.jpg');
final _picker = documentPhotoPickerProvider.overrideWithValue((_) async => _photo);

Future<void> _openFromPurchases(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('scan_invoice_banner')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Prendre une photo'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadTestFonts);

  test('nom proposé pour un nouveau produit', () {
    expect(tidyLabel('  SAVON  NOIR 250G '), 'Savon noir 250g');
    expect(tidyLabel('Huile Dinor 5L'), 'Huile Dinor 5L');
  });

  testWidgets('facture lue : produit reconnu, produit créé, ligne ignorée, puis achat reçu en stock', (tester) async {
    phoneSize(tester);
    final (_, repo) = await pumpSama(tester, location: '/purchases', overrides: [_picker]);
    await _openFromPurchases(tester);

    expect(repo.scans, 1);
    expect(find.byKey(const Key('scan_supplier')), findsOneWidget);
    expect(find.text('Grossiste Sandaga'), findsOneWidget);
    expect(find.textContaining('Fournisseur connu · Facture FA-1187'), findsOneWidget);
    expect(find.text('Beurre de karité 250 g'), findsOneWidget);
    expect(find.text('Pas encore dans votre stock'), findsNWidgets(2));
    // Tant qu'une ligne n'est pas associée, on ne peut pas continuer
    expect(
      tester
          .widget<FilledButton>(
            find.descendant(of: find.byKey(const Key('scan_continue')), matching: find.byType(FilledButton)),
          )
          .onPressed,
      isNull,
    );

    await tapCentered(tester, find.byKey(const Key('scan_create_1')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Savon noir artisanal'), findsOneWidget);
    expect(find.widgetWithText(TextField, '1500'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('new_product_price')), '2500');
    await tester.tap(find.byKey(const Key('new_product_save')));
    await tester.pumpAndSettle();
    expect(repo.createdProducts, contains('Savon noir artisanal'));

    await tester.scrollUntilVisible(find.byKey(const Key('scan_mismatch')), 300);
    expect(find.textContaining('Vérifiez les quantités et les prix'), findsOneWidget);
    await tapCentered(tester, find.byKey(const Key('scan_toggle_2'))); // « Transport » n'est pas un article
    await tester.pumpAndSettle();
    expect(find.text('Ligne ignorée'), findsOneWidget);

    await tester.tap(find.byKey(const Key('scan_continue')));
    await tester.pumpAndSettle();

    // Achat pré-rempli : fournisseur, lignes, note, marchandise déjà reçue
    expect(find.text('Grossiste Sandaga'), findsWidgets);
    expect(find.text('Savon noir artisanal'), findsOneWidget);
    await tapCentered(tester, find.text('Enregistrer l’achat'));
    await tester.pumpAndSettle();
    final body = repo.purchaseBodies.single;
    expect(body['supplierId'], 's1');
    expect(body['receive'], true);
    expect(body['note'], 'Facture FA-1187 du 17/11/2026');
    expect(body['lines'], [
      {'productId': 'p1', 'quantity': 12.0, 'unitCost': 2000, 'scanLabel': 'BEURRE KARITE 250G'},
      {'productId': 'new-1', 'quantity': 10.0, 'unitCost': 1500, 'scanLabel': 'Savon noir artisanal'},
    ]);
  });

  testWidgets('correction de la quantité et du prix lus', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, location: '/purchases', overrides: [_picker]);
    await _openFromPurchases(tester);
    await tapCentered(tester, find.byKey(const Key('scan_amounts_0')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('scan_qty')), '10');
    await tester.enterText(find.byKey(const Key('scan_cost')), '2100');
    await tester.tap(find.text('Valider'));
    await tester.pumpAndSettle();
    expect(find.text('10 × ${moneyShort(2100)}'), findsOneWidget);
  });

  testWidgets('nouveau fournisseur : il est créé avant l’achat', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo()
      ..invoiceScan = InvoiceScan.fromJson({
        'readable': true,
        'supplier': {'id': null, 'name': 'Ets Diallo et Fils', 'phone': null},
        'lines': [
          {
            'label': 'Beurre karité',
            'quantity': 5,
            'unitCost': 2000,
            'productId': null,
            'confidence': 'none',
            'candidates': [
              {'id': 'p1', 'name': 'Beurre de karité 250 g', 'unit': 'pièce', 'cost': 2000, 'price': 3500},
            ],
          },
        ],
      });
    await pumpSama(tester, location: '/purchases', repo: repo, overrides: [_picker]);
    await _openFromPurchases(tester);
    expect(find.textContaining('Nouveau : sera ajouté'), findsOneWidget);
    await tester.tap(find.byKey(const Key('scan_suggest_0_p1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('scan_continue')));
    await tester.pumpAndSettle();
    expect(repo.savedTypes.last, 'supplier');
    expect(repo.savedCustomers.last.$2['name'], 'Ets Diallo et Fils');
  });

  testWidgets('photo illisible : conseils et nouvelle photo', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo()
      ..invoiceScan = const InvoiceScan(
        readable: false,
        supplierId: null,
        supplierName: null,
        supplierPhone: null,
        number: null,
        date: null,
        total: null,
        lines: [],
        remaining: 18,
      );
    await pumpSama(tester, location: '/purchases', repo: repo, overrides: [_picker]);
    await _openFromPurchases(tester);
    expect(find.text('Facture illisible'), findsOneWidget);
    await tester.tap(find.text('Reprendre la photo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Prendre une photo'));
    await tester.pumpAndSettle();
    expect(repo.scans, 2);
  });

  testWidgets('lecture impossible : saisie à la main proposée', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo()
      ..scanError = const ApiException(
        'SCAN_UNAVAILABLE',
        'Lecture impossible pour le moment. Réessayez dans un instant.',
      );
    await pumpSama(tester, location: '/purchases', repo: repo, overrides: [_picker]);
    await _openFromPurchases(tester);
    expect(find.text('Lecture impossible pour le moment. Réessayez dans un instant.'), findsOneWidget);
    await tester.tap(find.text('Saisir l’achat à la main'));
    await tester.pumpAndSettle();
    expect(find.text('Nouvel achat'), findsOneWidget);
  });

  testWidgets('sans Pro : la carte mène à Sama360 Pro', (tester) async {
    phoneSize(tester);
    final repo = FakeRepo()..proUntil = DateTime(2026, 1, 1);
    await pumpSama(tester, location: '/purchases', repo: repo, overrides: [_picker]);
    expect(
      find.descendant(of: find.byKey(const Key('scan_invoice_banner')), matching: find.text('PRO')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('scan_invoice_banner')));
    await tester.pumpAndSettle();
    expect(repo.scans, 0);
    expect(find.byKey(const Key('pro_headline')), findsOneWidget);
  });
}
