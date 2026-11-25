import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/models.dart';
import 'package:sama360/core/widgets.dart';

void main() {
  testWidgets('vrais logos Wave, Orange Money, MTN MoMo, Moov Money et Airtel Money', (tester) async {
    const withLogo = [
      PayMethod.wave,
      PayMethod.orangeMoney,
      PayMethod.mtnMomo,
      PayMethod.moovMoney,
      PayMethod.airtelMoney,
    ];
    await tester.pumpWidget(
      MaterialApp(home: Row(children: [for (final m in withLogo) PayLogo(m), const PayLogo(PayMethod.cash)])),
    );
    final images = tester.widgetList<Image>(find.byType(Image)).toList();
    expect(images, hasLength(withLogo.length));
    for (final img in images) {
      final name = (img.image as AssetImage).assetName;
      expect(File(name).existsSync(), isTrue, reason: name);
    }
    // Espèces : une icône, pas d'image
    expect(find.byIcon(Icons.payments_rounded), findsOneWidget);
  });
}
