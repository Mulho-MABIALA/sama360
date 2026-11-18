// Le bouton flottant ne doit jamais cacher la dernière ligne d'une liste (liste défilée tout en bas).
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers.dart';

void main() {
  setUpAll(loadTestFonts);

  const routes = ['/stock', '/customers', '/invoices', '/booking', '/deliveries', '/team', '/categories', '/purchases'];
  for (final r in routes) {
    testWidgets('bouton flottant sans recouvrement : $r', (tester) async {
      phoneSize(tester);
      await pumpSama(tester, location: r);
      final fab = find.byType(FloatingActionButton);
      if (fab.evaluate().isEmpty) return;
      final scrollables = find.byType(Scrollable).evaluate().where((e) {
        final s = e.widget as Scrollable;
        return s.axisDirection == AxisDirection.down;
      });
      for (final e in scrollables) {
        final pos = (e as StatefulElement).state as ScrollableState;
        pos.position.jumpTo(pos.position.maxScrollExtent);
      }
      await tester.pumpAndSettle();
      final fabRect = tester.getRect(fab.first);
      // Tous les éléments à toucher visibles hors du bouton lui-même
      final hits = <String>[];
      for (final f in [find.byType(InkWell), find.byType(GestureDetector)]) {
        for (final el in f.evaluate()) {
          if (find.descendant(of: fab.first, matching: find.byWidget(el.widget)).evaluate().isNotEmpty) continue;
          if (find.ancestor(of: find.byWidget(el.widget), matching: fab.first).evaluate().isNotEmpty) continue;
          final ro = el.renderObject;
          if (ro is! RenderBox || !ro.hasSize || !ro.attached) continue;
          final rect = ro.localToGlobal(Offset.zero) & ro.size;
          if (rect.height > 400) continue; // conteneurs pleine page
          final inter = rect.intersect(fabRect);
          if (inter.width > 4 && inter.height > 4 && rect.top < fabRect.bottom && rect.bottom > fabRect.top) {
            hits.add('${el.widget.runtimeType} $rect');
          }
        }
      }
      expect(hits, isEmpty, reason: 'Le bouton flottant ($fabRect) recouvre : $hits');
    });
  }
}
