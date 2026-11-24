import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart' show Options, ResponseType;
import 'package:intl/intl.dart' show DateFormat;

import 'admin_models.dart';
import 'api/api_client.dart';
import 'push.dart' show PushWebConfig;
import 'models.dart';
import 'offline/kv_store.dart';

/// Toutes les routes de l'API utilisées par l'app, regroupées et typées.
///
/// Hors ligne : les lectures principales gardent leur dernière réponse dans [cache]
/// et la renvoient quand le serveur est injoignable (l'app reste utilisable au marché).
class SamaRepository {
  SamaRepository(this.api, {KeyValueStore? cache}) : cache = cache ?? MemoryStore();
  final ApiClient api;
  final KeyValueStore cache;

  static const cachePrefix = 'cache:v1:';

  /// Clé de cache : par entreprise (ou par utilisateur), chemin et paramètres triés.
  String cacheKey(String path, {Map<String, dynamic>? query, bool user = false}) {
    final q = (query?.entries.where((e) => e.value != null).toList() ?? [])..sort((a, b) => a.key.compareTo(b.key));
    final qs = q.map((e) => '${e.key}=${e.value}').join('&');
    // Le point de vente choisi change les chiffres : il fait partie de la clé
    final scope = user ? 'user' : '${api.businessId ?? '-'}${api.locationId == null ? '' : '@${api.locationId}'}';
    return '$cachePrefix$scope:$path${qs.isEmpty ? '' : '?$qs'}';
  }

  /// Lecture avec repli sur la dernière réponse connue si le réseau manque.
  Future<T> _cachedGet<T>(String path, {Map<String, dynamic>? query, bool user = false}) async {
    final key = cacheKey(path, query: query, user: user);
    try {
      final data = await api.get<T>(path, query: query);
      unawaited(cache.setString(key, jsonEncode(data)));
      return data;
    } on ApiException catch (e) {
      if (!e.isNetwork) rethrow;
      final saved = _fromCache<T>(path, query: query, user: user);
      if (saved == null) rethrow;
      return saved;
    }
  }

  T? _fromCache<T>(String path, {Map<String, dynamic>? query, bool user = false}) {
    final saved = cache.getString(cacheKey(path, query: query, user: user));
    return saved == null ? null : jsonDecode(saved) as T;
  }

  /// Efface les données gardées pour le hors ligne (déconnexion).
  Future<void> clearCache() => cache.removePrefix(cachePrefix);

  // ---------- Authentification ----------
  /// Moyens de recevoir le code (le premier par défaut). Serveur ancien ou injoignable : SMS.
  Future<List<OtpChannel>> otpChannels() async {
    try {
      final r = await api.get<Map<String, dynamic>>('/v1/auth/otp/channels');
      final list = [for (final c in (r['channels'] as List? ?? const [])) ?OtpChannel.fromApi(c as String)];
      return list.isEmpty ? const [OtpChannel.sms] : list;
    } catch (_) {
      return const [OtpChannel.sms];
    }
  }

  Future<OtpTarget> requestOtp(String phone, {OtpChannel? channel}) async {
    final r = await api.post<Map<String, dynamic>>(
      '/v1/auth/otp/request',
      data: {'phone': phone, 'channel': ?channel?.name},
      public: true,
    );
    return OtpTarget(
      r['phone'] as String,
      channel: OtpChannel.fromApi(r['channel'] as String?) ?? channel ?? OtpChannel.sms,
    );
  }

  /// [restored] : compte supprimé il y a moins de 30 jours, rétabli par cette connexion.
  Future<({String access, String refresh, bool restored})> verifyOtp(
    String phone,
    String code, {
    String? deviceId,
  }) async {
    final r = await api.post<Map<String, dynamic>>(
      '/v1/auth/otp/verify',
      data: {'phone': phone, 'code': code, 'deviceId': ?deviceId},
      public: true,
    );
    return (access: r['accessToken'] as String, refresh: r['refreshToken'] as String, restored: r['restored'] == true);
  }

  // ---------- Notifications push ----------

  /// Configuration de la version web (null : notifications web pas encore configurées).
  Future<PushWebConfig?> pushWebConfig() async {
    final r = await api.get<Map<String, dynamic>>('/v1/push/config');
    return PushWebConfig.fromJson(r['web'] as Map<String, dynamic>?);
  }

  Future<void> registerPushToken(String token, String platform) =>
      api.post<void>('/v1/me/push-tokens', data: {'token': token, 'platform': platform});

  Future<void> unregisterPushToken(String token) => api.delete<void>('/v1/me/push-tokens', data: {'token': token});

  // ---------- Suppression (30 jours pour changer d'avis) ----------

  /// Propriétaire : supprime la boutique courante ; [confirmName] = son nom retapé.
  Future<void> deleteBusiness(String confirmName) =>
      api.delete<void>('/v1/business', data: {'confirmName': confirmName});

  Future<List<DeletedBusiness>> deletedBusinesses() async => [
    for (final b in await api.get<List<dynamic>>('/v1/businesses/deleted'))
      DeletedBusiness.fromJson(b as Map<String, dynamic>),
  ];

  Future<void> restoreBusiness(String id) => api.post<void>('/v1/businesses/$id/restore');

  /// Supprime le compte ([confirm] = « SUPPRIMER ») et ses boutiques.
  Future<void> deleteAccount(String confirm) => api.delete<void>('/v1/me', data: {'confirm': confirm});

  Future<void> logout(String refreshToken) =>
      api.post<void>('/v1/auth/logout', data: {'refreshToken': refreshToken}, public: true);

  Future<Me> me() async => Me.fromJson(await _cachedGet<Map<String, dynamic>>('/v1/me', user: true));

  /// Couleur de la boutique (« #0A7E4F ») ; null pour revenir au vert Sama360.
  Future<void> updateRequireOpenCash(bool value) => api.patch<void>('/v1/business', data: {'requireOpenCash': value});

  // ── Sama360 Pro et parrainage

  Future<ProStatus> subscription() async => ProStatus.fromJson(await api.get<Map<String, dynamic>>('/v1/subscription'));

  /// « J'ai payé » : référence de la transaction Wave / Orange Money / MoMo.
  Future<PaymentRequest> requestProPayment({
    required String cycle,
    required PayMethod method,
    required String reference,
    String? payerPhone,
  }) async => PaymentRequest.fromJson(
    await api.post<Map<String, dynamic>>(
      '/v1/subscription/requests',
      data: {'cycle': cycle, 'method': method.api, 'reference': reference, 'payerPhone': ?payerPhone},
    ),
  );

  /// Paiement en ligne (Chariow) : adresse de la page de paiement.
  Future<OnlinePayment> startProCheckout({required String cycle, required String email}) async {
    final j = await api.post<Map<String, dynamic>>('/v1/subscription/checkout', data: {'cycle': cycle, 'email': email});
    return OnlinePayment(id: j['paymentId'] as String, checkoutUrl: j['checkoutUrl'] as String?);
  }

  Future<OnlinePayment> onlinePayment(String id) async {
    final j = await api.get<Map<String, dynamic>>('/v1/subscription/online/$id');
    return OnlinePayment(id: j['id'] as String, status: j['status'] as String? ?? 'pending');
  }

  Future<ReferralInfo> referrals() async => ReferralInfo.fromJson(await api.get<Map<String, dynamic>>('/v1/referrals'));

  /// Équipe Sama360 : validation des paiements Pro.
  Future<bool> isPlatformAdmin() async => (await api.get<Map<String, dynamic>>('/v1/admin/me'))['admin'] == true;

  Future<List<PaymentRequest>> adminPaymentRequests({String status = 'pending'}) async => [
    for (final r in await api.get<List<dynamic>>('/v1/admin/subscription-requests', query: {'status': status}))
      PaymentRequest.fromJson(r as Map<String, dynamic>),
  ];

  Future<void> approvePayment(String id) => api.post<void>('/v1/admin/subscription-requests/$id/approve');

  Future<void> rejectPayment(String id, String? note) =>
      api.post<void>('/v1/admin/subscription-requests/$id/reject', data: {'note': ?note});

  // ───────────── back office de l'équipe Sama360

  Future<AdminOverview> adminOverview({int days = 30}) async =>
      AdminOverview.fromJson(await api.get<Map<String, dynamic>>('/v1/admin/overview', query: {'days': days}));

  Future<AdminPage<AdminBusiness>> adminBusinesses(AdminBusinessQuery q) async {
    final j = await api.get<Map<String, dynamic>>('/v1/admin/businesses', query: q.toQuery());
    return AdminPage(
      items: [for (final b in j['items'] as List) AdminBusiness.fromJson(b as Map<String, dynamic>)],
      total: (j['total'] as num).toInt(),
      page: (j['page'] as num).toInt(),
      pageSize: (j['pageSize'] as num).toInt(),
    );
  }

  Future<AdminBusinessDetail> adminBusiness(String id) async =>
      AdminBusinessDetail.fromJson(await api.get<Map<String, dynamic>>('/v1/admin/businesses/$id'));

  Future<void> adminGift(String id, int days, String? reason) =>
      api.post<void>('/v1/admin/businesses/$id/gift', data: {'days': days, 'reason': ?reason});

  Future<void> adminSuspend(String id, String reason) =>
      api.post<void>('/v1/admin/businesses/$id/suspend', data: {'reason': reason});

  Future<void> adminUnsuspend(String id) => api.post<void>('/v1/admin/businesses/$id/unsuspend');

  Future<void> adminRestore(String id) => api.post<void>('/v1/admin/businesses/$id/restore');

  Future<({List<AdminPayment> items, bool hasMore})> adminPayments({
    AdminPayStatus? status,
    bool? online,
    int page = 1,
  }) async {
    final j = await api.get<Map<String, dynamic>>(
      '/v1/admin/payments',
      query: {
        'status': ?status?.api,
        'source': ?(online == null ? null : (online ? 'online' : 'manual')),
        'page': page,
      },
    );
    return (
      items: [for (final p in j['items'] as List) AdminPayment.fromJson(p as Map<String, dynamic>)],
      hasMore: j['hasMore'] == true,
    );
  }

  Future<void> updateCountry(String code) => api.patch<void>('/v1/business', data: {'country': code});

  /// Numéros et liens de paiement mobile (remplace l'ensemble ; vides = retirés).
  Future<void> updatePayAccounts(Map<PayMethod, PayAccount> accounts) => api.patch<void>(
    '/v1/business',
    data: {
      'payAccounts': {for (final e in accounts.entries) e.key.api: e.value.toJson()},
    },
  );

  Future<void> updateBrandColor(String? hex) => api.patch<void>('/v1/business', data: {'brandColor': hex});

  Future<void> updateName(String fullName) => api.patch<void>('/v1/me', data: {'fullName': fullName});

  /// Nom et e-mail (e-mail vide = retiré).
  Future<void> updateProfile({required String fullName, String? email}) =>
      api.patch<void>('/v1/me', data: {'fullName': fullName, 'email': (email ?? '').isEmpty ? null : email});

  Future<void> uploadAvatar(List<int> bytes, {String filename = 'photo.jpg'}) =>
      api.upload<void>('/v1/me/avatar', bytes, filename: filename);

  Future<void> deleteAvatar() => api.delete<void>('/v1/me/avatar');

  /// Ferme les sessions sur tous les appareils.
  Future<void> logoutAll() => api.post<void>('/v1/me/logout-all');

  // ---------- Entreprises ----------
  Future<String> createBusiness({
    required String name,
    String? category,
    String? city,
    String? focus,
    String? country,
    String? referralCode,
  }) async {
    final r = await api.post<Map<String, dynamic>>(
      '/v1/businesses',
      data: {
        'name': name,
        'category': ?category,
        'city': ?city,
        'focus': ?focus,
        'country': ?country,
        'referralCode': ?referralCode,
      },
    );
    return (r['business'] as Map)['id'] as String;
  }

  /// Premiers pas : activité, guide masqué, étapes faites (d'après les données de la boutique).
  Future<Onboarding> onboarding() async =>
      Onboarding.fromJson(await api.get<Map<String, dynamic>>('/v1/business/onboarding'));

  /// Activité de la boutique : « products », « services » ou « both ».
  Future<void> setFocus(String focus) => api.patch<void>('/v1/business', data: {'focus': focus});

  Future<void> dismissOnboarding() => api.patch<void>('/v1/business', data: {'onboardingDismissed': true});

  Future<CurrentBusiness> currentBusiness() async =>
      CurrentBusiness.fromJson(await _cachedGet<Map<String, dynamic>>('/v1/business'));

  /// Variantes d'un produit (taille, couleur…) : renvoie les variantes à jour.
  Future<List<Product>> setVariants(String productId, List<VariantAxis> axes, List<VariantDraft> variants) async {
    final r = await api.put<Map<String, dynamic>>(
      '/v1/catalog/products/$productId/variants',
      data: {
        'axes': [for (final a in axes) a.toJson()],
        'variants': [for (final v in variants) v.toJson()],
      },
    );
    return [for (final v in (r['variants'] as List)) Product.fromJson(v as Map<String, dynamic>)];
  }

  /// Logo de l'entreprise (factures, devis, reçus).
  Future<void> uploadBusinessLogo(List<int> bytes, {String filename = 'logo.png'}) =>
      api.upload<void>('/v1/business/logo', bytes, filename: filename);

  Future<void> deleteBusinessLogo() => api.delete<void>('/v1/business/logo');

  final _fileCache = <String, List<int>>{};

  /// Octets d'un fichier public (logo pour les PDF), gardés en mémoire.
  Future<List<int>?> fileBytes(String fileId) async {
    final hit = _fileCache[fileId];
    if (hit != null) return hit;
    try {
      final r = await api.dio.get<List<int>>(
        '/v1/files/$fileId',
        options: Options(responseType: ResponseType.bytes, extra: {'public': true}),
      );
      return _fileCache[fileId] = r.data!;
    } catch (_) {
      return null; // hors ligne : document sans logo
    }
  }

  // ---------- Catalogue ----------
  Future<List<Category>> categories() async => (await _cachedGet<List<dynamic>>(
    '/v1/catalog/categories',
  )).map((e) => Category.fromJson(e as Map<String, dynamic>)).toList();

  Future<List<Product>> products({String? search, String? categoryId}) async {
    const path = '/v1/catalog/products';
    const all = {'limit': 100};
    List<Product> parse(Map<String, dynamic> r) =>
        (r['data'] as List).map((e) => Product.fromJson(e as Map<String, dynamic>)).toList();
    if (search == null && categoryId == null) return parse(await _cachedGet<Map<String, dynamic>>(path, query: all));
    try {
      return parse(
        await api.get<Map<String, dynamic>>(path, query: {...all, 'search': search, 'categoryId': categoryId}),
      );
    } on ApiException catch (e) {
      // Hors ligne : recherche dans le dernier catalogue connu
      final saved = e.isNetwork ? _fromCache<Map<String, dynamic>>(path, query: all) : null;
      if (saved == null) rethrow;
      final q = search?.toLowerCase();
      return parse(saved)
          .where(
            (p) =>
                (categoryId == null || p.categoryId == categoryId) && (q == null || p.name.toLowerCase().contains(q)),
          )
          .toList();
    }
  }

  Future<Product> createProduct({
    required String name,
    required int price,
    int cost = 0,
    String? categoryId,
    int lowStockThreshold = 5,
  }) async => Product.fromJson(
    await api.post<Map<String, dynamic>>(
      '/v1/catalog/products',
      data: {
        'name': name,
        'price': price,
        'cost': cost,
        'categoryId': ?categoryId,
        'lowStockThreshold': lowStockThreshold,
      },
    ),
  );

  /// Envoie (ou remplace) la photo d'un produit.
  Future<Product> uploadProductImage(String productId, List<int> bytes, {String filename = 'photo.jpg'}) async =>
      Product.fromJson(
        await api.upload<Map<String, dynamic>>('/v1/catalog/products/$productId/image', bytes, filename: filename),
      );

  Future<Product> product(String id) async =>
      Product.fromJson(await _cachedGet<Map<String, dynamic>>('/v1/catalog/products/$id'));

  /// Produit par code-barres ou référence (scan) ; null si inconnu.
  Future<Product?> productByCode(String code) async {
    try {
      return Product.fromJson(
        await api.get<Map<String, dynamic>>('/v1/catalog/products/by-code/${Uri.encodeComponent(code)}'),
      );
    } on ApiException catch (e) {
      if (e.status == 404) return null;
      if (!e.isNetwork) rethrow;
      // Hors ligne : recherche dans le dernier catalogue connu
      final saved = _fromCache<Map<String, dynamic>>('/v1/catalog/products', query: {'limit': 100});
      if (saved == null) rethrow;
      return (saved['data'] as List)
          .map((e) => Product.fromJson(e as Map<String, dynamic>))
          .where((p) => p.barcode == code || p.sku == code)
          .firstOrNull;
    }
  }

  Future<Product> saveProduct(ProductDraft d, {String? id}) async => Product.fromJson(
    id == null
        ? await api.post<Map<String, dynamic>>('/v1/catalog/products', data: d.toJson())
        : await api.patch<Map<String, dynamic>>('/v1/catalog/products/$id', data: d.toJson()),
  );

  Future<void> deleteProduct(String id) => api.delete<void>('/v1/catalog/products/$id');

  Future<Category> createCategory(String name) async =>
      Category.fromJson(await api.post<Map<String, dynamic>>('/v1/catalog/categories', data: {'name': name.trim()}));

  Future<void> renameCategory(String id, String name) =>
      api.patch<void>('/v1/catalog/categories/$id', data: {'name': name.trim()});

  Future<void> deleteCategory(String id) => api.delete<void>('/v1/catalog/categories/$id');

  Future<void> deleteProductImage(String productId) => api.delete<void>('/v1/catalog/products/$productId/image');

  /// Adresse publique d'un fichier (photo de produit).
  String fileUrl(String fileId) => '${api.dio.options.baseUrl}/v1/files/$fileId';

  // ---------- Stock ----------
  Future<StockOverview> stock({bool lowOnly = false}) async => StockOverview.fromJson(
    await _cachedGet<Map<String, dynamic>>('/v1/inventory/stock', query: {'lowOnly': lowOnly ? 'true' : null}),
  );

  Future<void> addStock(String productId, double quantity, {int? unitCost}) => api.post<void>(
    '/v1/inventory/movements',
    data: {'productId': productId, 'type': 'purchase', 'quantity': quantity, 'unitCost': ?unitCost},
  );

  // ---------- Ventes ----------
  /// Corps de POST /v1/sales. L'identifiant vient du téléphone : renvoyer la même vente
  /// (hors ligne, réseau coupé pendant la réponse) ne crée jamais de doublon.
  static Map<String, dynamic> saleBody({
    required String id,
    String? customerId,
    required List<({String productId, double quantity})> items,
    required List<({PayMethod method, int amount})> payments,
    DateTime? soldAt,
    int redeemRewards = 0,
  }) => {
    'id': id,
    'customerId': ?customerId,
    'items': [
      for (final i in items) {'productId': i.productId, 'quantity': i.quantity},
    ],
    'payments': [
      for (final p in payments) {'method': p.method.api, 'amount': p.amount},
    ],
    if (soldAt != null) 'soldAt': soldAt.toUtc().toIso8601String(),
    if (redeemRewards > 0) 'redeemRewards': redeemRewards,
  };

  Future<SaleResult> createSale({
    required String id,
    String? customerId,
    required List<({String productId, double quantity})> items,
    required List<({PayMethod method, int amount})> payments,
  }) => postSale(saleBody(id: id, customerId: customerId, items: items, payments: payments));

  /// Envoie une vente déjà préparée, éventuellement pour une autre entreprise que la courante.
  Future<SaleResult> postSale(Map<String, dynamic> body, {String? businessId}) async =>
      SaleResult.fromJson(await api.post<Map<String, dynamic>>('/v1/sales', data: body, businessId: businessId));

  /// Annule une vente : stock remis, paiements et points de fidélité repris (motif obligatoire).
  Future<void> voidSale(String id, String reason) =>
      api.post<Map<String, dynamic>>('/v1/sales/$id/void', data: {'reason': reason});

  Future<SaleDetail> sale(String id) async =>
      SaleDetail.fromJson(await _cachedGet<Map<String, dynamic>>('/v1/sales/$id'));

  /// Ventes d'une journée (aujourd'hui par défaut), les plus récentes d'abord.
  /// [mine] : seulement les ventes du vendeur connecté.
  Future<List<SaleSummary>> salesOfDay([DateTime? day, bool mine = false]) async {
    final d = (day ?? DateTime.now()).toUtc().toIso8601String().substring(0, 10);
    final r = await _cachedGet<Map<String, dynamic>>(
      '/v1/sales',
      query: {'from': d, 'to': d, 'limit': 100, 'mine': mine ? 'true' : null},
    );
    return (r['data'] as List).map((e) => SaleSummary.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<DaySummary> todaySummary() async =>
      DaySummary.fromJson(await _cachedGet<Map<String, dynamic>>('/v1/sales/summary'));

  /// Ma journée de vendeur.
  Future<MyDay> myDay() async => MyDay.fromJson(await _cachedGet<Map<String, dynamic>>('/v1/sales/my-day'));

  Future<void> addExpense({required String category, required int amount}) =>
      api.post<void>('/v1/sales/expenses', data: {'category': category, 'amount': amount, 'method': 'cash'});

  // ---------- Clients et carnet de crédit ----------
  Future<List<Contact>> customers({String? search}) async {
    const path = '/v1/contacts';
    const all = {'limit': 100, 'type': 'customer'};
    List<Contact> parse(Map<String, dynamic> r) =>
        (r['data'] as List).map((e) => Contact.fromJson(e as Map<String, dynamic>)).toList();
    if (search == null || search.isEmpty) return parse(await _cachedGet<Map<String, dynamic>>(path, query: all));
    try {
      return parse(await api.get<Map<String, dynamic>>(path, query: {...all, 'search': search}));
    } on ApiException catch (e) {
      final saved = e.isNetwork ? _fromCache<Map<String, dynamic>>(path, query: all) : null;
      if (saved == null) rethrow;
      final q = search.toLowerCase();
      final digits = search.replaceAll(RegExp(r'\D'), '');
      return parse(saved)
          .where(
            (c) =>
                c.name.toLowerCase().contains(q) ||
                (digits.length >= 3 && (c.phone ?? '').replaceAll(RegExp(r'\D'), '').contains(digits)),
          )
          .toList();
    }
  }

  /// Annuaire clients avec soldes, achats et totaux (en-tête).
  Future<CustomerList> customerList({
    String? search,
    CustomerFilter filter = CustomerFilter.all,
    CustomerSort sort = CustomerSort.name,
  }) async {
    final query = {
      'filter': filter.api,
      'sort': sort.api,
      'limit': 100,
      'search': ?(search?.isEmpty ?? true ? null : search),
    };
    return CustomerList.fromJson(await _cachedGet<Map<String, dynamic>>('/v1/customers', query: query));
  }

  Future<CustomerOverview> customerOverview(String id) async =>
      CustomerOverview.fromJson(await _cachedGet<Map<String, dynamic>>('/v1/customers/$id'));

  /// Crée ou modifie une fiche client. Le plafond n'est envoyé que si l'utilisateur peut le fixer.
  Future<Contact> saveCustomer(
    CustomerDraft draft, {
    String? id,
    bool withLimit = true,
    String type = 'customer',
  }) async {
    final data = {...draft.toJson(withLimit: withLimit), if (id == null) 'type': type};
    return Contact.fromJson(
      id == null
          ? await api.post<Map<String, dynamic>>('/v1/contacts', data: data)
          : await api.patch<Map<String, dynamic>>('/v1/contacts/$id', data: data),
    );
  }

  Future<void> deleteCustomer(String id) => api.delete<void>('/v1/contacts/$id');

  /// Reprise d'une ancienne dette (montant positif) ou remise de dette (négatif). Renvoie le nouveau solde.
  Future<int> adjustBalance(String customerId, {required int amount, required String reason}) async {
    final r = await api.post<Map<String, dynamic>>(
      '/v1/customers/$customerId/adjustments',
      data: {'amount': amount, 'reason': reason},
    );
    return (r['balance'] as num).toInt();
  }

  /// Note qu'un rappel de paiement vient d'être envoyé.
  Future<void> markReminded(String customerId, String channel) =>
      api.post<void>('/v1/customers/$customerId/reminders', data: {'channel': channel});

  Future<Contact> createCustomer({required String name, String? phone}) async =>
      Contact.fromJson(await api.post<Map<String, dynamic>>('/v1/contacts', data: {'name': name, 'phone': ?phone}));

  Future<List<Debtor>> debtors() async => (await _cachedGet<List<dynamic>>(
    '/v1/sales/debtors',
  )).map((e) => Debtor.fromJson(e as Map<String, dynamic>)).toList();

  Future<Ledger> ledger(String customerId) async =>
      Ledger.fromJson(await _cachedGet<Map<String, dynamic>>('/v1/sales/customers/$customerId/ledger'));

  Future<int> repay(String customerId, int amount, PayMethod method) async {
    final r = await api.post<Map<String, dynamic>>(
      '/v1/sales/customers/$customerId/repayments',
      data: {'amount': amount, 'method': method.api},
    );
    return (r['balance'] as num).toInt();
  }

  // ---------- Achats et fournisseurs ----------
  Future<PurchaseList> purchases({PurchaseFilter filter = PurchaseFilter.all, String? supplierId}) async =>
      PurchaseList.fromJson(
        await _cachedGet<Map<String, dynamic>>(
          '/v1/purchases',
          query: {'filter': filter.api, 'limit': 100, 'supplierId': ?supplierId},
        ),
      );

  Future<PurchaseDetail> purchase(String id) async =>
      PurchaseDetail.fromJson(await _cachedGet<Map<String, dynamic>>('/v1/purchases/$id'));

  /// Corps de POST /v1/purchases (et PATCH, sans id, réception ni paiement).
  static Map<String, dynamic> purchaseBody({
    String? id,
    required String supplierId,
    required List<PurchaseLineDraft> lines,
    DateTime? expectedDate,
    String? note,
    bool draft = false,
    bool receive = false,
    ({int amount, PayMethod method})? payment,
  }) => {
    'id': ?id,
    'supplierId': supplierId,
    'lines': [for (final l in lines) l.toJson()],
    'expectedDate': expectedDate == null ? null : DateFormat('yyyy-MM-dd').format(expectedDate),
    'note': (note ?? '').trim().isEmpty ? null : note!.trim(),
    'draft': draft,
    if (receive) 'receive': true,
    if (payment != null) 'payment': {'amount': payment.amount, 'method': payment.method.api},
  };

  /// Facture fournisseur en photo → proposition d'achat (la lecture prend de 5 à 40 secondes).
  Future<InvoiceScan> scanInvoice(List<int> bytes, {String filename = 'facture.jpg'}) async => InvoiceScan.fromJson(
    await api.upload<Map<String, dynamic>>(
      '/v1/purchases/scan',
      bytes,
      filename: filename,
      receiveTimeout: const Duration(seconds: 100),
    ),
  );

  Future<PurchaseDetail> createPurchase(Map<String, dynamic> body) async =>
      PurchaseDetail.fromJson(await api.post<Map<String, dynamic>>('/v1/purchases', data: body));

  Future<PurchaseDetail> updatePurchase(String id, Map<String, dynamic> body) async {
    final data = Map<String, dynamic>.of(body)..removeWhere((k, _) => k == 'id' || k == 'receive' || k == 'payment');
    return PurchaseDetail.fromJson(await api.patch<Map<String, dynamic>>('/v1/purchases/$id', data: data));
  }

  Future<PurchaseDetail> confirmPurchase(String id) async =>
      PurchaseDetail.fromJson(await api.post<Map<String, dynamic>>('/v1/purchases/$id/confirm'));

  Future<PurchaseDetail> cancelPurchase(String id) async =>
      PurchaseDetail.fromJson(await api.post<Map<String, dynamic>>('/v1/purchases/$id/cancel'));

  /// Réception (tout ce qui reste si [lines] est vide), avec paiement au livreur éventuel.
  Future<PurchaseDetail> receivePurchase(
    String id, {
    List<({String lineId, double quantity, int unitCost})> lines = const [],
    String? note,
    ({int amount, PayMethod method})? payment,
  }) async {
    final r = await api.post<Map<String, dynamic>>(
      '/v1/purchases/$id/receive',
      data: {
        if (lines.isNotEmpty)
          'lines': [
            for (final l in lines) {'lineId': l.lineId, 'quantity': l.quantity, 'unitCost': l.unitCost},
          ],
        'note': (note ?? '').trim().isEmpty ? null : note!.trim(),
        if (payment != null) 'payment': {'amount': payment.amount, 'method': payment.method.api},
      },
    );
    return PurchaseDetail.fromJson(r['order'] as Map<String, dynamic>);
  }

  Future<PurchaseDetail> payPurchase(
    String id, {
    required int amount,
    required PayMethod method,
    String? paymentId,
  }) async => PurchaseDetail.fromJson(
    await api.post<Map<String, dynamic>>(
      '/v1/purchases/$id/payments',
      data: {'id': ?paymentId, 'amount': amount, 'method': method.api},
    ),
  );

  Future<List<SupplierRow>> suppliers({String? search}) async => (await _cachedGet<List<dynamic>>(
    '/v1/suppliers',
    query: {'search': ?(search?.isEmpty ?? true ? null : search)},
  )).map((e) => SupplierRow.fromJson(e as Map<String, dynamic>)).toList();

  Future<SupplierOverview> supplierOverview(String id) async =>
      SupplierOverview.fromJson(await _cachedGet<Map<String, dynamic>>('/v1/suppliers/$id'));

  /// Paiement global : réparti sur les bons impayés, du plus ancien au plus récent. Renvoie la dette restante.
  Future<int> paySupplier(String id, {required int amount, required PayMethod method}) async {
    final r = await api.post<Map<String, dynamic>>(
      '/v1/suppliers/$id/payments',
      data: {'amount': amount, 'method': method.api},
    );
    return (r['due'] as num).toInt();
  }

  // ---------- Boutique en ligne ----------
  Future<ShopOverview> shop() async => ShopOverview.fromJson(await _cachedGet<Map<String, dynamic>>('/v1/shop'));

  /// Couverture de la vitrine : renvoie les réglages à jour.
  Future<ShopSettings> uploadShopCover(List<int> bytes, {String filename = 'cover.jpg'}) async =>
      ShopSettings.fromJson(await api.upload<Map<String, dynamic>>('/v1/shop/cover', bytes, filename: filename));

  Future<ShopSettings> deleteShopCover() async =>
      ShopSettings.fromJson(await api.delete<Map<String, dynamic>>('/v1/shop/cover'));

  Future<ShopSettings> saveShopSettings(ShopSettings s) async =>
      ShopSettings.fromJson(await api.put<Map<String, dynamic>>('/v1/shop/settings', data: s.toJson()));

  /// Publie ou retire des produits de la boutique (tous si [productIds] est null). Renvoie le nombre modifié.
  Future<int> publishProducts({List<String>? productIds, required bool published}) async {
    final r = await api.post<Map<String, dynamic>>(
      '/v1/shop/publish',
      data: {'productIds': ?productIds, 'published': published},
    );
    return (r['updated'] as num).toInt();
  }

  Future<List<ShopOrder>> shopOrders({ShopOrderFilter filter = ShopOrderFilter.open}) async =>
      ((await _cachedGet<Map<String, dynamic>>('/v1/shop/orders', query: {'filter': filter.api, 'limit': 100}))['data']
              as List)
          .map((e) => ShopOrder.fromJson(e as Map<String, dynamic>))
          .toList();

  Future<ShopOrder> shopOrder(String id) async =>
      ShopOrder.fromJson(await _cachedGet<Map<String, dynamic>>('/v1/shop/orders/$id'));

  /// Fait avancer une commande. « Livrée » enregistre la vente avec le paiement reçu.
  Future<ShopOrder> setShopOrderStatus(
    String id,
    ShopOrderStatus status, {
    String? reason,
    ({int amount, PayMethod method})? payment,
  }) async => ShopOrder.fromJson(
    await api.post<Map<String, dynamic>>(
      '/v1/shop/orders/$id/status',
      data: {
        'status': status.api,
        'reason': ?reason,
        if (payment != null) 'payment': {'amount': payment.amount, 'method': payment.method.api},
      },
    ),
  );

  // ---------- Caisse ----------
  /// Ma caisse ouverte (null si fermée).
  // ---------- Fidélité ----------

  Future<LoyaltyDashboard> loyaltyDashboard() async =>
      LoyaltyDashboard.fromJson(await _cachedGet<Map<String, dynamic>>('/v1/loyalty'));

  Future<LoyaltySettings> loyaltySettings() async =>
      LoyaltySettings.fromJson(await _cachedGet<Map<String, dynamic>>('/v1/loyalty/settings'));

  Future<LoyaltySettings> saveLoyaltySettings(LoyaltySettings s) async =>
      LoyaltySettings.fromJson(await api.put<Map<String, dynamic>>('/v1/loyalty/settings', data: s.toJson()));

  Future<LoyaltyCard> loyaltyCard(String customerId) async =>
      LoyaltyCard.fromJson(await _cachedGet<Map<String, dynamic>>('/v1/loyalty/customers/$customerId'));

  /// Cadeau (points positifs) ou correction : renvoie le nouveau solde.
  Future<int> adjustLoyalty(String customerId, int points, String reason) async {
    final r = await api.post<Map<String, dynamic>>(
      '/v1/loyalty/customers/$customerId/adjust',
      data: {'points': points, 'reason': reason},
    );
    return (r['balance'] as num).toInt();
  }

  // ---------- Relances ----------

  Future<ReminderQueue> reminders() async =>
      ReminderQueue.fromJson(await _cachedGet<Map<String, dynamic>>('/v1/reminders'));

  /// Note qu'un crédit (kind = credit, id du client) ou une facture vient d'être relancé.
  Future<void> recordReminder({required String kind, required String id, required String channel}) =>
      api.post<Map<String, dynamic>>('/v1/reminders', data: {'kind': kind, 'id': id, 'channel': channel});

  // ---------- Notifications ----------

  Future<NotificationsPage> notifications() async =>
      NotificationsPage.fromJson(await _cachedGet<Map<String, dynamic>>('/v1/notifications'));

  /// Pastille de la cloche (0 hors connexion).
  Future<int> unreadNotifications() async {
    final r = await api.get<Map<String, dynamic>>('/v1/notifications/unread-count');
    return (r['unread'] as num?)?.toInt() ?? 0;
  }

  Future<int> markNotificationRead(String id) async {
    final r = await api.post<Map<String, dynamic>>('/v1/notifications/$id/read');
    return (r['unread'] as num?)?.toInt() ?? 0;
  }

  Future<void> markAllNotificationsRead() async {
    await api.post<Map<String, dynamic>>('/v1/notifications/read-all');
  }

  Future<CashSession?> cashCurrent() async {
    final r = await _cachedGet<Map<String, dynamic>>('/v1/cash/current');
    final s = r['session'];
    return s == null ? null : CashSession.fromJson(s as Map<String, dynamic>);
  }

  Future<CashSession> openCash({required int openingFloat, String? note}) async => CashSession.fromJson(
    await api.post<Map<String, dynamic>>(
      '/v1/cash/open',
      data: {'openingFloat': openingFloat, 'note': (note ?? '').trim().isEmpty ? null : note!.trim()},
    ),
  );

  Future<CashSession> cashMovement({required bool isIn, required int amount, required String reason}) async =>
      CashSession.fromJson(
        await api.post<Map<String, dynamic>>(
          '/v1/cash/current/movements',
          data: {'direction': isIn ? 'in' : 'out', 'amount': amount, 'reason': reason.trim()},
        ),
      );

  /// Clôture ma caisse, ou celle d'un vendeur si [sessionId] est donné (gérant).
  Future<CashSession> closeCash({String? sessionId, required Map<PayMethod, int> counted, String? note}) async =>
      CashSession.fromJson(
        await api.post<Map<String, dynamic>>(
          sessionId == null ? '/v1/cash/current/close' : '/v1/cash/sessions/$sessionId/close',
          data: {
            'counted': {for (final e in counted.entries) e.key.api: e.value},
            'note': (note ?? '').trim().isEmpty ? null : note!.trim(),
          },
        ),
      );

  Future<List<CashSessionSummary>> cashSessions() async =>
      ((await _cachedGet<Map<String, dynamic>>('/v1/cash/sessions', query: {'limit': 60}))['data'] as List)
          .map((e) => CashSessionSummary.fromJson(e as Map<String, dynamic>))
          .toList();

  Future<CashSession> cashSession(String id) async =>
      CashSession.fromJson(await _cachedGet<Map<String, dynamic>>('/v1/cash/sessions/$id'));

  // ---------- Équipe ----------
  Future<List<Member>> members() async =>
      (await _cachedGet<List<dynamic>>('/v1/members')).map((e) => Member.fromJson(e as Map<String, dynamic>)).toList();

  Future<void> inviteMember({required String phone, String? fullName, required TeamRole role, String? locationId}) =>
      api.post<void>(
        '/v1/members',
        data: {'phone': phone, 'fullName': ?fullName, 'roleKey': role.api, 'locationId': ?locationId},
      );

  /// [locationId] : '' pour « tous les points de vente », null pour ne pas changer.
  Future<void> updateMember(String id, {TeamRole? role, String? status, String? locationId}) => api.patch<void>(
    '/v1/members/$id',
    data: {
      'roleKey': ?role?.api,
      'status': ?status,
      if (locationId != null) 'locationId': locationId.isEmpty ? null : locationId,
    },
  );

  // ---------- Points de vente ----------
  Future<LocationsState> locations() async =>
      LocationsState.fromJson(await _cachedGet<Map<String, dynamic>>('/v1/locations'));

  Future<ShopLocation> saveLocation({String? id, required String name, String? address, String? phone}) async {
    final data = {'name': name, 'address': address, 'phone': phone};
    return ShopLocation.fromJson(
      id == null
          ? await api.post<Map<String, dynamic>>('/v1/locations', data: data)
          : await api.patch<Map<String, dynamic>>('/v1/locations/$id', data: data),
    );
  }

  Future<void> makeMainLocation(String id) => api.patch<void>('/v1/locations/$id', data: {'makeDefault': true});

  Future<void> archiveLocation(String id) => api.post<void>('/v1/locations/$id/archive');

  Future<StockTransfer> transferStock({
    required String id,
    required String fromId,
    required String toId,
    required List<({String productId, double quantity})> lines,
    String? note,
  }) async => StockTransfer.fromJson(
    await api.post<Map<String, dynamic>>(
      '/v1/inventory/transfers',
      data: {
        'id': id,
        'fromId': fromId,
        'toId': toId,
        'lines': [
          for (final l in lines) {'productId': l.productId, 'quantity': l.quantity},
        ],
        'note': ?note,
      },
    ),
  );

  Future<List<StockTransfer>> transfers() async => [
    for (final t in await _cachedGet<List<dynamic>>('/v1/inventory/transfers'))
      StockTransfer.fromJson(t as Map<String, dynamic>),
  ];

  Future<void> removeMember(String id) => api.delete<void>('/v1/members/$id');

  // ---------- Rapports ----------
  Future<ReportOverview> report(DateTime from, DateTime to) async => ReportOverview.fromJson(
    await _cachedGet<Map<String, dynamic>>('/v1/reports/overview', query: {'from': _day(from), 'to': _day(to)}),
  );

  // ---------- Livraison ----------
  Future<List<Courier>> couriers() async => [
    for (final c in await _cachedGet<List<dynamic>>('/v1/couriers')) Courier.fromJson(c as Map<String, dynamic>),
  ];

  Future<Courier> addCourier({required String name, String? phone, String vehicle = 'moto'}) async => Courier.fromJson(
    await api.post<Map<String, dynamic>>(
      '/v1/couriers',
      data: {'name': name, 'phone': (phone ?? '').trim().isEmpty ? null : phone, 'vehicle': vehicle},
    ),
  );

  Future<Courier> updateCourier(String id, Map<String, Object?> changes) async =>
      Courier.fromJson(await api.patch<Map<String, dynamic>>('/v1/couriers/$id', data: changes));

  Future<DeliveryBoard> deliveryBoard({bool done = false}) async => DeliveryBoard.fromJson(
    await _cachedGet<Map<String, dynamic>>('/v1/deliveries', query: {'view': done ? 'done' : 'active'}),
  );

  Future<Delivery> createDelivery(Map<String, Object?> data) async =>
      Delivery.fromJson(await api.post<Map<String, dynamic>>('/v1/deliveries', data: data));

  Future<Delivery> updateDelivery(String id, Map<String, Object?> changes) async =>
      Delivery.fromJson(await api.patch<Map<String, dynamic>>('/v1/deliveries/$id', data: changes));

  /// Le livreur a remis l'argent encaissé.
  Future<int> settleCourier(String courierId) async =>
      _int((await api.post<Map<String, dynamic>>('/v1/couriers/$courierId/settle'))['amount']);

  // ---------- Réservation ----------
  Future<AppointmentList> appointments(DateTime day) async => AppointmentList.fromJson(
    await _cachedGet<Map<String, dynamic>>('/v1/appointments', query: {'from': _day(day), 'to': _day(day)}),
  );

  Future<BookingSettings> bookingSettings() async =>
      BookingSettings.fromJson(await _cachedGet<Map<String, dynamic>>('/v1/appointments/settings'));

  Future<BookingSettings> saveBookingSettings(BookingSettings s) async =>
      BookingSettings.fromJson(await api.put<Map<String, dynamic>>('/v1/appointments/settings', data: s.toJson()));

  Future<Appointment> createAppointment(AppointmentDraft d) async =>
      Appointment.fromJson(await api.post<Map<String, dynamic>>('/v1/appointments', data: d.toJson()));

  Future<Appointment> updateAppointment(String id, Map<String, Object?> changes) async =>
      Appointment.fromJson(await api.patch<Map<String, dynamic>>('/v1/appointments/$id', data: changes));

  // ---------- Assistant IA ----------
  Future<AssistantStatus> assistantStatus() async =>
      AssistantStatus.fromJson(await api.get<Map<String, dynamic>>('/v1/assistant'));

  /// Les 20 derniers messages suffisent au contexte (le serveur n'en accepte pas plus).
  Future<AssistantReply> askAssistant(List<ChatMessage> history) async {
    final turns = history.where((m) => !m.failed).toList();
    final last = turns.length > 20 ? turns.sublist(turns.length - 20) : turns;
    // Le premier message envoyé doit venir de l'utilisateur
    final start = last.indexWhere((m) => m.fromUser);
    return AssistantReply.fromJson(
      await api.post<Map<String, dynamic>>(
        '/v1/assistant/chat',
        data: {
          'messages': [for (final m in last.sublist(start < 0 ? 0 : start)) m.toJson()],
        },
      ),
    );
  }

  // ---------- Documents ----------
  Future<DocumentList> storedDocuments({DocCategory? category, String? search}) async => DocumentList.fromJson(
    await _cachedGet<Map<String, dynamic>>(
      '/v1/documents',
      query: {'category': category?.key, if (search != null && search.isNotEmpty) 'search': search},
    ),
  );

  Future<BusinessDocument> storedDocument(String id) async =>
      BusinessDocument.fromJson(await _cachedGet<Map<String, dynamic>>('/v1/documents/$id'));

  Future<BusinessDocument> uploadStoredDocument({
    required List<int> bytes,
    required String filename,
    required String title,
    required DocCategory category,
    String? note,
    DateTime? expiresOn,
  }) async => BusinessDocument.fromJson(
    await api.upload<Map<String, dynamic>>(
      '/v1/documents',
      bytes,
      filename: filename,
      fields: {
        'title': title,
        'category': category.key,
        'note': note ?? '',
        'expiresOn': expiresOn == null ? '' : _day(expiresOn),
      },
    ),
  );

  Future<BusinessDocument> updateStoredDocument(
    String id, {
    required String title,
    required DocCategory category,
    String? note,
    DateTime? expiresOn,
  }) async => BusinessDocument.fromJson(
    await api.patch<Map<String, dynamic>>(
      '/v1/documents/$id',
      data: {
        'title': title,
        'category': category.key,
        'note': (note ?? '').trim().isEmpty ? null : note!.trim(),
        'expiresOn': expiresOn == null ? null : _day(expiresOn),
      },
    ),
  );

  Future<void> deleteStoredDocument(String id) => api.delete<void>('/v1/documents/$id');

  /// Le fichier (réservé aux membres autorisés : jamais par l'adresse publique).
  Future<List<int>> storedDocumentBytes(String id) async {
    final r = await api.dio.get<List<int>>(
      '/v1/documents/$id/file',
      options: Options(responseType: ResponseType.bytes),
    );
    return r.data ?? const [];
  }

  // ---------- Analyses ----------
  Future<Insights> insights(int days) async =>
      Insights.fromJson(await _cachedGet<Map<String, dynamic>>('/v1/reports/insights', query: {'days': '$days'}));

  /// Rapport de la semaine qui contient [week] (par défaut : la semaine complète précédente).
  Future<WeeklyReport> weeklyReport([DateTime? week]) async => WeeklyReport.fromJson(
    await _cachedGet<Map<String, dynamic>>('/v1/reports/weekly', query: {if (week != null) 'week': _day(week)}),
  );

  // ---------- Factures et devis ----------
  static String _day(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Corps d'un devis / d'une facture.
  static Map<String, dynamic> documentBody({
    required String customerId,
    required List<DocLineDraft> lines,
    int discount = 0,
    DateTime? issueDate,
    DateTime? dueDate,
    bool clearDueDate = false,
    String? note,
  }) => {
    'customerId': customerId,
    'lines': [for (final l in lines) l.toJson()],
    'discount': discount,
    if (issueDate != null) 'issueDate': _day(issueDate),
    if (dueDate != null) 'dueDate': _day(dueDate) else if (clearDueDate) 'dueDate': null,
    'note': (note ?? '').trim().isEmpty ? null : note!.trim(),
  };

  Future<InvoicingSummary> invoicingSummary() async =>
      InvoicingSummary.fromJson(await _cachedGet<Map<String, dynamic>>('/v1/invoicing/summary'));

  Future<List<DocSummary>> documents({
    required DocKind kind,
    String? status,
    bool overdue = false,
    String? search,
  }) async {
    final r = await _cachedGet<Map<String, dynamic>>(
      '/v1/invoicing/documents',
      query: {
        'kind': kind.api,
        'status': status,
        'overdue': overdue ? 'true' : null,
        'search': (search ?? '').isEmpty ? null : search,
        'limit': 100,
      },
    );
    return (r['data'] as List).map((e) => DocSummary.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<DocDetail> document(String id) async =>
      DocDetail.fromJson(await _cachedGet<Map<String, dynamic>>('/v1/invoicing/documents/$id'));

  Future<DocDetail> createDocument({
    required String id,
    required DocKind kind,
    required Map<String, dynamic> body,
  }) async => DocDetail.fromJson(
    await api.post<Map<String, dynamic>>('/v1/invoicing/documents', data: {...body, 'id': id, 'kind': kind.api}),
  );

  Future<DocDetail> updateQuote(String id, Map<String, dynamic> body) async =>
      DocDetail.fromJson(await api.patch<Map<String, dynamic>>('/v1/invoicing/documents/$id', data: body));

  /// accept, decline, reopen
  Future<DocDetail> quoteAction(String id, String action) async =>
      DocDetail.fromJson(await api.post<Map<String, dynamic>>('/v1/invoicing/documents/$id/$action'));

  Future<DocDetail> convertQuote(String id, {DateTime? dueDate}) async => DocDetail.fromJson(
    await api.post<Map<String, dynamic>>(
      '/v1/invoicing/documents/$id/convert',
      data: {if (dueDate != null) 'dueDate': _day(dueDate)},
    ),
  );

  Future<DocDetail> payInvoice(
    String id, {
    required String paymentId,
    required int amount,
    required PayMethod method,
    String? reference,
  }) async => DocDetail.fromJson(
    await api.post<Map<String, dynamic>>(
      '/v1/invoicing/documents/$id/payments',
      data: {
        'id': paymentId,
        'amount': amount,
        'method': method.api,
        if ((reference ?? '').trim().isNotEmpty) 'reference': reference!.trim(),
      },
    ),
  );

  Future<DocDetail> cancelInvoice(String id, String reason) async => DocDetail.fromJson(
    await api.post<Map<String, dynamic>>('/v1/invoicing/documents/$id/cancel', data: {'reason': reason}),
  );
}

/// Ligne en cours de saisie dans l'éditeur.
class DocLineDraft {
  const DocLineDraft({
    this.productId,
    required this.name,
    this.description,
    required this.quantity,
    required this.unitPrice,
  });
  final String? productId;
  final String name;
  final String? description;
  final double quantity;
  final int unitPrice;

  int get total => (quantity * unitPrice).round();

  DocLineDraft copyWith({double? quantity, int? unitPrice, String? name, String? description}) => DocLineDraft(
    productId: productId,
    name: name ?? this.name,
    description: description ?? this.description,
    quantity: quantity ?? this.quantity,
    unitPrice: unitPrice ?? this.unitPrice,
  );

  factory DocLineDraft.fromLine(DocLine l) => DocLineDraft(
    productId: l.productId,
    name: l.name,
    description: l.description,
    quantity: l.quantity,
    unitPrice: l.unitPrice,
  );

  Map<String, dynamic> toJson() => {
    if (productId != null) 'productId': productId,
    'name': name,
    if ((description ?? '').trim().isNotEmpty) 'description': description!.trim(),
    'quantity': quantity,
    'unitPrice': unitPrice,
  };
}

int _int(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
