import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../models.dart';
import '../providers.dart';
import '../repositories.dart';
import 'kv_store.dart';

/// Vente faite sans réseau, gardée sur le téléphone jusqu'à son envoi.
class PendingSale {
  const PendingSale({
    required this.id,
    required this.businessId,
    required this.soldAt,
    required this.body,
    required this.total,
    required this.lines,
    this.customerName,
    this.failed = false,
    this.error,
  });

  final String id;
  final String businessId;
  final DateTime soldAt;

  /// Corps prêt pour POST /v1/sales (même identifiant à chaque envoi : pas de doublon).
  final Map<String, dynamic> body;
  final int total;

  /// Lignes, pour l'affichage et le stock du téléphone.
  final List<({String productId, String name, double quantity})> lines;
  final String? customerName;

  /// Refusée par le serveur (ex. produit supprimé) : à vérifier par le commerçant.
  final bool failed;
  final String? error;

  double get itemCount => lines.fold(0, (s, l) => s + l.quantity);

  PendingSale copyWith({bool? failed, String? error}) => PendingSale(
    id: id,
    businessId: businessId,
    soldAt: soldAt,
    body: body,
    total: total,
    lines: lines,
    customerName: customerName,
    failed: failed ?? this.failed,
    error: error,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'businessId': businessId,
    'soldAt': soldAt.toUtc().toIso8601String(),
    'body': body,
    'total': total,
    'lines': [
      for (final l in lines) {'productId': l.productId, 'name': l.name, 'quantity': l.quantity},
    ],
    'customerName': customerName,
    'failed': failed,
    'error': error,
  };

  factory PendingSale.fromJson(Map<String, dynamic> j) => PendingSale(
    id: j['id'] as String,
    businessId: j['businessId'] as String,
    soldAt: DateTime.parse(j['soldAt'] as String),
    body: Map<String, dynamic>.from(j['body'] as Map),
    total: (j['total'] as num).toInt(),
    lines: [
      for (final l in (j['lines'] as List).cast<Map>())
        (productId: l['productId'] as String, name: l['name'] as String, quantity: (l['quantity'] as num).toDouble()),
    ],
    customerName: j['customerName'] as String?,
    failed: j['failed'] as bool? ?? false,
    error: j['error'] as String?,
  );
}

/// Résultat d'un encaissement : envoyé au serveur, ou gardé sur le téléphone.
sealed class CheckoutOutcome {
  const CheckoutOutcome();
}

class SaleSent extends CheckoutOutcome {
  const SaleSent(this.sale);
  final SaleResult sale;
}

class SaleQueued extends CheckoutOutcome {
  const SaleQueued(this.pending);
  final PendingSale pending;
}

/// Bilan d'une synchronisation.
class SyncReport {
  const SyncReport({this.sent = 0, this.failed = 0, this.offline = false});
  final int sent;
  final int failed;
  final bool offline;
}

/// Remplacé dans main() par le stockage du téléphone ; en mémoire dans les tests.
final keyValueStoreProvider = Provider<KeyValueStore>((ref) => MemoryStore());

/// Vrai tant que le serveur répond (mis à jour à chaque requête).
final onlineProvider = NotifierProvider<OnlineNotifier, bool>(OnlineNotifier.new);

class OnlineNotifier extends Notifier<bool> {
  @override
  bool build() {
    final online = ref.watch(apiClientProvider).online;
    void listener() => state = online.value;
    online.addListener(listener);
    ref.onDispose(() => online.removeListener(listener));
    return online.value;
  }
}

/// Ventes en attente d'envoi (toutes entreprises), dans l'ordre où elles ont été faites.
final pendingSalesProvider = NotifierProvider<PendingSalesController, List<PendingSale>>(PendingSalesController.new);

class PendingSalesController extends Notifier<List<PendingSale>> {
  static const storageKey = 'offline:pending_sales:v1';

  KeyValueStore get _store => ref.read(keyValueStoreProvider);
  bool _syncing = false;

  @override
  List<PendingSale> build() {
    final raw = _store.getString(storageKey);
    if (raw == null) return const [];
    try {
      return [for (final e in jsonDecode(raw) as List) PendingSale.fromJson(e as Map<String, dynamic>)];
    } catch (_) {
      return const []; // donnée illisible : on ne bloque pas la caisse
    }
  }

  Future<void> _save(List<PendingSale> list) async {
    state = list;
    await _store.setString(storageKey, jsonEncode([for (final p in list) p.toJson()]));
  }

  bool get isSyncing => _syncing;

  /// Encaisse : envoi direct si le réseau répond, sinon la vente est gardée sur le téléphone.
  /// Une erreur métier (crédit sans client, produit supprimé…) est remontée telle quelle.
  Future<CheckoutOutcome> checkout({
    required String id,
    required String businessId,
    required List<({Product product, double quantity})> lines,
    required List<({PayMethod method, int amount})> payments,
    required int total,
    Contact? customer,
    DateTime? now,
  }) async {
    final soldAt = now ?? DateTime.now();
    final body = SamaRepository.saleBody(
      id: id,
      customerId: customer?.id,
      items: [for (final l in lines) (productId: l.product.id, quantity: l.quantity)],
      payments: payments,
      soldAt: soldAt,
    );
    try {
      final sale = await ref.read(repoProvider).postSale(body, businessId: businessId);
      unawaited(sync()); // d'éventuelles ventes plus anciennes partent aussi
      return SaleSent(sale);
    } on ApiException catch (e) {
      if (!e.isNetwork) rethrow;
      final pending = PendingSale(
        id: id,
        businessId: businessId,
        soldAt: soldAt,
        body: body,
        total: total,
        customerName: customer?.name,
        lines: [for (final l in lines) (productId: l.product.id, name: l.product.name, quantity: l.quantity)],
      );
      await _save([...state.where((p) => p.id != id), pending]);
      return SaleQueued(pending);
    }
  }

  /// Envoie les ventes en attente, dans l'ordre. S'arrête au premier problème de réseau.
  Future<SyncReport> sync() async {
    if (_syncing) return const SyncReport();
    final queue = state.where((p) => !p.failed).toList();
    if (queue.isEmpty) return const SyncReport();
    _syncing = true;
    var sent = 0;
    var failed = 0;
    var offline = false;
    try {
      final repo = ref.read(repoProvider);
      for (final p in queue) {
        try {
          await repo.postSale(p.body, businessId: p.businessId);
          sent++;
          await _save(state.where((x) => x.id != p.id).toList());
        } on ApiException catch (e) {
          if (e.isNetwork || (e.status ?? 0) >= 500 || e.status == 401 || e.status == 429) {
            // Réseau, serveur indisponible, session à renouveler : on réessaiera plus tard.
            offline = e.isNetwork;
            break;
          }
          if (e.status == 409) {
            // Envoi simultané de la même vente : elle existe déjà sur le serveur.
            sent++;
            await _save(state.where((x) => x.id != p.id).toList());
            continue;
          }
          failed++;
          await _save([for (final x in state) x.id == p.id ? x.copyWith(failed: true, error: e.message) : x]);
        }
      }
    } finally {
      _syncing = false;
    }
    if (sent > 0) _refreshAfterSync();
    return SyncReport(sent: sent, failed: failed, offline: offline);
  }

  /// Remet une vente refusée dans la file (après correction côté serveur, ou nouvel essai).
  Future<void> retry(String id) async {
    await _save([for (final x in state) x.id == id ? x.copyWith(failed: false) : x]);
    await sync();
  }

  /// Abandonne une vente en attente (elle ne sera jamais envoyée).
  Future<void> discard(String id) => _save(state.where((x) => x.id != id).toList());

  /// Déconnexion : vide la file.
  Future<void> clear() => _save(const []);

  void _refreshAfterSync() {
    ref.invalidate(summaryProvider);
    ref.invalidate(stockRawProvider);
    ref.invalidate(productsProvider);
    ref.invalidate(debtorsProvider);
    ref.invalidate(ledgerProvider);
    ref.invalidate(salesTodayProvider);
  }
}

/// Ventes en attente de l'entreprise courante (pas celles refusées).
final pendingForBusinessProvider = Provider<List<PendingSale>>((ref) {
  final id = ref.watch(businessIdProvider);
  return ref.watch(pendingSalesProvider).where((p) => p.businessId == id).toList();
});

/// Stock affiché sur le téléphone : stock du serveur moins les ventes pas encore envoyées.
StockOverview stockNetOfPending(StockOverview s, List<PendingSale> pending) {
  final out = <String, double>{};
  for (final p in pending.where((p) => !p.failed)) {
    for (final l in p.lines) {
      out[l.productId] = (out[l.productId] ?? 0) + l.quantity;
    }
  }
  if (out.isEmpty) return s;
  final items = [
    for (final i in s.items)
      if (out[i.productId] == null)
        i
      else
        i.copyWith(onHand: i.onHand - out[i.productId]!, low: i.onHand - out[i.productId]! <= i.threshold),
  ];
  return StockOverview(items: items, lowStock: items.where((i) => i.low).length, stockValue: s.stockValue);
}
