// Back office de l'équipe Sama360 : données renvoyées par /v1/admin/*.
import 'countries.dart';

DateTime? _date(Object? v) => v == null ? null : DateTime.parse(v as String).toLocal();
int _int(Object? v) => (v as num?)?.round() ?? 0;

/// État de l'abonnement d'une boutique.
enum AdminPlan {
  trial('Essai'),
  active('Pro'),
  expired('Expiré'),
  free('Gratuit');

  const AdminPlan(this.label);
  final String label;
  static AdminPlan of(Object? v) => values.where((p) => p.name == v).firstOrNull ?? free;
}

enum AdminStatus {
  active('Active'),
  suspended('Suspendue'),
  deleted('Supprimée');

  const AdminStatus(this.label);
  final String label;
  static AdminStatus of(Object? v) => values.where((p) => p.name == v).firstOrNull ?? active;
}

class DayValue {
  const DayValue(this.date, this.value);
  final DateTime date;
  final int value;
  factory DayValue.fromJson(Map<String, dynamic> j) => DayValue(DateTime.parse(j['date'] as String), _int(j['value']));
}

class AdminOverview {
  const AdminOverview({
    required this.days,
    required this.businesses,
    required this.newBusinesses,
    required this.newPrevious,
    required this.active7,
    required this.everSold,
    required this.suspended,
    required this.deleted,
    required this.users,
    required this.plans,
    required this.trialsEnding,
    required this.revenue,
    required this.revenuePrevious,
    required this.revenueAllTime,
    required this.mrr,
    required this.revenueOnline,
    required this.revenueManual,
    required this.paymentsCount,
    required this.pendingPayments,
    required this.gmv30,
    required this.sales30,
    required this.signupsByDay,
    required this.revenueByDay,
    required this.countries,
    required this.top,
    required this.latest,
  });

  final int days;
  final int businesses, newBusinesses, newPrevious, active7, everSold, suspended, deleted, users;
  final Map<AdminPlan, int> plans;
  final List<({String id, String name, String ownerPhone, int daysLeft})> trialsEnding;
  final int revenue, revenuePrevious, revenueAllTime, mrr, revenueOnline, revenueManual, paymentsCount;
  final int pendingPayments, gmv30, sales30;
  final List<DayValue> signupsByDay, revenueByDay;
  final List<({Country country, int count})> countries;
  final List<({String id, String name, Country country, int revenue30, int sales30})> top;
  final List<({String id, String name, Country country, String? ownerName, DateTime createdAt, AdminPlan plan})> latest;

  /// Évolution en % par rapport à la période précédente (null si rien avant).
  static int? change(int now, int before) => before == 0 ? null : (((now - before) / before) * 100).round();

  factory AdminOverview.fromJson(Map<String, dynamic> j) {
    final b = j['businesses'] as Map<String, dynamic>;
    final r = j['revenue'] as Map<String, dynamic>;
    final p = j['plans'] as Map<String, dynamic>;
    return AdminOverview(
      days: _int(j['days']),
      businesses: _int(b['total']),
      newBusinesses: _int(b['new']),
      newPrevious: _int(b['newPrevious']),
      active7: _int(b['active7']),
      everSold: _int(b['everSold']),
      suspended: _int(b['suspended']),
      deleted: _int(b['deleted']),
      users: _int(j['users']),
      plans: {for (final k in AdminPlan.values) k: _int(p[k.name])},
      trialsEnding: [
        for (final t in (j['trialsEnding'] as List? ?? []).cast<Map<String, dynamic>>())
          (
            id: t['id'] as String,
            name: t['name'] as String,
            ownerPhone: t['ownerPhone'] as String,
            daysLeft: _int(t['daysLeft']),
          ),
      ],
      revenue: _int(r['period']),
      revenuePrevious: _int(r['previous']),
      revenueAllTime: _int(r['allTime']),
      mrr: _int(r['mrr']),
      revenueOnline: _int(r['online']),
      revenueManual: _int(r['manual']),
      paymentsCount: _int(r['payments']),
      pendingPayments: _int(j['pendingPayments']),
      gmv30: _int(j['merchantsGmv30']),
      sales30: _int(j['merchantsSales30']),
      signupsByDay: [for (final d in (j['signupsByDay'] as List)) DayValue.fromJson(d as Map<String, dynamic>)],
      revenueByDay: [for (final d in (j['revenueByDay'] as List)) DayValue.fromJson(d as Map<String, dynamic>)],
      countries: [
        for (final c in (j['countries'] as List).cast<Map<String, dynamic>>())
          (country: Country.fromCode(c['code'] as String?), count: _int(c['count'])),
      ],
      top: [
        for (final t in (j['topBusinesses'] as List? ?? []).cast<Map<String, dynamic>>())
          (
            id: t['id'] as String,
            name: t['name'] as String,
            country: Country.fromCode(t['country'] as String?),
            revenue30: _int(t['revenue30']),
            sales30: _int(t['sales30']),
          ),
      ],
      latest: [
        for (final t in (j['latest'] as List? ?? []).cast<Map<String, dynamic>>())
          (
            id: t['id'] as String,
            name: t['name'] as String,
            country: Country.fromCode(t['country'] as String?),
            ownerName: t['ownerName'] as String?,
            createdAt: _date(t['createdAt'])!,
            plan: AdminPlan.of(t['plan']),
          ),
      ],
    );
  }
}

class AdminBusiness {
  const AdminBusiness({
    required this.id,
    required this.name,
    required this.slug,
    required this.country,
    required this.createdAt,
    required this.status,
    required this.ownerName,
    required this.ownerPhone,
    required this.plan,
    required this.planEndsAt,
    required this.daysLeft,
    required this.everPaid,
    required this.members,
    required this.sales30,
    required this.revenue30,
    required this.sales7,
    required this.lastSaleAt,
    required this.products,
    required this.customers,
    this.logoFileId,
  });

  final String id, name, slug;
  final Country country;
  final DateTime createdAt;
  final AdminStatus status;
  final String? ownerName;
  final String ownerPhone;
  final AdminPlan plan;
  final DateTime? planEndsAt;
  final int daysLeft;
  final bool everPaid;
  final int members, sales30, revenue30, sales7, products, customers;
  final DateTime? lastSaleAt;
  final String? logoFileId;

  factory AdminBusiness.fromJson(Map<String, dynamic> j) {
    final o = j['owner'] as Map<String, dynamic>;
    final p = j['plan'] as Map<String, dynamic>;
    final s = j['stats'] as Map<String, dynamic>;
    return AdminBusiness(
      id: j['id'] as String,
      name: j['name'] as String,
      slug: j['slug'] as String? ?? '',
      country: Country.fromCode(j['country'] as String?),
      createdAt: _date(j['createdAt'])!,
      status: AdminStatus.of(j['status']),
      ownerName: o['name'] as String?,
      ownerPhone: o['phone'] as String,
      plan: AdminPlan.of(p['state']),
      planEndsAt: _date(p['endsAt']),
      daysLeft: _int(p['daysLeft']),
      everPaid: j['everPaid'] == true,
      members: j['members'] is List ? (j['members'] as List).length : _int(j['members']),
      sales30: _int(s['sales30']),
      revenue30: _int(s['revenue30']),
      sales7: _int(s['sales7']),
      lastSaleAt: _date(s['lastSaleAt']),
      products: _int(s['products']),
      customers: _int(s['customers']),
      logoFileId: j['logoFileId'] as String?,
    );
  }
}

class AdminPage<T> {
  const AdminPage({required this.items, required this.total, required this.page, required this.pageSize});
  final List<T> items;
  final int total, page, pageSize;
  bool get hasMore => page * pageSize < total;
}

class AdminMember {
  const AdminMember({required this.name, required this.phone, required this.role, required this.roleKey});
  final String? name;
  final String phone, role, roleKey;
}

class AdminAction {
  const AdminAction({required this.action, required this.details, required this.at, required this.by});
  final String action;
  final Map<String, dynamic> details;
  final DateTime at;
  final String by;

  String get label => switch (action) {
    'gift' =>
      '${details['days']} jour(s) de Pro offert(s)${details['reason'] != null ? ' · ${details['reason']}' : ''}',
    'suspend' => 'Suspendue · ${details['reason'] ?? ''}',
    'unsuspend' => 'Réactivée',
    'restore' => 'Restaurée après suppression',
    _ => action,
  };
}

class AdminBusinessDetail {
  const AdminBusinessDetail({
    required this.business,
    required this.currency,
    required this.suspendedReason,
    required this.suspendedAt,
    required this.deletedAt,
    required this.purgeAt,
    required this.referralCode,
    required this.referredBy,
    required this.referrals,
    required this.members,
    required this.locations,
    required this.payments,
    required this.actions,
  });

  final AdminBusiness business;
  final String currency;
  final String? suspendedReason;
  final DateTime? suspendedAt, deletedAt, purgeAt;
  final String? referralCode;
  final ({String id, String name})? referredBy;
  final List<({String id, String name, DateTime createdAt})> referrals;
  final List<AdminMember> members;
  final List<({String name, bool main})> locations;
  final List<AdminPayment> payments;
  final List<AdminAction> actions;

  factory AdminBusinessDetail.fromJson(Map<String, dynamic> j) {
    final ref = j['referredBy'] as Map<String, dynamic>?;
    return AdminBusinessDetail(
      business: AdminBusiness.fromJson(j),
      currency: j['currency'] as String? ?? 'XOF',
      suspendedReason: j['suspendedReason'] as String?,
      suspendedAt: _date(j['suspendedAt']),
      deletedAt: _date(j['deletedAt']),
      purgeAt: _date(j['purgeAt']),
      referralCode: j['referralCode'] as String?,
      referredBy: ref == null ? null : (id: ref['id'] as String, name: ref['name'] as String),
      referrals: [
        for (final r in (j['referrals'] as List? ?? []).cast<Map<String, dynamic>>())
          (id: r['id'] as String, name: r['name'] as String, createdAt: _date(r['createdAt'])!),
      ],
      members: [
        for (final m in (j['members'] as List? ?? []).cast<Map<String, dynamic>>())
          AdminMember(
            name: m['name'] as String?,
            phone: m['phone'] as String,
            role: m['role'] as String? ?? '',
            roleKey: m['roleKey'] as String? ?? '',
          ),
      ],
      locations: [
        for (final l in (j['locations'] as List? ?? []).cast<Map<String, dynamic>>())
          (name: l['name'] as String, main: l['main'] == true),
      ],
      payments: [for (final p in (j['payments'] as List? ?? [])) AdminPayment.fromJson(p as Map<String, dynamic>)],
      actions: [
        for (final a in (j['actions'] as List? ?? []).cast<Map<String, dynamic>>())
          AdminAction(
            action: a['action'] as String,
            details: (a['details'] as Map?)?.cast<String, dynamic>() ?? const {},
            at: _date(a['at'])!,
            by: a['by'] as String? ?? '',
          ),
      ],
    );
  }
}

enum AdminPayStatus {
  paid('Payé'),
  toCheck('À vérifier'),
  pending('En cours'),
  rejected('Refusé'),
  failed('Échoué');

  const AdminPayStatus(this.label);
  final String label;
  static AdminPayStatus of(Object? v) => switch (v) {
    'paid' => paid,
    'to_check' => toCheck,
    'rejected' => rejected,
    'failed' => failed,
    _ => pending,
  };
  String get api => this == toCheck ? 'to_check' : name;
}

class AdminPayment {
  const AdminPayment({
    required this.id,
    required this.online,
    required this.businessId,
    required this.businessName,
    required this.yearly,
    required this.amount,
    required this.method,
    required this.reference,
    required this.status,
    required this.createdAt,
    required this.settledAt,
    required this.note,
  });

  final String id, businessId, businessName, method;
  final bool online, yearly;
  final int amount;
  final String? reference, note;
  final AdminPayStatus status;
  final DateTime createdAt;
  final DateTime? settledAt;

  factory AdminPayment.fromJson(Map<String, dynamic> j) => AdminPayment(
    id: j['id'] as String,
    online: j['source'] == 'online',
    businessId: j['businessId'] as String,
    businessName: j['businessName'] as String? ?? '—',
    yearly: j['cycle'] == 'yearly',
    amount: _int(j['amount']),
    method: j['method'] as String? ?? '',
    reference: j['reference'] as String?,
    status: AdminPayStatus.of(j['status']),
    createdAt: _date(j['createdAt'])!,
    settledAt: _date(j['settledAt']),
    note: j['note'] as String?,
  );
}

/// Filtres de la liste des commerçants.
class AdminBusinessQuery {
  const AdminBusinessQuery({
    this.search = '',
    this.plan,
    this.status,
    this.country,
    this.sort = 'recent',
    this.page = 1,
  });
  final String search;
  final AdminPlan? plan;
  final AdminStatus? status;
  final Country? country;
  final String sort;
  final int page;

  AdminBusinessQuery copyWith({
    String? search,
    AdminPlan? Function()? plan,
    AdminStatus? Function()? status,
    Country? Function()? country,
    String? sort,
    int? page,
  }) => AdminBusinessQuery(
    search: search ?? this.search,
    plan: plan != null ? plan() : this.plan,
    status: status != null ? status() : this.status,
    country: country != null ? country() : this.country,
    sort: sort ?? this.sort,
    page: page ?? 1,
  );

  Map<String, dynamic> toQuery() => {
    if (search.trim().isNotEmpty) 'q': search.trim(),
    'plan': ?plan?.name,
    'status': ?status?.name,
    'country': ?country?.code,
    'sort': sort,
    'page': page,
  };

  @override
  bool operator ==(Object other) =>
      other is AdminBusinessQuery &&
      other.search == search &&
      other.plan == plan &&
      other.status == status &&
      other.country == country &&
      other.sort == sort &&
      other.page == page;

  @override
  int get hashCode => Object.hash(search, plan, status, country, sort, page);
}
