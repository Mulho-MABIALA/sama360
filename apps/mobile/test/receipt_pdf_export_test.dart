@Tags(['screenshots'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:sama360/features/sales/receipt.dart';

import 'helpers.dart';

void main() {
  if (Platform.environment['SAMA_SCREENSHOTS'] != '1') return;
  TestWidgetsFlutterBinding.ensureInitialized();
  test('export du PDF de démonstration', () async {
    await initializeDateFormatting('fr');
    final bytes = await buildReceiptPdf(demoSale, demoBusiness);
    File('test/screenshots/recu_demo.pdf').writeAsBytesSync(bytes);
  });
}
