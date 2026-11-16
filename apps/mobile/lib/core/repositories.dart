import 'dart:async';
import 'dart:convert';

import 'api/api_client.dart';
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
    return '$cachePrefix${user ? 'user' : (api.businessId ?? '-')}:$path${qs.isEmpty ? '' : '?$qs'}';
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
  Future<String> requestOtp(String phone) async {
    final r = await api.post<Map<String, dynamic>>('/v1/auth/otp/request', data: {'phone': phone}, public: true);
    return r['phone'] as String;
  }

  Future<({String access, String refresh})> verifyOtp(String phone, String code, {String? deviceId}) async {
    final r = await api.post<Map<String, dynamic>>(
      '/v1/auth/otp/verify',
      data: {'phone': phone, 'code': code, 'deviceId': ?deviceId},
      public: true,
    );
    return (access: r['accessToken'] as String, refresh: r['refreshToken'] as String);
  }

  Future<void> logout(String refreshToken) =>
      api.post<void>('/v1/auth/logout', data: {'refreshToken': refreshToken}, public: true);

  Future<Me> me() async => Me.fromJson(await _cachedGet<Map<String, dynamic>>('/v1/me', user: true));

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
  Future<String> createBusiness({required String name, String? category, String? city}) async {
    final r = await api.post<Map<String, dynamic>>(
      '/v1/businesses',
      data: {'name': name, 'category': ?category, 'city': ?city},
    );
    return (r['business'] as Map)['id'] as String;
  }

  Future<CurrentBusiness> currentBusiness() async =>
      CurrentBusiness.fromJson(await _cachedGet<Map<String, dynamic>>('/v1/business'));

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

  // ---------- Équipe ----------
  Future<List<Member>> members() async =>
      (await _cachedGet<List<dynamic>>('/v1/members')).map((e) => Member.fromJson(e as Map<String, dynamic>)).toList();

  Future<void> inviteMember({required String phone, String? fullName, required TeamRole role}) =>
      api.post<void>('/v1/members', data: {'phone': phone, 'fullName': ?fullName, 'roleKey': role.api});

  Future<void> updateMember(String id, {TeamRole? role, String? status}) =>
      api.patch<void>('/v1/members/$id', data: {'roleKey': ?role?.api, 'status': ?status});

  Future<void> removeMember(String id) => api.delete<void>('/v1/members/$id');

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
