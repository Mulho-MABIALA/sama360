import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sama360/core/providers.dart';
import 'package:sama360/core/push.dart';

import 'helpers.dart';

/// Téléphone Android simulé : autorisation, jeton, notification touchée.
class FakePush implements PushPlatform {
  FakePush({this.allowed = PushPermission.notAsked, this.grant = PushPermission.granted});
  PushPermission allowed;
  final PushPermission grant;
  int requests = 0;
  bool deleted = false;
  final opened = StreamController<String?>.broadcast();
  final foreground = StreamController<String?>.broadcast();
  final refreshed = StreamController<String>.broadcast();

  @override
  String get name => 'android';
  @override
  Future<bool> init(PushWebConfig? web) async => true;
  @override
  Future<PushPermission> permission() async => allowed;
  @override
  Future<PushPermission> request() async {
    requests++;
    return allowed = grant;
  }

  @override
  Future<String?> token() async => 'jeton-android-${'x' * 30}';
  @override
  Future<void> deleteToken() async => deleted = true;
  @override
  Stream<String> get onTokenRefresh => refreshed.stream;
  @override
  Stream<String?> get onForeground => foreground.stream;
  @override
  Stream<String?> get onOpen => opened.stream;
  @override
  Future<String?> initialLink() async => null;
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('Android : autorisation demandée une fois, appareil abonné, notification touchée', (tester) async {
    phoneSize(tester);
    final push = FakePush();
    final (c, repo) = await pumpSama(tester, push: push);
    await tester.pumpAndSettle();
    expect(push.requests, 1);
    expect(repo.pushTokens, {'jeton-android-${'x' * 30}': 'android'});
    expect(c.read(pushProvider).active, isTrue);

    // Une notification touchée ouvre son écran
    push.opened.add('/notifications');
    await tester.pumpAndSettle();
    expect(routerOf(c).state.uri.path, '/notifications');
    expect(find.byKey(const Key('push_banner')), findsNothing); // déjà abonné
  });

  test('déconnexion : ce téléphone ne reçoit plus les notifications du compte', () async {
    final push = FakePush(allowed: PushPermission.granted);
    final repo = FakeRepo();
    final c = ProviderContainer(
      overrides: [repoProvider.overrideWithValue(repo), pushPlatformProvider.overrideWithValue(push)],
    );
    addTearDown(c.dispose);
    await c.read(pushProvider.notifier).start();
    expect(push.requests, 0); // déjà autorisé
    expect(repo.pushTokens, hasLength(1));
    await c.read(pushProvider.notifier).stop();
    expect(repo.pushTokens, isEmpty);
    expect(push.deleted, isTrue);
    expect(c.read(pushProvider).active, isFalse);
  });

  testWidgets('refusée au départ : bandeau « Activer » dans les notifications', (tester) async {
    phoneSize(tester);
    final push = FakePush(grant: PushPermission.denied);
    final (c, repo) = await pumpSama(tester, location: '/notifications', push: push);
    await tester.pumpAndSettle();
    // Refusée à la première demande : expliqué, pas de bouton
    expect(find.text('Notifications bloquées'), findsOneWidget);
    expect(repo.pushTokens, isEmpty);
  });

  testWidgets('pas encore demandée (navigateur) : le bouton « Activer » abonne l’appareil', (tester) async {
    phoneSize(tester);
    final push = _WebPush();
    final (c, repo) = await pumpSama(tester, location: '/notifications', push: push);
    await tester.pumpAndSettle();
    expect(push.requests, 0); // le navigateur exige un geste
    expect(find.text('Être prévenu sur ce téléphone'), findsOneWidget);
    await tester.tap(find.byKey(const Key('push_enable')));
    await tester.pumpAndSettle();
    expect(push.requests, 1);
    expect(repo.pushTokens.values, ['web']);
    expect(find.byKey(const Key('push_banner')), findsNothing);
  });
}

class _WebPush extends FakePush {
  @override
  String get name => 'web';
}
