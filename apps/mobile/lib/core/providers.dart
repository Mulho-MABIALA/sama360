import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api/api_client.dart';
import 'api/session_store.dart';
import 'config.dart';
import 'models.dart';
import 'offline/pending_sales.dart';
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

final repoProvider = Provider<SamaRepository>(
  (ref) => SamaRepository(ref.watch(apiClientProvider), cache: ref.watch(keyValueStoreProvider)),
);

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

/// Stock tel que le serveur le connaît.
final stockRawProvider = FutureProvider<StockOverview>((ref) {
  ref.watch(businessIdProvider);
  return ref.watch(repoProvider).stock();
});

/// Stock affiché : celui du serveur moins les ventes faites hors ligne pas encore envoyées.
final stockProvider = FutureProvider<StockOverview>((ref) async {
  final pending = ref.watch(pendingForBusinessProvider);
  return stockNetOfPending(await ref.watch(stockRawProvider.future), pending);
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

final saleProvider = FutureProvider.family<SaleDetail, String>((ref, id) {
  ref.watch(businessIdProvider);
  return ref.watch(repoProvider).sale(id);
});

/// Ventes du jour : toutes pour qui voit les rapports, sinon seulement les miennes.
final salesTodayProvider = FutureProvider<List<SaleSummary>>((ref) async {
  ref.watch(businessIdProvider);
  final b = await ref.watch(currentBusinessProvider.future);
  return ref.watch(repoProvider).salesOfDay(null, !hasPermission(b.permissions, 'reports:read'));
});

final myDayProvider = FutureProvider<MyDay>((ref) {
  ref.watch(businessIdProvider);
  return ref.watch(repoProvider).myDay();
});

final membersProvider = FutureProvider<List<Member>>((ref) {
  ref.watch(businessIdProvider);
  return ref.watch(repoProvider).members();
});

/// Rapport d'une période (dates sans heure).
final reportProvider = FutureProvider.family<ReportOverview, ({DateTime from, DateTime to})>((ref, p) {
  ref.watch(businessIdProvider);
  return ref.watch(repoProvider).report(p.from, p.to);
});

final productProvider = FutureProvider.family<Product, String>((ref, id) {
  ref.watch(businessIdProvider);
  return ref.watch(repoProvider).product(id);
});

final invoicingSummaryProvider = FutureProvider<InvoicingSummary>((ref) {
  ref.watch(businessIdProvider);
  return ref.watch(repoProvider).invoicingSummary();
});

/// Liste par type et filtre : (type, statut(s), en retard).
final documentsProvider = FutureProvider.family<List<DocSummary>, ({DocKind kind, String? status, bool overdue})>((
  ref,
  f,
) {
  ref.watch(businessIdProvider);
  return ref.watch(repoProvider).documents(kind: f.kind, status: f.status, overdue: f.overdue);
});

final documentProvider = FutureProvider.family<DocDetail, String>((ref, id) {
  ref.watch(businessIdProvider);
  return ref.watch(repoProvider).document(id);
});

/// Après une action sur un devis / une facture.
void refreshInvoicing(WidgetRef ref) {
  ref.invalidate(invoicingSummaryProvider);
  ref.invalidate(documentsProvider);
  ref.invalidate(documentProvider);
  ref.invalidate(stockRawProvider);
}

/// Après une vente, un remboursement ou une entrée de stock : rafraîchit ce qui en dépend.
void refreshBusinessData(WidgetRef ref) {
  ref.invalidate(summaryProvider);
  ref.invalidate(stockRawProvider);
  ref.invalidate(productsProvider);
  ref.invalidate(debtorsProvider);
  ref.invalidate(ledgerProvider);
  ref.invalidate(salesTodayProvider);
  ref.invalidate(myDayProvider);
}

/// Message lisible pour l'utilisateur à partir de n'importe quelle erreur.
String errorMessage(Object error) {
  if (error is ApiException) return error.message;
  return 'Une erreur est survenue. Réessayez.';
}
