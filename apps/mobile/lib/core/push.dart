import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'offline/pending_sales.dart' show keyValueStoreProvider;
import 'providers.dart';

/// Autorisation d'afficher des notifications sur cet appareil.
enum PushPermission { granted, denied, notAsked, unsupported }

/// Configuration de la version web (appli Web Firebase), donnée par le serveur.
class PushWebConfig {
  const PushWebConfig({
    required this.apiKey,
    required this.appId,
    required this.projectId,
    required this.messagingSenderId,
    required this.vapidKey,
  });
  final String apiKey;
  final String appId;
  final String projectId;
  final String messagingSenderId;
  final String vapidKey;

  static PushWebConfig? fromJson(Map<String, dynamic>? j) => j == null
      ? null
      : PushWebConfig(
          apiKey: j['apiKey'] as String,
          appId: j['appId'] as String,
          projectId: j['projectId'] as String,
          messagingSenderId: j['messagingSenderId'] as String,
          vapidKey: j['vapidKey'] as String,
        );
}

/// Accès aux notifications du système (Firebase), remplaçable dans les tests.
abstract class PushPlatform {
  /// android, ios ou web
  String get name;
  Future<bool> init(PushWebConfig? web);
  Future<PushPermission> permission();
  Future<PushPermission> request();
  Future<String?> token();
  Future<void> deleteToken();
  Stream<String> get onTokenRefresh;

  /// Notification reçue app ouverte
  Stream<String?> get onForeground;

  /// Notification touchée (app en arrière-plan) : écran à ouvrir
  Stream<String?> get onOpen;

  /// Notification qui a lancé l'app
  Future<String?> initialLink();
}

/// Appareils sans notifications (ordinateur de bureau, tests).
class NoPush implements PushPlatform {
  const NoPush();
  @override
  String get name => 'none';
  @override
  Future<bool> init(PushWebConfig? web) async => false;
  @override
  Future<PushPermission> permission() async => PushPermission.unsupported;
  @override
  Future<PushPermission> request() async => PushPermission.unsupported;
  @override
  Future<String?> token() async => null;
  @override
  Future<void> deleteToken() async {}
  @override
  Stream<String> get onTokenRefresh => const Stream.empty();
  @override
  Stream<String?> get onForeground => const Stream.empty();
  @override
  Stream<String?> get onOpen => const Stream.empty();
  @override
  Future<String?> initialLink() async => null;
}

PushPermission _status(AuthorizationStatus s) => switch (s) {
  AuthorizationStatus.authorized || AuthorizationStatus.provisional => PushPermission.granted,
  AuthorizationStatus.denied || AuthorizationStatus.deniedPermanently => PushPermission.denied,
  AuthorizationStatus.notDetermined => PushPermission.notAsked,
};

class FirebasePush implements PushPlatform {
  FirebasePush(this.name);
  @override
  final String name;
  String? _vapidKey;
  FirebaseMessaging get _m => FirebaseMessaging.instance;

  @override
  Future<bool> init(PushWebConfig? web) async {
    try {
      if (kIsWeb) {
        if (web == null) return false;
        _vapidKey = web.vapidKey;
        if (Firebase.apps.isEmpty) {
          await Firebase.initializeApp(
            options: FirebaseOptions(
              apiKey: web.apiKey,
              appId: web.appId,
              projectId: web.projectId,
              messagingSenderId: web.messagingSenderId,
            ),
          );
        }
        // Safari sur iPhone : seulement une fois Sama360 ajouté à l'écran d'accueil
        return await _m.isSupported();
      }
      // Android : configuration lue dans google-services.json (absent : pas de notifications)
      if (Firebase.apps.isEmpty) await Firebase.initializeApp();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<PushPermission> permission() async => _status((await _m.getNotificationSettings()).authorizationStatus);

  @override
  Future<PushPermission> request() async => _status((await _m.requestPermission()).authorizationStatus);

  /// Inscription auprès de Firebase : le jeton arrive par [FirebaseMessaging.onRegistered].
  @override
  Future<String?> token() async {
    final next = _m.onRegistered.first.timeout(const Duration(seconds: 20));
    await _m.register(vapidKey: _vapidKey);
    try {
      return await next;
    } on TimeoutException {
      return null;
    }
  }

  @override
  Future<void> deleteToken() => _m.unregister();

  @override
  Stream<String> get onTokenRefresh => _m.onRegistered;

  @override
  Stream<String?> get onForeground => FirebaseMessaging.onMessage.map((m) => m.data['link'] as String?);

  @override
  Stream<String?> get onOpen => FirebaseMessaging.onMessageOpenedApp.map((m) => m.data['link'] as String?);

  @override
  Future<String?> initialLink() async => (await _m.getInitialMessage())?.data['link'] as String?;
}

/// Firebase sur le web et sur Android ; rien ailleurs (ordinateur). Les tests le remplacent.
final pushPlatformProvider = Provider<PushPlatform>((ref) {
  if (kIsWeb) return FirebasePush('web');
  if (defaultTargetPlatform == TargetPlatform.android) return FirebasePush('android');
  return const NoPush();
});

class PushState {
  const PushState({this.available = false, this.permission = PushPermission.unsupported, this.token});

  /// Notifications possibles sur cet appareil (Firebase configuré et pris en charge)
  final bool available;
  final PushPermission permission;
  final String? token;
  bool get active => available && permission == PushPermission.granted && token != null;

  PushState copyWith({bool? available, PushPermission? permission, String? token}) => PushState(
    available: available ?? this.available,
    permission: permission ?? this.permission,
    token: token ?? this.token,
  );
}

/// Abonne cet appareil aux notifications du compte connecté.
class PushController extends Notifier<PushState> {
  static const _askedKey = 'push.asked';
  final _subs = <StreamSubscription<Object?>>[];
  bool _started = false;

  /// Ouvre l'écran d'une notification touchée (branché par l'app sur le routeur).
  void Function(String link)? onOpenLink;

  @override
  PushState build() {
    ref.onDispose(() {
      for (final s in _subs) {
        s.cancel();
      }
    });
    return const PushState();
  }

  PushPlatform get _platform => ref.read(pushPlatformProvider);

  /// Après la connexion : prépare Firebase, et abonne l'appareil si c'est déjà autorisé.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    final p = _platform;
    if (p is NoPush) return;
    try {
      final web = kIsWeb ? await ref.read(repoProvider).pushWebConfig() : null;
      if (!await p.init(web)) return;
      state = state.copyWith(available: true, permission: await p.permission());
      _subs
        ..add(p.onTokenRefresh.listen(_register))
        ..add(
          p.onForeground.listen((_) {
            ref.invalidate(notificationsProvider);
            ref.invalidate(unreadNotificationsProvider);
          }),
        )
        ..add(p.onOpen.listen(_openLink));
      final first = await p.initialLink();
      if (first != null) _openLink(first);

      // Android : la première fois, on demande tout de suite (le système affiche sa fenêtre)
      final store = ref.read(keyValueStoreProvider);
      if (state.permission == PushPermission.notAsked && p.name == 'android' && store.getString(_askedKey) == null) {
        await store.setString(_askedKey, '1');
        state = state.copyWith(permission: await p.request());
      }
      if (state.permission == PushPermission.granted) await _register(await p.token());
    } catch (_) {
      // Pas de notifications sur cet appareil : l'app marche normalement
    }
  }

  /// Bouton « Activer les notifications » (le navigateur exige un geste de la personne).
  Future<bool> enable() async {
    final p = _platform;
    if (!_started) await start();
    if (!state.available) return false;
    final perm = await p.request();
    state = state.copyWith(permission: perm);
    if (perm != PushPermission.granted) return false;
    await _register(await p.token());
    return state.active;
  }

  /// Déconnexion : ce téléphone ne reçoit plus les notifications de ce compte.
  Future<void> stop() async {
    final token = state.token;
    if (token != null) {
      try {
        await ref.read(repoProvider).unregisterPushToken(token);
        await _platform.deleteToken();
      } catch (_) {}
    }
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    _started = false;
    state = PushState(available: state.available, permission: state.permission);
  }

  Future<void> _register(String? token) async {
    if (token == null || token.length < 20) return;
    await ref.read(repoProvider).registerPushToken(token, _platform.name);
    state = state.copyWith(token: token);
  }

  void _openLink(String? link) {
    if (link == null || !link.startsWith('/')) return;
    onOpenLink?.call(link);
  }
}

final pushProvider = NotifierProvider<PushController, PushState>(PushController.new);
