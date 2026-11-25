import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sama360/core/thermal/escpos.dart';
import 'package:sama360/core/thermal/printer.dart';
import 'package:sama360/features/sales/cart.dart';
import 'package:sama360/features/sales/receipt_escpos.dart';
import 'package:sama360/features/sales/receipt_screen.dart';

import 'helpers.dart';
import 'receipt_test.dart' show RecordingActions;

/// Imprimante Bluetooth factice : appairées, tickets reçus, panne simulée.
class FakeThermal implements ThermalPrinter {
  FakeThermal({this.on = true, this.devices = const [PrinterDevice('MPT-II', 'AA:BB:CC:DD:EE:FF')]});
  bool on;
  final List<PrinterDevice> devices;
  bool fail = false;
  final printed = <(String, List<int>)>[];

  @override
  bool get supported => true;
  @override
  Future<bool> ready() async => on;
  @override
  Future<List<PrinterDevice>> paired() async => devices;
  @override
  Future<bool> print(String address, List<int> bytes) async {
    if (fail) return false;
    printed.add((address, bytes));
    return true;
  }
}

/// Texte lisible d'un ticket : commandes ESC/POS retirées, « é »/« É » ramenés à « e »/« E ».
String ticketText(List<int> bytes) {
  final out = <int>[];
  for (var i = 0; i < bytes.length; i++) {
    final b = bytes[i];
    if (b == 0x1B || b == 0x1D) {
      final cmd = bytes[i + 1];
      i += b == 0x1B && cmd == 0x40 ? 1 : (b == 0x1D && cmd == 0x56 ? 3 : 2);
      continue;
    }
    if (b == 0x0A || (b >= 0x20 && b < 0x7F)) {
      out.add(b);
    } else if (b == 0x82) {
      out.add(0x65);
    } else if (b == 0x90) {
      out.add(0x45);
    } else {
      out.add(0x3F);
    }
  }
  return String.fromCharCodes(out);
}

/// L'imprimante tourne (indicateur animé) pendant le choix : on avance le temps sans attendre la fin.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

void main() {
  setUpAll(() async {
    await loadTestFonts();
    await initializeDateFormatting('fr');
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('ESC/POS', () {
    test('accents en page 850, signes typographiques simplifiés', () {
      expect(EscPos.encode('é'), [0x82]);
      expect(EscPos.encode('Reçu'), [0x52, 0x65, 0x87, 0x75]);
      expect(EscPos.encode('l’été'), [0x6C, 0x27, 0x82, 0x74, 0x82]);
      expect(EscPos.encode('3 500 F'), '3 500 F'.codeUnits);
      expect(EscPos.encode('☺'), [0x3F]);
    });

    test('ligne libellé / montant calée sur la largeur du rouleau', () {
      final p = EscPos(width: 32)..row('Payé (Wave)', '9 000 F');
      final line = ticketText(p.bytes).split('\n').firstWhere((l) => l.contains('Wave'));
      expect(line.length, 32);
      expect(line, endsWith('9 000 F'));
      expect(EscPos.wrap('Beurre de karité bio extra pur 250 g', 20), ['Beurre de karité bio', 'extra pur 250 g']);
    });

    test('reçu complet : en-tête, lignes, total, coupe ; 80 mm plus large', () {
      final b = demoBusiness;
      final t58 = receiptEscPos(demoSale, b);
      final text = ticketText(t58);
      expect(text, contains('VEN-2026-0042'));
      expect(text, contains('TOTAL'));
      expect(text, contains('Merci de votre confiance !'));
      expect(t58.sublist(0, 2), [0x1B, 0x40]);
      expect(t58.sublist(t58.length - 4), [0x1D, 0x56, 0x41, 0x03]);
      final t80 = ticketText(receiptEscPos(demoSale, b, width: 48));
      expect(t80.split('\n').any((l) => l.length == 48), isTrue);
    });
  });

  testWidgets('reçu : choisir l’imprimante la première fois, puis imprimer directement', (tester) async {
    phoneSize(tester);
    final printer = FakeThermal();
    final actions = RecordingActions();
    await pumpSama(
      tester,
      location: '/sales/s2',
      overrides: [thermalPrinterProvider.overrideWithValue(printer), receiptActionsProvider.overrideWithValue(actions)],
    );
    await tester.tap(find.byKey(const Key('receipt_print')));
    await settle(tester);
    await tester.tap(find.text('Rouleau 80 mm'));
    await settle(tester);
    await tester.tap(find.byKey(const Key('printer_AA:BB:CC:DD:EE:FF')));
    await settle(tester);
    expect(printer.printed.single.$1, 'AA:BB:CC:DD:EE:FF');
    expect(ticketText(printer.printed.single.$2), contains('VEN-2026-0042'));
    expect(actions.printed, isNull); // pas de PDF
    expect(find.text('Imprimante : MPT-II · changer'), findsOneWidget);

    // Deuxième fois : directement, sans redemander
    await tester.tap(find.byKey(const Key('receipt_print')));
    await settle(tester);
    expect(printer.printed, hasLength(2));
    expect(find.byKey(const Key('printer_AA:BB:CC:DD:EE:FF')), findsNothing);
    expect(ticketText(printer.printed.last.$2).split('\n').any((l) => l.length == 48), isTrue);
  });

  testWidgets('imprimante éteinte : message clair, réessayer', (tester) async {
    phoneSize(tester);
    SharedPreferences.setMockInitialValues({
      'printer.bt': ['MPT-II', 'AA:BB:CC:DD:EE:FF', '32'],
    });
    final printer = FakeThermal()..fail = true;
    await pumpSama(tester, location: '/sales/s2', overrides: [thermalPrinterProvider.overrideWithValue(printer)]);
    await tester.tap(find.byKey(const Key('receipt_print')));
    await settle(tester);
    expect(find.byKey(const Key('printer_unreachable')), findsOneWidget);
    printer.fail = false;
    await tester.tap(find.text('Réessayer'));
    await settle(tester);
    expect(printer.printed, hasLength(1));
  });

  testWidgets('Bluetooth coupé : on le dit ; « Imprimer autrement » passe au PDF', (tester) async {
    phoneSize(tester);
    final printer = FakeThermal(on: false);
    final actions = RecordingActions();
    await pumpSama(
      tester,
      location: '/sales/s2',
      overrides: [thermalPrinterProvider.overrideWithValue(printer), receiptActionsProvider.overrideWithValue(actions)],
    );
    await tester.tap(find.byKey(const Key('receipt_print')));
    await settle(tester);
    expect(find.byKey(const Key('printer_bluetooth_off')), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('printer_pdf')));
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await settle(tester);
    expect(actions.printed, isNotNull);
    expect(printer.printed, isEmpty);
  });

  testWidgets('caisse : « Imprimer le reçu » juste après la vente', (tester) async {
    phoneSize(tester);
    SharedPreferences.setMockInitialValues({
      'printer.bt': ['MPT-II', 'AA:BB:CC:DD:EE:FF', '32'],
    });
    final printer = FakeThermal();
    final (c, _) = await pumpSama(
      tester,
      location: '/pos',
      overrides: [thermalPrinterProvider.overrideWithValue(printer)],
    );
    c.read(cartProvider.notifier).add(demoProducts[0]);
    await settle(tester);
    await tester.tap(find.textContaining('Encaisser'));
    await settle(tester);
    await tester.tap(find.byKey(const Key('sale_print')));
    await settle(tester);
    expect(printer.printed, hasLength(1));
  });
}
