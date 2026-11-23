import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../../core/api/session_store.dart';
import '../../core/models.dart';
import '../../core/offline/pending_sales.dart';
import '../../core/pin_lock.dart';
import '../../core/push.dart';
import '../../core/providers.dart';

class AuthState {
  const AuthState({this.me, this.businessId});
  final Me? me;
  final String? businessId;

  bool get signedIn => me != null;
  bool get needsProfile => me?.needsProfile ?? false;
  BusinessLink? get business => me?.businesses.where((b) => b.id == businessId).firstOrNull;
}

/// Session de l'utilisateur : connexion OTP, profil, entreprise choisie, déconnexion.
class AuthController extends AsyncNotifier<AuthState> {
  SessionStore get _store => ref.read(sessionStoreProvider);
  ApiClient get _api => ref.read(apiClientProvider);

  @override
  Future<AuthState> build() async {
    final session = await _store.read();
    if (session == null) return const AuthState();
    try {
      return await _load();
    } on ApiException catch (e) {
      if (e.status == 401) {
        await _store.clear();
        return const AuthState();
      }
      rethrow; // réseau : l'écran de démarrage propose de réessayer
    }
  }

  /// Charge le profil et choisit l'entreprise : celle mémorisée, sinon la seule disponible.
  Future<AuthState> _load() async {
    final me = await ref.read(repoProvider).me();
    var businessId = await _store.readBusinessId();
    if (!me.businesses.any((b) => b.id == businessId)) {
      businessId = me.businesses.length == 1 ? me.businesses.first.id : null;
      await _store.saveBusinessId(businessId);
    }
    _api.businessId = businessId;
    return AuthState(me: me, businessId: businessId);
  }

  Future<OtpTarget> requestOtp(String phone, {OtpChannel? channel}) =>
      ref.read(repoProvider).requestOtp(phone, channel: channel);

  /// Vrai si la connexion a rétabli un compte supprimé il y a moins de 30 jours.
  Future<bool> verifyOtp(String phone, String code) async {
    final t = await ref.read(repoProvider).verifyOtp(phone, code);
    await _store.save(Session(accessToken: t.access, refreshToken: t.refresh));
    state = AsyncData(await _load());
    return t.restored;
  }

  Future<void> saveName(String fullName) async {
    await ref.read(repoProvider).updateName(fullName.trim());
    state = AsyncData(await _load());
  }

  Future<void> updateProfile({required String fullName, String? email}) async {
    await ref.read(repoProvider).updateProfile(fullName: fullName.trim(), email: email?.trim());
    state = AsyncData(await _load());
  }

  Future<void> setAvatar(List<int> bytes, String filename) async {
    await ref.read(repoProvider).uploadAvatar(bytes, filename: filename);
    state = AsyncData(await _load());
  }

  Future<void> removeAvatar() async {
    await ref.read(repoProvider).deleteAvatar();
    state = AsyncData(await _load());
  }

  /// Déconnecte tous les appareils (celui-ci compris).
  Future<void> signOutEverywhere() async {
    await ref.read(repoProvider).logoutAll();
    await ref.read(pendingSalesProvider.notifier).clear();
    await ref.read(pushProvider.notifier).stop();
    await _clearLocal();
    await ref.read(pinLockProvider.notifier).forget();
  }

  Future<void> createBusiness({
    required String name,
    String? category,
    String? city,
    String? focus,
    String? country,
    String? referralCode,
  }) async {
    final id = await ref
        .read(repoProvider)
        .createBusiness(
          name: name.trim(),
          category: category,
          city: city,
          focus: focus,
          country: country,
          referralCode: referralCode,
        );
    await _store.saveBusinessId(id);
    state = AsyncData(await _load());
  }

  Future<void> selectBusiness(String id) async {
    await _store.saveBusinessId(id);
    _api.businessId = id;
    state = AsyncData(AuthState(me: state.value?.me, businessId: id));
  }

  /// Propriétaire : supprime la boutique courante, puis passe à une autre (ou à la création).
  Future<void> deleteCurrentBusiness(String confirmName) async {
    await ref.read(repoProvider).deleteBusiness(confirmName);
    await ref.read(pendingSalesProvider.notifier).clear();
    await ref.read(repoProvider).clearCache();
    await _store.saveBusinessId(null);
    state = AsyncData(await _load());
  }

  /// Rétablit une boutique supprimée et l'ouvre.
  Future<void> restoreBusiness(String id) async {
    await ref.read(repoProvider).restoreBusiness(id);
    await ref.read(repoProvider).clearCache();
    await _store.saveBusinessId(id);
    state = AsyncData(await _load());
  }

  /// Supprime le compte : tout est effacé sur ce téléphone (30 jours pour revenir en se reconnectant).
  Future<void> deleteAccount(String confirm) async {
    await ref.read(repoProvider).deleteAccount(confirm);
    await ref.read(pendingSalesProvider.notifier).clear();
    await ref.read(pushProvider.notifier).stop();
    await _clearLocal();
    await ref.read(pinLockProvider.notifier).forget();
  }

  Future<void> reload() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(build);
  }

  Future<void> signOut() async {
    // Les ventes pas encore envoyées sont abandonnées (l'écran prévient avant).
    await ref.read(pendingSalesProvider.notifier).clear();
    // Ce téléphone ne reçoit plus les notifications de ce compte
    await ref.read(pushProvider.notifier).stop();
    final session = await _store.read();
    if (session != null) {
      try {
        await ref.read(repoProvider).logout(session.refreshToken);
      } catch (_) {
        // hors ligne : la session locale est effacée quand même
      }
    }
    await _clearLocal();
    // Déconnexion volontaire : le code secret est effacé (le prochain compte créera le sien)
    await ref.read(pinLockProvider.notifier).forget();
  }

  /// Appelé par le client API quand la session ne peut plus être rafraîchie.
  Future<void> sessionExpired() => _clearLocal();

  Future<void> _clearLocal() async {
    await _store.clear();
    await ref.read(repoProvider).clearCache();
    _api.businessId = null;
    state = const AsyncData(AuthState());
  }
}

final authProvider = AsyncNotifierProvider<AuthController, AuthState>(AuthController.new);
