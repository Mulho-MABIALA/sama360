import 'api/api_client.dart';
import 'models.dart';

/// Toutes les routes de l'API utilisées par l'app, regroupées et typées.
class SamaRepository {
  SamaRepository(this.api);
  final ApiClient api;

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

  Future<Me> me() async => Me.fromJson(await api.get<Map<String, dynamic>>('/v1/me'));

  Future<void> updateName(String fullName) => api.patch<void>('/v1/me', data: {'fullName': fullName});

  // ---------- Entreprises ----------
  Future<String> createBusiness({required String name, String? category, String? city}) async {
    final r = await api.post<Map<String, dynamic>>(
      '/v1/businesses',
      data: {'name': name, 'category': ?category, 'city': ?city},
    );
    return (r['business'] as Map)['id'] as String;
  }

  Future<CurrentBusiness> currentBusiness() async =>
      CurrentBusiness.fromJson(await api.get<Map<String, dynamic>>('/v1/business'));

  // ---------- Catalogue ----------
  Future<List<Category>> categories() async => (await api.get<List<dynamic>>('/v1/catalog/categories'))
      .map((e) => Category.fromJson(e as Map<String, dynamic>))
      .toList();

  Future<List<Product>> products({String? search, String? categoryId}) async {
    final r = await api.get<Map<String, dynamic>>(
      '/v1/catalog/products',
      query: {'limit': 100, 'search': search, 'categoryId': categoryId},
    );
    return (r['data'] as List).map((e) => Product.fromJson(e as Map<String, dynamic>)).toList();
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

  // ---------- Stock ----------
  Future<StockOverview> stock({bool lowOnly = false}) async => StockOverview.fromJson(
    await api.get<Map<String, dynamic>>('/v1/inventory/stock', query: {'lowOnly': lowOnly ? 'true' : null}),
  );

  Future<void> addStock(String productId, double quantity, {int? unitCost}) => api.post<void>(
    '/v1/inventory/movements',
    data: {'productId': productId, 'type': 'purchase', 'quantity': quantity, 'unitCost': ?unitCost},
  );

  // ---------- Ventes ----------
  Future<SaleResult> createSale({
    required String id,
    String? customerId,
    required List<({String productId, double quantity})> items,
    required List<({PayMethod method, int amount})> payments,
  }) async => SaleResult.fromJson(
    await api.post<Map<String, dynamic>>(
      '/v1/sales',
      data: {
        'id': id,
        'customerId': ?customerId,
        'items': [
          for (final i in items) {'productId': i.productId, 'quantity': i.quantity},
        ],
        'payments': [
          for (final p in payments) {'method': p.method.api, 'amount': p.amount},
        ],
      },
    ),
  );

  Future<DaySummary> todaySummary() async =>
      DaySummary.fromJson(await api.get<Map<String, dynamic>>('/v1/sales/summary'));

  Future<void> addExpense({required String category, required int amount}) =>
      api.post<void>('/v1/sales/expenses', data: {'category': category, 'amount': amount, 'method': 'cash'});

  // ---------- Clients et carnet de crédit ----------
  Future<List<Contact>> customers({String? search}) async {
    final r = await api.get<Map<String, dynamic>>('/v1/contacts', query: {'limit': 100, 'search': search, 'type': 'customer'});
    return (r['data'] as List).map((e) => Contact.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Contact> createCustomer({required String name, String? phone}) async => Contact.fromJson(
    await api.post<Map<String, dynamic>>('/v1/contacts', data: {'name': name, 'phone': ?phone}),
  );

  Future<List<Debtor>> debtors() async => (await api.get<List<dynamic>>('/v1/sales/debtors'))
      .map((e) => Debtor.fromJson(e as Map<String, dynamic>))
      .toList();

  Future<Ledger> ledger(String customerId) async =>
      Ledger.fromJson(await api.get<Map<String, dynamic>>('/v1/sales/customers/$customerId/ledger'));

  Future<int> repay(String customerId, int amount, PayMethod method) async {
    final r = await api.post<Map<String, dynamic>>(
      '/v1/sales/customers/$customerId/repayments',
      data: {'amount': amount, 'method': method.api},
    );
    return (r['balance'] as num).toInt();
  }
}
