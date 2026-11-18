// Audit d'accessibilité (contrastes, zones à toucher, libellés) sur les écrans principaux.
// Ne fait pas échouer la suite : écrit les constats dans /tmp/sama_a11y.json.
// Lancer : SAMA_AUDIT=1 flutter test test/audit_a11y_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sama360/core/api/session_store.dart';
import 'package:sama360/core/pin_lock.dart';
import 'package:sama360/core/providers.dart';
import 'package:sama360/features/auth/auth_controller.dart';
import 'package:sama360/main.dart';

import 'helpers.dart';

class _SignedOut extends AuthController {
  @override
  Future<AuthState> build() async => const AuthState();
}

final _results = <Map<String, Object?>>[];

Future<void> _check(WidgetTester tester, String screen) async {
  final handle = tester.ensureSemantics();
  final out = <String, Object?>{'screen': screen};
  for (final (name, g) in [
    ('contraste', textContrastGuideline),
    ('cible_android_48', androidTapTargetGuideline),
    ('cible_ios_44', iOSTapTargetGuideline),
    ('libelles', labeledTapTargetGuideline),
  ]) {
    final e = await g.evaluate(tester);
    out[name] = e.passed ? 'ok' : e.reason;
  }
  // Tailles de texte réellement affichées
  final sizes = <double>[];
  for (final el in find.byType(RichText).evaluate()) {
    final rt = el.widget as RichText;
    void walk(InlineSpan s, double? inherited) {
      final size = s.style?.fontSize ?? inherited;
      if (s is TextSpan) {
        if ((s.text ?? '').trim().isNotEmpty && size != null) sizes.add(size);
        for (final c in s.children ?? const <InlineSpan>[]) {
          walk(c, size);
        }
      }
    }

    walk(rt.text, rt.text.style?.fontSize);
  }
  out['textes'] = sizes.length;
  out['textes_moins_de_12'] = sizes.where((s) => s < 12).length;
  out['textes_12_a_14'] = sizes.where((s) => s >= 12 && s < 14).length;
  handle.dispose();
  _results.add(out);
}

void main() {
  final enabled = Platform.environment['SAMA_AUDIT'] == '1';
  setUpAll(loadTestFonts);
  tearDownAll(() {
    if (enabled) File('/tmp/sama_a11y.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(_results));
  });

  const routes = [
    '/',
    '/pos',
    '/stock',
    '/customers',
    '/sales',
    '/cash',
    '/invoices',
    '/reports',
    '/shop',
    '/deliveries',
    '/booking',
    '/pro',
    '/referral',
    '/account',
    '/status?ids=p2',
    '/notifications',
  ];

  for (final r in routes) {
    testWidgets('a11y $r', (tester) async {
      phoneSize(tester);
      await pumpSama(tester, location: r);
      await _check(tester, r);
    }, skip: !enabled);
  }

  testWidgets('a11y / (sombre)', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, dark: true);
    await _check(tester, '/ (mode sombre)');
  }, skip: !enabled);

  testWidgets('a11y connexion', (tester) async {
    phoneSize(tester);
    await initializeDateFormatting('fr');
    final c = ProviderContainer(
      overrides: [
        sessionStoreProvider.overrideWithValue(MemorySessionStore()),
        authProvider.overrideWith(_SignedOut.new),
      ],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const SamaApp(googleFonts: false)));
    await tester.pumpAndSettle();
    await _check(tester, 'connexion');
  }, skip: !enabled);

  testWidgets('a11y code PIN', (tester) async {
    phoneSize(tester);
    await pumpSama(tester, pinStore: MemoryPinStore(StoredPin(userId: 'u1', hash: hashPin('2580'))));
    await _check(tester, 'code PIN');
  }, skip: !enabled);
}
