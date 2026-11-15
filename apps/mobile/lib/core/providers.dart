import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api/api_client.dart';
import 'api/session_store.dart';
import 'config.dart';
import 'models.dart';
import 'permissions.dart';
import 'repositories.dart';
import '../features/auth/auth_controller.dart';

/// Remplacé dans main() (stockage sécurisé) et dans les tests (mémoire).
final sessionStoreProvider = Provider<SessionStore>((ref) => throw UnimplementedError('sessionStoreProvider'));

/// Remplaçable dans les tests pour viser une autre API.
final apiBaseUrlProvider = Provider<String>((ref) => apiUrl);

final apiClientProvider = Provider<ApiClient>((ref) {
  final client = ApiClient(baseUrl: ref.watch(apiBaseUrlProvider), store: ref.watch(sessionStoreProvider));
  client.onSessionExpired = () => ref.read(authProvider.notifier).sessionExpired();
  return client;
});

final repoProvider = Provider<SamaRepository>((ref) => SamaRepository(ref.watch(apiClientProvider)));

/// Entreprise sélectionnée : toutes les données en dépendent et se rechargent quand elle change.
final businessIdProvider = Provider<String?>((ref) => ref.watch(authProvider).value?.businessId);

final currentBusinessProvider = FutureProvider<CurrentBusiness>((ref) {
  final id = ref.watch(businessIdProvider);
  if (id == null) throw StateError('Aucune entreprise sélectionnée');
  return ref.watch(repoProvider).currentBusiness();
});

/// Vrai si l'utilisateur a la permission dans l'entreprise courante (faux tant que c'est inconnu).
final canProvider = Provider.family<bool, String>((ref, permission) {
  final b = ref.watch(currentBusinessProvider).value;
  return b != null && hasPermission(b.permissions, permission);
});

final summaryProvider = FutureProvider<DaySummary>((ref) {
  ref.watch(businessIdProvider);
  return ref.watch(repoProvider).todaySummary();
});

final stockProvider = FutureProvider<StockOverview>((ref) {
  ref.watch(businessIdProvider);
  return ref.watch(repoProvider).stock();
});

final categoriesProvider = FutureProvider<List<Category>>((ref) {
  ref.watch(businessIdProvider);
  return ref.watch(repoProvider).categories();
});

final productsProvider = FutureProvider<List<Product>>((ref) {
  ref.watch(businessIdProvider);
  return ref.watch(repoProvider).products();
});

final debtorsProvider = FutureProvider<List<Debtor>>((ref) {
  ref.watch(businessIdProvider);
  return ref.watch(repoProvider).debtors();
});

final ledgerProvider = FutureProvider.family<Ledger, String>((ref, customerId) {
  ref.watch(businessIdProvider);
  return ref.watch(repoProvider).ledger(customerId);
});

/// Après une vente, un remboursement ou une entrée de stock : rafraîchit ce qui en dépend.
void refreshBusinessData(WidgetRef ref) {
  ref.invalidate(summaryProvider);
  ref.invalidate(stockProvider);
  ref.invalidate(productsProvider);
  ref.invalidate(debtorsProvider);
  ref.invalidate(ledgerProvider);
}

/// Message lisible pour l'utilisateur à partir de n'importe quelle erreur.
String errorMessage(Object error) {
  if (error is ApiException) return error.message;
  return 'Une erreur est survenue. Réessayez.';
}
