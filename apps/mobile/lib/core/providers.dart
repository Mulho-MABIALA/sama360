import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'admin_models.dart';
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
/// Adresse du serveur choisie dans l'app (versions de test) ; sinon celle de la compilation.
class ServerUrl extends Notifier<String> {
  static const key = 'settings:api_url';

  @override
  String build() {
    final saved = ref.watch(keyValueStoreProvider).getString(key);
    return saved == null || saved.isEmpty ? apiUrl : saved;
  }

  Future<void> set(String? url) async {
    final clean = url?.trim().replaceAll(RegExp(r'/+$'), '');
    await ref.read(keyValueStoreProvider).setString(key, clean ?? '');
    state = clean == null || clean.isEmpty ? apiUrl : clean;
  }
}

final serverUrlProvider = NotifierProvider<ServerUrl, String>(ServerUrl.new);

final apiBaseUrlProvider = Provider<String>((ref) => ref.watch(serverUrlProvider));

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

/// Point de vente choisi (null = tous), mémorisé pour chaque entreprise sur ce téléphone.
class LocationChoice extends Notifier<String?> {
  static String keyFor(String? businessId) => 'location:${businessId ?? '-'}';

  @override
  String? build() {
    final biz = ref.watch(businessIdProvider);
    final saved = ref.watch(keyValueStoreProvider).getString(keyFor(biz));
    final id = saved == null || saved.isEmpty ? null : saved;
    _apply(id);
    return id;
  }

  Future<void> select(String? id) async {
    await ref.read(keyValueStoreProvider).setString(keyFor(ref.read(businessIdProvider)), id ?? '');
    _apply(id);
    state = id;
  }

  /// Le client du dépôt est d'ordinaire le même que apiClientProvider (différent dans les tests).
  void _apply(String? id) {
    ref.read(apiClientProvider).locationId = id;
    ref.read(repoProvider).api.locationId = id;
  }
}

final locationIdProvider = NotifierProvider<LocationChoice, String?>(LocationChoice.new);

/// Entreprise + point de vente : tout ce qui en dépend se recharge quand l'un change.
final scopeProvider = Provider<String>((ref) => '${ref.watch(businessIdProvider)}|${ref.watch(locationIdProvider)}');

/// Points de vente de l'entreprise et celui actif pour moi.
final locationsProvider = FutureProvider<LocationsState>((ref) {
  ref.watch(scopeProvider);
  return ref.watch(repoProvider).locations();
});

final currentBusinessProvider = FutureProvider<CurrentBusiness>((ref) {
  final id = ref.watch(businessIdProvider);
  if (id == null) throw StateError('Aucune entreprise sélectionnée');
  ref.watch(locationIdProvider);
  return ref.watch(repoProvider).currentBusiness();
});

// ── Sama360 Pro

/// Pro actif ? (vrai tant que l'entreprise charge, pour ne rien verrouiller à tort)
final isProProvider = Provider<bool>((ref) => ref.watch(currentBusinessProvider).value?.isPro ?? true);

final subscriptionProvider = FutureProvider.autoDispose<ProStatus>((ref) => ref.watch(repoProvider).subscription());

final referralsProvider = FutureProvider.autoDispose<ReferralInfo>((ref) => ref.watch(repoProvider).referrals());

/// Membre de l'équipe Sama360 (valide les paiements) ; faux en cas d'erreur.
final platformAdminProvider = FutureProvider<bool>((ref) async {
  try {
    return await ref.watch(repoProvider).isPlatformAdmin();
  } catch (_) {
    return false;
  }
});

final adminPaymentsProvider = FutureProvider.autoDispose.family<List<PaymentRequest>, String>(
  (ref, status) => ref.watch(repoProvider).adminPaymentRequests(status: status),
);

/// Back office : suggestions des commerçants, par statut.
final adminFeedbackProvider = FutureProvider.autoDispose
    .family<({List<AdminFeedback> items, Map<FeedbackStatus, int> counts}), FeedbackStatus>(
      (ref, status) => ref.watch(repoProvider).adminFeedback(status),
    );

/// Back office : tableau de bord sur une période (jours).
final adminOverviewProvider = FutureProvider.autoDispose.family<AdminOverview, int>(
  (ref, days) => ref.watch(repoProvider).adminOverview(days: days),
);

final adminBusinessesProvider = FutureProvider.autoDispose.family<AdminPage<AdminBusiness>, AdminBusinessQuery>(
  (ref, q) => ref.watch(repoProvider).adminBusinesses(q),
);

final adminBusinessProvider = FutureProvider.autoDispose.family<AdminBusinessDetail, String>(
  (ref, id) => ref.watch(repoProvider).adminBusiness(id),
);

final adminAllPaymentsProvider = FutureProvider.autoDispose
    .family<({List<AdminPayment> items, bool hasMore}), ({AdminPayStatus? status, bool? online})>(
      (ref, f) => ref.watch(repoProvider).adminPayments(status: f.status, online: f.online),
    );

/// Mes boutiques supprimées, encore restaurables (liste vide en cas d'erreur).
final deletedBusinessesProvider = FutureProvider.autoDispose<List<DeletedBusiness>>((ref) async {
  try {
    return await ref.watch(repoProvider).deletedBusinesses();
  } catch (_) {
    return const [];
  }
});

/// Moyens de recevoir le code de connexion (WhatsApp, SMS, appel), le premier par défaut.
final otpChannelsProvider = FutureProvider<List<OtpChannel>>((ref) => ref.watch(repoProvider).otpChannels());

/// Moyen choisi par la personne sur cet appareil (retenu pour la prochaine fois).
class PreferredOtpChannel extends Notifier<OtpChannel?> {
  static const _key = 'login.otp_channel';
  @override
  OtpChannel? build() => OtpChannel.fromApi(ref.watch(keyValueStoreProvider).getString(_key));
  Future<void> set(OtpChannel c) async {
    state = c;
    await ref.read(keyValueStoreProvider).setString(_key, c.name);
  }
}

final preferredOtpChannelProvider = NotifierProvider<PreferredOtpChannel, OtpChannel?>(PreferredOtpChannel.new);

/// Pays choisi à la connexion (avant d'avoir une entreprise).
class LoginCountry extends Notifier<Country> {
  @override
  Country build() => Country.sn;
  void set(Country c) => state = c;
}

final loginCountryProvider = NotifierProvider<LoginCountry, Country>(LoginCountry.new);

/// Pays de travail : celui de l'entreprise, sinon celui choisi à la connexion.
final countryProvider = Provider<Country>(
  (ref) => ref.watch(currentBusinessProvider).value?.country ?? ref.watch(loginCountryProvider),
);

/// Vrai si l'utilisateur a la permission dans l'entreprise courante (faux tant que c'est inconnu).
final canProvider = Provider.family<bool, String>((ref, permission) {
  final b = ref.watch(currentBusinessProvider).value;
  return b != null && hasPermission(b.permissions, permission);
});

final summaryProvider = FutureProvider<DaySummary>((ref) {
  ref.watch(scopeProvider);
  return ref.watch(repoProvider).todaySummary();
});

/// Stock tel que le serveur le connaît.
final stockRawProvider = FutureProvider<StockOverview>((ref) {
  ref.watch(scopeProvider);
  return ref.watch(repoProvider).stock();
});

/// Stock affiché : celui du serveur moins les ventes faites hors ligne pas encore envoyées.
final stockProvider = FutureProvider<StockOverview>((ref) async {
  final pending = ref.watch(pendingForBusinessProvider);
  return stockNetOfPending(await ref.watch(stockRawProvider.future), pending);
});

final categoriesProvider = FutureProvider<List<Category>>((ref) {
  ref.watch(scopeProvider);
  return ref.watch(repoProvider).categories();
});

final productsProvider = FutureProvider<List<Product>>((ref) {
  ref.watch(scopeProvider);
  return ref.watch(repoProvider).products();
});

/// Catalogue affiché : les produits simples et les modèles (leurs variantes sont rangées dessous).
final catalogProductsProvider = FutureProvider<List<Product>>(
  (ref) async => (await ref.watch(productsProvider.future)).where((p) => !p.isVariant).toList(),
);

/// Ce qui se vend, s'achète et se compte : produits simples et variantes (pas les modèles).
final sellableProductsProvider = FutureProvider<List<Product>>(
  (ref) async => (await ref.watch(productsProvider.future)).where((p) => !p.hasVariants).toList(),
);

/// Variantes d'un modèle, dans l'ordre de ses options.
List<Product> variantsOf(Product parent, List<Product> all) {
  final vs = all.where((p) => p.parentId == parent.id).toList();
  int rank(Product v) {
    var r = 0;
    for (final a in parent.variantAxes) {
      r = r * 100 + a.values.indexOf(v.options[a.name] ?? '').clamp(0, 99);
    }
    return r;
  }

  vs.sort((a, b) => rank(a).compareTo(rank(b)));
  return vs;
}

final debtorsProvider = FutureProvider<List<Debtor>>((ref) {
  ref.watch(scopeProvider);
  return ref.watch(repoProvider).debtors();
});

final ledgerProvider = FutureProvider.family<Ledger, String>((ref, customerId) {
  ref.watch(scopeProvider);
  return ref.watch(repoProvider).ledger(customerId);
});

typedef CustomerQuery = ({String search, CustomerFilter filter, CustomerSort sort});

final customerListProvider = FutureProvider.family<CustomerList, CustomerQuery>((ref, q) {
  ref.watch(scopeProvider);
  return ref.watch(repoProvider).customerList(search: q.search, filter: q.filter, sort: q.sort);
});

final customerOverviewProvider = FutureProvider.family<CustomerOverview, String>((ref, id) {
  ref.watch(scopeProvider);
  return ref.watch(repoProvider).customerOverview(id);
});

final purchasesProvider = FutureProvider.family<PurchaseList, ({PurchaseFilter filter, String? supplierId})>((ref, q) {
  ref.watch(scopeProvider);
  return ref.watch(repoProvider).purchases(filter: q.filter, supplierId: q.supplierId);
});

final purchaseProvider = FutureProvider.family<PurchaseDetail, String>((ref, id) {
  ref.watch(scopeProvider);
  return ref.watch(repoProvider).purchase(id);
});

final suppliersProvider = FutureProvider.family<List<SupplierRow>, String>((ref, search) {
  ref.watch(scopeProvider);
  return ref.watch(repoProvider).suppliers(search: search);
});

final supplierProvider = FutureProvider.family<SupplierOverview, String>((ref, id) {
  ref.watch(scopeProvider);
  return ref.watch(repoProvider).supplierOverview(id);
});

/// Après un achat, une réception ou un paiement fournisseur : rafraîchit les achats et le stock.
void refreshPurchasing(WidgetRef ref) {
  ref.invalidate(purchasesProvider);
  ref.invalidate(purchaseProvider);
  ref.invalidate(suppliersProvider);
  ref.invalidate(supplierProvider);
  ref.invalidate(stockRawProvider);
  ref.invalidate(productsProvider);
  ref.invalidate(productProvider);
}

final shopProvider = FutureProvider<ShopOverview>((ref) {
  ref.watch(scopeProvider);
  return ref.watch(repoProvider).shop();
});

final shopOrdersProvider = FutureProvider.family<List<ShopOrder>, ShopOrderFilter>((ref, filter) {
  ref.watch(scopeProvider);
  return ref.watch(repoProvider).shopOrders(filter: filter);
});

final shopOrderProvider = FutureProvider.family<ShopOrder, String>((ref, id) {
  ref.watch(scopeProvider);
  return ref.watch(repoProvider).shopOrder(id);
});

void refreshShop(WidgetRef ref) {
  ref.invalidate(shopProvider);
  ref.invalidate(shopOrdersProvider);
  ref.invalidate(shopOrderProvider);
}

final loyaltySettingsProvider = FutureProvider<LoyaltySettings>((ref) async {
  ref.watch(scopeProvider);
  try {
    return await ref.watch(repoProvider).loyaltySettings();
  } catch (_) {
    return const LoyaltySettings(); // hors ligne ou sans droit : programme considéré désactivé
  }
});

final loyaltyDashboardProvider = FutureProvider<LoyaltyDashboard>((ref) {
  ref.watch(scopeProvider);
  return ref.watch(repoProvider).loyaltyDashboard();
});

final loyaltyCardProvider = FutureProvider.family<LoyaltyCard, String>((ref, customerId) {
  ref.watch(scopeProvider);
  return ref.watch(repoProvider).loyaltyCard(customerId);
});

void refreshLoyalty(WidgetRef ref) {
  ref.invalidate(loyaltySettingsProvider);
  ref.invalidate(loyaltyDashboardProvider);
  ref.invalidate(loyaltyCardProvider);
}

final remindersProvider = FutureProvider<ReminderQueue>((ref) {
  ref.watch(scopeProvider);
  return ref.watch(repoProvider).reminders();
});

final notificationsProvider = FutureProvider<NotificationsPage>((ref) {
  ref.watch(scopeProvider);
  return ref.watch(repoProvider).notifications();
});

/// Nombre de notifications non lues ; 0 en cas d'erreur (hors connexion) pour ne jamais bloquer l'accueil.
final unreadNotificationsProvider = FutureProvider<int>((ref) async {
  ref.watch(scopeProvider);
  try {
    return await ref.watch(repoProvider).unreadNotifications();
  } catch (_) {
    return 0;
  }
});

void refreshNotifications(WidgetRef ref) {
  ref.invalidate(notificationsProvider);
  ref.invalidate(unreadNotificationsProvider);
}

final cashCurrentProvider = FutureProvider<CashSession?>((ref) {
  ref.watch(scopeProvider);
  return ref.watch(repoProvider).cashCurrent();
});

final cashSessionsProvider = FutureProvider<List<CashSessionSummary>>((ref) {
  ref.watch(scopeProvider);
  return ref.watch(repoProvider).cashSessions();
});

final cashSessionProvider = FutureProvider.family<CashSession, String>((ref, id) {
  ref.watch(scopeProvider);
  return ref.watch(repoProvider).cashSession(id);
});

void refreshCash(WidgetRef ref) {
  ref.invalidate(cashCurrentProvider);
  ref.invalidate(cashSessionsProvider);
  ref.invalidate(cashSessionProvider);
}

final saleProvider = FutureProvider.family<SaleDetail, String>((ref, id) {
  ref.watch(scopeProvider);
  return ref.watch(repoProvider).sale(id);
});

/// Ventes du jour : toutes pour qui voit les rapports, sinon seulement les miennes.
final salesTodayProvider = FutureProvider<List<SaleSummary>>((ref) async {
  ref.watch(scopeProvider);
  final b = await ref.watch(currentBusinessProvider.future);
  return ref.watch(repoProvider).salesOfDay(null, !hasPermission(b.permissions, 'reports:read'));
});

/// Demandes d'annulation des vendeurs, en attente (gérant seulement ; vide sinon).
final pendingVoidsProvider = FutureProvider<List<SaleSummary>>((ref) async {
  ref.watch(scopeProvider);
  final b = await ref.watch(currentBusinessProvider.future);
  if (!hasPermission(b.permissions, 'sales:void')) return const [];
  return ref.watch(repoProvider).salesPendingVoid();
});

final myDayProvider = FutureProvider<MyDay>((ref) {
  ref.watch(scopeProvider);
  return ref.watch(repoProvider).myDay();
});

final membersProvider = FutureProvider<List<Member>>((ref) {
  ref.watch(scopeProvider);
  return ref.watch(repoProvider).members();
});

/// Rapport d'une période (dates sans heure).
/// Analyses sur les N derniers jours (7, 30, 90).
final insightsProvider = FutureProvider.family<Insights, int>((ref, days) {
  ref.watch(scopeProvider);
  return ref.watch(repoProvider).insights(days);
});

/// Rapport de la semaine : null = semaine complète précédente, sinon un jour de la semaine voulue.
final weeklyReportProvider = FutureProvider.family<WeeklyReport, DateTime?>((ref, week) {
  ref.watch(scopeProvider);
  return ref.watch(repoProvider).weeklyReport(week);
});

final reportProvider = FutureProvider.family<ReportOverview, ({DateTime from, DateTime to})>((ref, p) {
  ref.watch(scopeProvider);
  return ref.watch(repoProvider).report(p.from, p.to);
});

final productProvider = FutureProvider.family<Product, String>((ref, id) {
  ref.watch(scopeProvider);
  return ref.watch(repoProvider).product(id);
});

final invoicingSummaryProvider = FutureProvider<InvoicingSummary>((ref) {
  ref.watch(scopeProvider);
  return ref.watch(repoProvider).invoicingSummary();
});

/// Liste par type et filtre : (type, statut(s), en retard).
final documentsProvider = FutureProvider.family<List<DocSummary>, ({DocKind kind, String? status, bool overdue})>((
  ref,
  f,
) {
  ref.watch(scopeProvider);
  return ref.watch(repoProvider).documents(kind: f.kind, status: f.status, overdue: f.overdue);
});

final documentProvider = FutureProvider.family<DocDetail, String>((ref, id) {
  ref.watch(scopeProvider);
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
  ref.invalidate(customerListProvider);
  ref.invalidate(customerOverviewProvider);
  ref.invalidate(salesTodayProvider);
  ref.invalidate(pendingVoidsProvider);
  ref.invalidate(myDayProvider);
  ref.invalidate(cashCurrentProvider);
  ref.invalidate(unreadNotificationsProvider);
  ref.invalidate(remindersProvider);
  ref.invalidate(loyaltyDashboardProvider);
  ref.invalidate(loyaltyCardProvider);
  // Rapports et analyses : une vente, une dépense ou un achat les change
  ref.invalidate(reportProvider);
  ref.invalidate(insightsProvider);
  ref.invalidate(weeklyReportProvider);
}

/// Message lisible pour l'utilisateur à partir de n'importe quelle erreur.
String errorMessage(Object error) {
  if (error is ApiException) return error.message;
  return 'Une erreur est survenue. Réessayez.';
}

/// Vente bloquée : le patron oblige à ouvrir la caisse et la caisse de ce vendeur est fermée.
/// (Hors ligne ou état inconnu : on ne bloque pas, la vente partira plus tard.)
final mustOpenCashProvider = Provider<bool>((ref) {
  final required = ref.watch(currentBusinessProvider).value?.requireOpenCash ?? false;
  if (!required) return false;
  return ref.watch(cashCurrentProvider).maybeWhen(data: (s) => s == null, orElse: () => false);
});

/// Documents de la boutique (filtre par catégorie et recherche).
final storedDocumentsProvider = FutureProvider.family<DocumentList, ({DocCategory? category, String search})>((ref, q) {
  ref.watch(scopeProvider);
  return ref.watch(repoProvider).storedDocuments(category: q.category, search: q.search);
});

final storedDocumentProvider = FutureProvider.family<BusinessDocument, String>((ref, id) {
  ref.watch(scopeProvider);
  return ref.watch(repoProvider).storedDocument(id);
});

/// Octets d'un document, gardés en mémoire le temps de l'écran.
final storedDocumentBytesProvider = FutureProvider.autoDispose.family<List<int>, String>((ref, id) {
  return ref.watch(repoProvider).storedDocumentBytes(id);
});

void refreshStoredDocuments(WidgetRef ref) {
  ref.invalidate(storedDocumentsProvider);
  ref.invalidate(storedDocumentProvider);
}

final assistantStatusProvider = FutureProvider<AssistantStatus>((ref) {
  ref.watch(scopeProvider);
  return ref.watch(repoProvider).assistantStatus();
});

class AssistantChatState {
  const AssistantChatState({this.messages = const [], this.busy = false, this.remaining});
  final List<ChatMessage> messages;
  final bool busy;
  final int? remaining;
}

/// Conversation avec l'assistant : gardée le temps de la session, jamais sur le serveur.
class AssistantChat extends Notifier<AssistantChatState> {
  @override
  AssistantChatState build() {
    ref.watch(scopeProvider);
    return const AssistantChatState();
  }

  Future<void> ask(String question) async {
    final q = question.trim();
    if (q.isEmpty || state.busy) return;
    final history = [...state.messages.where((m) => !m.failed), ChatMessage(fromUser: true, text: q)];
    state = AssistantChatState(messages: history, busy: true, remaining: state.remaining);
    try {
      final r = await ref.read(repoProvider).askAssistant(history);
      state = AssistantChatState(
        messages: [
          ...history,
          ChatMessage(fromUser: false, text: r.reply),
        ],
        remaining: r.remaining,
      );
    } catch (e) {
      final why = e is ApiException && !e.isNetwork
          ? e.message
          : 'Connexion impossible. Vérifiez internet et réessayez.';
      state = AssistantChatState(
        messages: [
          ...history.take(history.length - 1),
          ChatMessage(fromUser: true, text: q, failed: true),
        ],
        remaining: state.remaining,
      );
      throw ApiException('ASSISTANT', why, status: e is ApiException ? e.status : null);
    }
  }

  void reset() => state = AssistantChatState(remaining: state.remaining);
}

final assistantChatProvider = NotifierProvider<AssistantChat, AssistantChatState>(AssistantChat.new);

/// Rendez-vous d'un jour (avec le nombre de rendez-vous des jours voisins).
final appointmentsProvider = FutureProvider.family<AppointmentList, DateTime>((ref, day) {
  ref.watch(scopeProvider);
  return ref.watch(repoProvider).appointments(day);
});

final bookingSettingsProvider = FutureProvider<BookingSettings>((ref) {
  ref.watch(scopeProvider);
  return ref.watch(repoProvider).bookingSettings();
});

/// Premiers pas (patron seulement : le guide parle de réglages de la boutique).
final onboardingProvider = FutureProvider<Onboarding?>((ref) async {
  ref.watch(scopeProvider);
  if (!ref.watch(canProvider('business:update'))) return null;
  return ref.watch(repoProvider).onboarding();
});

final couriersProvider = FutureProvider<List<Courier>>((ref) {
  ref.watch(scopeProvider);
  return ref.watch(repoProvider).couriers();
});

/// Livraisons en cours (false) ou terminées (true).
final deliveryBoardProvider = FutureProvider.family<DeliveryBoard, bool>((ref, done) {
  ref.watch(scopeProvider);
  return ref.watch(repoProvider).deliveryBoard(done: done);
});

void refreshDeliveries(WidgetRef ref) {
  ref.invalidate(deliveryBoardProvider);
  ref.invalidate(couriersProvider);
}

/// Nouvel essai automatique d'un chargement raté : seulement pour le réseau ou une panne du serveur.
/// Un refus de l'API (Pro requis, droit manquant, introuvable…) ne changera pas en réessayant.
Duration? samaRetry(int retryCount, Object error) {
  if (error is ApiException && error.code != ApiException.network && (error.status ?? 400) < 500) return null;
  if (retryCount >= 5) return null;
  return Duration(milliseconds: 200 * (1 << retryCount));
}
