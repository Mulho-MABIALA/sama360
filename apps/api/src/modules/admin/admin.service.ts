import { Injectable, Logger } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { countryOf } from '../../shared/countries';
import { DbService } from '../../shared/db/db.service';
import { newId } from '../../shared/ids';
import { AppError } from '../../shared/http/app-error';
import { effectivePlan, PRO_PRICES } from '../../shared/plans';
import { BillingService } from '../billing/billing.service';
import { ClosureService, GRACE_DAYS } from '../core/closure.service';

type Row = Record<string, unknown>;
const DAY = 86_400_000;

/** Activité d'une boutique (lue dans ses propres données, une boutique à la fois). */
export interface BusinessStats {
  sales30: number;
  revenue30: number;
  sales7: number;
  lastSaleAt: string | null;
  products: number;
  customers: number;
}

export type PlanState = 'trial' | 'active' | 'expired' | 'free';
export type BusinessStatus = 'active' | 'suspended' | 'deleted';

const EMPTY: BusinessStats = { sales30: 0, revenue30: 0, sales7: 0, lastSaleAt: null, products: 0, customers: 0 };

const iso = (v: unknown) => (v ? new Date(v as string).toISOString() : null);
const dayKey = (d: Date) => d.toISOString().slice(0, 10);

/**
 * Back office de l'équipe Sama360 : toutes les boutiques, abonnements, paiements, et les gestes
 * (mois offert, suspension, restauration). Réservé aux numéros de ADMIN_PHONES.
 */
@Injectable()
export class AdminService {
  private readonly log = new Logger('BackOffice');
  private cache?: { at: number; stats: Map<string, BusinessStats> };

  constructor(
    private readonly dbs: DbService,
    private readonly billing: BillingService,
    private readonly closure: ClosureService,
  ) {}

  assertAdmin(userId: string) {
    return this.billing.assertAdmin(userId);
  }

  // ─────────────────────────────── activité des boutiques

  /**
   * Ventes, produits et clients de chaque boutique. Les données de chaque boutique sont cloisonnées
   * (sécurité au niveau des lignes) : on les lit une par une ; résultat gardé 2 minutes.
   */
  async allStats(fresh = false): Promise<Map<string, BusinessStats>> {
    if (!fresh && this.cache && Date.now() - this.cache.at < 120_000) return this.cache.stats;
    const ids = (
      await this.dbs.transaction((tx) => tx.execute(sql`SELECT id FROM core.businesses WHERE deleted_at IS NULL`))
    ).rows.map((r) => (r as Row).id as string);
    const stats = new Map<string, BusinessStats>();
    for (const id of ids) {
      try {
        stats.set(id, await this.statsOf(id));
      } catch (e) {
        this.log.warn(`Activité de ${id} : ${(e as Error).message}`);
        stats.set(id, EMPTY);
      }
    }
    this.cache = { at: Date.now(), stats };
    return stats;
  }

  private async statsOf(businessId: string): Promise<BusinessStats> {
    return this.dbs.withTenant(businessId, async (tx) => {
      const s = (
        await tx.execute(sql`
          SELECT count(*) FILTER (WHERE sold_at > now() - interval '30 days')::int AS sales30,
                 coalesce(sum(total) FILTER (WHERE sold_at > now() - interval '30 days'), 0)::bigint AS revenue30,
                 count(*) FILTER (WHERE sold_at > now() - interval '7 days')::int AS sales7,
                 max(sold_at) AS last_sale
          FROM sales.sales WHERE status = 'completed'`)
      ).rows[0] as Row;
      const c = (
        await tx.execute(sql`
          SELECT (SELECT count(*) FROM catalog.products WHERE deleted_at IS NULL)::int AS products,
                 (SELECT count(*) FROM contacts.contacts WHERE deleted_at IS NULL)::int AS customers`)
      ).rows[0] as Row;
      return {
        sales30: Number(s.sales30),
        revenue30: Number(s.revenue30),
        sales7: Number(s.sales7),
        lastSaleAt: iso(s.last_sale),
        products: Number(c.products),
        customers: Number(c.customers),
      };
    });
  }

  // ─────────────────────────────── boutiques

  private async baseRows(): Promise<Row[]> {
    return (
      await this.dbs.transaction((tx) =>
        tx.execute(sql`
          SELECT b.id, b.name, b.slug, b.country, b.currency, b.created_at, b.deleted_at, b.suspended_at,
                 b.suspended_reason, b.logo_file_id, b.referral_code, b.referred_by,
                 u.id AS owner_id, u.full_name AS owner_name, u.phone AS owner_phone,
                 s.plan, s.status AS plan_status, s.current_period_end,
                 (SELECT count(*) FROM core.memberships m WHERE m.business_id = b.id AND m.status = 'active')::int AS members,
                 (SELECT count(*) FROM core.subscription_requests r
                   WHERE r.business_id = b.id AND r.status = 'approved')::int
                 + (SELECT count(*) FROM core.online_payments o
                   WHERE o.business_id = b.id AND o.status = 'paid')::int AS payments
          FROM core.businesses b
          JOIN core.users u ON u.id = b.owner_id
          LEFT JOIN core.subscriptions s ON s.business_id = b.id
          ORDER BY b.created_at DESC`),
      )
    ).rows as Row[];
  }

  private summary(r: Row, stats: BusinessStats | undefined) {
    const plan = effectivePlan(
      r.plan
        ? { plan: r.plan as string, status: r.plan_status as string, currentPeriodEnd: r.current_period_end as string }
        : null,
    );
    const status: BusinessStatus = r.deleted_at ? 'deleted' : r.suspended_at ? 'suspended' : 'active';
    return {
      id: r.id as string,
      name: r.name as string,
      slug: r.slug as string,
      country: r.country as string,
      logoFileId: (r.logo_file_id as string) ?? null,
      createdAt: iso(r.created_at)!,
      status,
      owner: { id: r.owner_id as string, name: (r.owner_name as string) ?? null, phone: r.owner_phone as string },
      plan: { state: plan.state as PlanState, endsAt: plan.endsAt, daysLeft: plan.daysLeft },
      everPaid: Number(r.payments) > 0,
      members: Number(r.members),
      stats: stats ?? EMPTY,
    };
  }

  async listBusinesses(q: {
    search?: string;
    country?: string;
    plan?: PlanState;
    status?: BusinessStatus;
    sort?: 'recent' | 'name' | 'activity' | 'revenue';
    page?: number;
    pageSize?: number;
  }) {
    const [rows, stats] = await Promise.all([this.baseRows(), this.allStats()]);
    const needle = q.search?.trim().toLowerCase().replace(/\s+/g, '');
    let list = rows.map((r) => this.summary(r, stats.get(r.id as string)));
    if (needle) {
      list = list.filter(
        (b) =>
          b.name.toLowerCase().replace(/\s+/g, '').includes(needle) ||
          b.slug.includes(needle) ||
          b.owner.phone.includes(needle) ||
          (b.owner.name ?? '').toLowerCase().replace(/\s+/g, '').includes(needle),
      );
    }
    if (q.country) list = list.filter((b) => b.country === q.country);
    if (q.plan) list = list.filter((b) => b.plan.state === q.plan);
    list = list.filter((b) => (q.status ? b.status === q.status : b.status !== 'deleted'));
    const by = {
      recent: (a: (typeof list)[0], b: (typeof list)[0]) => b.createdAt.localeCompare(a.createdAt),
      name: (a: (typeof list)[0], b: (typeof list)[0]) => a.name.localeCompare(b.name, 'fr'),
      activity: (a: (typeof list)[0], b: (typeof list)[0]) =>
        (b.stats.lastSaleAt ?? '').localeCompare(a.stats.lastSaleAt ?? ''),
      revenue: (a: (typeof list)[0], b: (typeof list)[0]) => b.stats.revenue30 - a.stats.revenue30,
    }[q.sort ?? 'recent'];
    list.sort(by);
    const size = Math.min(Math.max(q.pageSize ?? 25, 1), 100);
    const page = Math.max(q.page ?? 1, 1);
    return { total: list.length, page, pageSize: size, items: list.slice((page - 1) * size, page * size) };
  }

  async business(id: string) {
    const rows = await this.baseRows();
    const r = rows.find((x) => x.id === id);
    if (!r) throw AppError.notFound('Boutique');
    const stats = r.deleted_at ? EMPTY : await this.statsOf(id).catch(() => EMPTY);
    const base = this.summary(r, stats);
    const [members, locations, payments, actions, referrals, referrer] = await Promise.all([
      this.dbs.transaction(async (tx) =>
        (
          await tx.execute(sql`
            SELECT u.id, u.full_name, u.phone, ro.name AS role, ro.key AS role_key, m.status, m.created_at
            FROM core.memberships m JOIN core.users u ON u.id = m.user_id JOIN core.roles ro ON ro.id = m.role_id
            WHERE m.business_id = ${id} ORDER BY (ro.key = 'owner') DESC, m.created_at`)
        ).rows.map((m) => {
          const x = m as Row;
          return {
            userId: x.id as string,
            name: (x.full_name as string) ?? null,
            phone: x.phone as string,
            role: x.role as string,
            roleKey: x.role_key as string,
            status: x.status as string,
          };
        }),
      ),
      r.deleted_at
        ? Promise.resolve([])
        : this.dbs.withTenant(id, async (tx) =>
            (
              await tx.execute(sql`
                SELECT name, is_default FROM inventory.warehouses WHERE archived_at IS NULL ORDER BY is_default DESC, name`)
            ).rows.map((w) => ({ name: (w as Row).name as string, main: (w as Row).is_default as boolean })),
          ),
      this.payments({ businessId: id, pageSize: 50 }).then((p) => p.items),
      this.dbs.transaction(async (tx) =>
        (
          await tx.execute(sql`
            SELECT a.action, a.details, a.created_at, u.full_name, u.phone
            FROM core.admin_actions a JOIN core.users u ON u.id = a.admin_id
            WHERE a.business_id = ${id} ORDER BY a.created_at DESC LIMIT 30`)
        ).rows.map((a) => {
          const x = a as Row;
          return {
            action: x.action as string,
            details: x.details as Record<string, unknown>,
            at: iso(x.created_at)!,
            by: (x.full_name as string) ?? (x.phone as string),
          };
        }),
      ),
      this.dbs.transaction(async (tx) =>
        (
          await tx.execute(sql`
            SELECT id, name, created_at FROM core.businesses WHERE referred_by = ${id} ORDER BY created_at DESC`)
        ).rows.map((b) => ({
          id: (b as Row).id as string,
          name: (b as Row).name as string,
          createdAt: iso((b as Row).created_at)!,
        })),
      ),
      r.referred_by
        ? this.dbs.transaction(async (tx) => {
            const b = (
              await tx.execute(sql`SELECT id, name FROM core.businesses WHERE id = ${r.referred_by as string}`)
            ).rows[0] as Row | undefined;
            return b ? { id: b.id as string, name: b.name as string } : null;
          })
        : Promise.resolve(null),
    ]);
    return {
      ...base,
      currency: r.currency as string,
      countryName: countryOf(r.country as string).name,
      suspendedAt: iso(r.suspended_at),
      suspendedReason: (r.suspended_reason as string) ?? null,
      deletedAt: iso(r.deleted_at),
      purgeAt: r.deleted_at
        ? new Date(new Date(r.deleted_at as string).getTime() + GRACE_DAYS * DAY).toISOString()
        : null,
      referralCode: (r.referral_code as string) ?? null,
      referredBy: referrer,
      referrals,
      members,
      locations,
      payments,
      actions,
    };
  }

  // ─────────────────────────────── gestes de l'équipe

  private async record(adminId: string, businessId: string, action: string, details: Record<string, unknown>) {
    await this.dbs.transaction((tx) =>
      tx.execute(sql`
        INSERT INTO core.admin_actions (id, admin_id, business_id, action, details)
        VALUES (${newId()}, ${adminId}, ${businessId}, ${action}, ${JSON.stringify(details)}::jsonb)`),
    );
  }

  private async mustExist(id: string, alive = true) {
    const b = (
      await this.dbs.transaction((tx) =>
        tx.execute(sql`SELECT id, name, deleted_at, suspended_at FROM core.businesses WHERE id = ${id}`),
      )
    ).rows[0] as Row | undefined;
    if (!b) throw AppError.notFound('Boutique');
    if (alive && b.deleted_at) throw AppError.conflict('Boutique supprimée : restaurez-la d’abord');
    return b;
  }

  async gift(adminId: string, id: string, days: number, reason: string | null) {
    await this.mustExist(id);
    const r = await this.billing.gift(id, days, reason);
    await this.record(adminId, id, 'gift', { days, reason });
    return r;
  }

  async suspend(adminId: string, id: string, reason: string) {
    const b = await this.mustExist(id);
    if (b.suspended_at) throw AppError.conflict('Déjà suspendue');
    await this.dbs.transaction((tx) =>
      tx.execute(sql`UPDATE core.businesses SET suspended_at = now(), suspended_reason = ${reason} WHERE id = ${id}`),
    );
    await this.record(adminId, id, 'suspend', { reason });
    return { suspended: true };
  }

  async unsuspend(adminId: string, id: string) {
    const b = await this.mustExist(id);
    if (!b.suspended_at) throw AppError.conflict('Pas suspendue');
    await this.dbs.transaction((tx) =>
      tx.execute(sql`UPDATE core.businesses SET suspended_at = NULL, suspended_reason = NULL WHERE id = ${id}`),
    );
    await this.record(adminId, id, 'unsuspend', {});
    return { suspended: false };
  }

  /** Rétablir une boutique supprimée (pendant les 30 jours), à la demande du commerçant. */
  async restore(adminId: string, id: string) {
    const b = await this.mustExist(id, false);
    if (!b.deleted_at) throw AppError.conflict('Pas supprimée');
    const owner = (
      await this.dbs.transaction((tx) => tx.execute(sql`SELECT owner_id FROM core.businesses WHERE id = ${id}`))
    ).rows[0] as Row;
    const r = await this.closure.restoreBusiness(owner.owner_id as string, id);
    await this.record(adminId, id, 'restore', {});
    return r;
  }

  // ─────────────────────────────── paiements

  /** Paiements Pro : en ligne (Chariow) et par transfert (validés, à valider, refusés). */
  async payments(q: {
    source?: 'online' | 'manual';
    status?: string;
    businessId?: string;
    page?: number;
    pageSize?: number;
  }) {
    const size = Math.min(Math.max(q.pageSize ?? 30, 1), 100);
    const page = Math.max(q.page ?? 1, 1);
    const biz = q.businessId ? sql`AND p.business_id = ${q.businessId}` : sql``;
    const rows = (
      await this.dbs.transaction((tx) =>
        tx.execute(sql`
          SELECT * FROM (
            SELECT 'online' AS source, o.id, o.business_id, o.cycle, coalesce(o.amount, 0) AS amount, o.currency,
                   'chariow' AS method, o.sale_id AS reference,
                   CASE o.status WHEN 'paid' THEN 'paid' WHEN 'failed' THEN 'failed' ELSE 'pending' END AS status,
                   o.created_at, o.paid_at AS settled_at, NULL::text AS note
            FROM core.online_payments o
            UNION ALL
            SELECT 'manual', r.id, r.business_id, r.cycle, r.amount, r.currency, r.method, r.reference,
                   CASE r.status WHEN 'approved' THEN 'paid' WHEN 'rejected' THEN 'rejected' ELSE 'to_check' END,
                   r.created_at, r.decided_at, r.note
            FROM core.subscription_requests r
          ) p
          JOIN core.businesses b ON b.id = p.business_id
          WHERE true ${biz}
            ${q.source ? sql`AND p.source = ${q.source}` : sql``}
            ${q.status ? sql`AND p.status = ${q.status}` : sql``}
            -- Paiements en ligne abandonnés avant la page de paiement : sans intérêt
            AND NOT (p.source = 'online' AND p.status = 'pending' AND p.created_at < now() - interval '1 day')
          ORDER BY coalesce(p.settled_at, p.created_at) DESC
          LIMIT ${size + 1} OFFSET ${(page - 1) * size}`),
      )
    ).rows as Row[];
    const names = new Map<string, string>();
    for (const b of (await this.dbs.transaction((tx) => tx.execute(sql`SELECT id, name FROM core.businesses`)))
      .rows as Row[]) {
      names.set(b.id as string, b.name as string);
    }
    return {
      page,
      pageSize: size,
      hasMore: rows.length > size,
      items: rows.slice(0, size).map((p) => ({
        id: p.id as string,
        source: p.source as 'online' | 'manual',
        businessId: p.business_id as string,
        businessName: names.get(p.business_id as string) ?? '—',
        cycle: p.cycle as 'monthly' | 'yearly',
        amount: Number(p.amount) || PRO_PRICES[p.cycle as 'monthly' | 'yearly'],
        currency: (p.currency as string) ?? 'XOF',
        method: p.method as string,
        reference: (p.reference as string) ?? null,
        status: p.status as 'paid' | 'pending' | 'to_check' | 'rejected' | 'failed',
        createdAt: iso(p.created_at)!,
        settledAt: iso(p.settled_at),
        note: (p.note as string) ?? null,
      })),
    };
  }

  // ─────────────────────────────── tableau de bord

  async overview(days = 30, now = new Date()) {
    const from = new Date(now.getTime() - days * DAY);
    const [rows, stats] = await Promise.all([this.baseRows(), this.allStats()]);
    const alive = rows.filter((r) => !r.deleted_at).map((r) => this.summary(r, stats.get(r.id as string)));

    const plans = { trial: 0, active: 0, expired: 0, free: 0 };
    for (const b of alive) plans[b.plan.state]++;

    const paid = (
      await this.dbs.transaction((tx) =>
        tx.execute(sql`
          SELECT business_id, cycle, coalesce(amount, 0)::bigint AS amount, paid_at AS at, 'online' AS source
          FROM core.online_payments WHERE status = 'paid'
          UNION ALL
          SELECT business_id, cycle, amount::bigint, decided_at, 'manual'
          FROM core.subscription_requests WHERE status = 'approved'`),
      )
    ).rows as Row[];
    const amountOf = (p: Row) => Number(p.amount) || PRO_PRICES[p.cycle as 'monthly' | 'yearly'];
    const inPeriod = paid.filter((p) => new Date(p.at as string) >= from);
    // Revenu mensuel récurrent : chaque boutique Pro payante, au prix de son dernier paiement (l'année / 12)
    const lastCycle = new Map<string, string>();
    for (const p of [...paid].sort((a, b) => String(a.at).localeCompare(String(b.at)))) {
      lastCycle.set(p.business_id as string, p.cycle as string);
    }
    const mrr = alive
      .filter((b) => b.plan.state === 'active')
      .reduce((sum, b) => sum + (lastCycle.get(b.id) === 'yearly' ? PRO_PRICES.yearly / 12 : PRO_PRICES.monthly), 0);

    const series = (dates: Date[], values?: number[]) => {
      const m = new Map<string, number>();
      for (let i = days - 1; i >= 0; i--) m.set(dayKey(new Date(now.getTime() - i * DAY)), 0);
      dates.forEach((d, i) => {
        const k = dayKey(d);
        if (m.has(k)) m.set(k, m.get(k)! + (values ? values[i] : 1));
      });
      return [...m].map(([date, value]) => ({ date, value }));
    };
    const signups = rows.map((r) => new Date(r.created_at as string));
    const prevFrom = new Date(from.getTime() - days * DAY);

    const byCountry = new Map<string, number>();
    for (const b of alive) byCountry.set(b.country, (byCountry.get(b.country) ?? 0) + 1);

    const pending = (
      await this.dbs.transaction((tx) =>
        tx.execute(sql`SELECT count(*)::int AS n FROM core.subscription_requests WHERE status = 'pending'`),
      )
    ).rows[0] as Row;
    const users = (
      await this.dbs.transaction((tx) =>
        tx.execute(sql`SELECT count(*)::int AS n FROM core.users WHERE deleted_at IS NULL AND status <> 'deleted'`),
      )
    ).rows[0] as Row;

    const activeShops = alive.filter((b) => b.stats.sales7 > 0).length;
    const withSales = alive.filter((b) => b.stats.lastSaleAt).length;
    return {
      days,
      generatedAt: now.toISOString(),
      businesses: {
        total: alive.length,
        new: signups.filter((d) => d >= from).length,
        newPrevious: signups.filter((d) => d >= prevFrom && d < from).length,
        active7: activeShops,
        everSold: withSales,
        suspended: alive.filter((b) => b.status === 'suspended').length,
        deleted: rows.length - alive.length,
      },
      users: Number(users.n),
      plans,
      // Essais qui se terminent dans les 7 jours : à relancer
      trialsEnding: alive
        .filter((b) => b.plan.state === 'trial' && b.plan.daysLeft <= 7)
        .sort((a, b) => a.plan.daysLeft - b.plan.daysLeft)
        .slice(0, 8)
        .map((b) => ({ id: b.id, name: b.name, ownerPhone: b.owner.phone, daysLeft: b.plan.daysLeft })),
      revenue: {
        period: inPeriod.reduce((s, p) => s + amountOf(p), 0),
        previous: paid
          .filter((p) => new Date(p.at as string) >= prevFrom && new Date(p.at as string) < from)
          .reduce((s, p) => s + amountOf(p), 0),
        allTime: paid.reduce((s, p) => s + amountOf(p), 0),
        mrr: Math.round(mrr),
        online: inPeriod.filter((p) => p.source === 'online').reduce((s, p) => s + amountOf(p), 0),
        manual: inPeriod.filter((p) => p.source === 'manual').reduce((s, p) => s + amountOf(p), 0),
        payments: inPeriod.length,
      },
      pendingPayments: Number(pending.n),
      merchantsGmv30: alive.reduce((s, b) => s + b.stats.revenue30, 0),
      merchantsSales30: alive.reduce((s, b) => s + b.stats.sales30, 0),
      signupsByDay: series(signups),
      revenueByDay: series(
        inPeriod.map((p) => new Date(p.at as string)),
        inPeriod.map(amountOf),
      ),
      countries: [...byCountry]
        .map(([code, count]) => ({ code, name: countryOf(code).name, count }))
        .sort((a, b) => b.count - a.count),
      topBusinesses: [...alive]
        .sort((a, b) => b.stats.revenue30 - a.stats.revenue30)
        .slice(0, 6)
        .filter((b) => b.stats.revenue30 > 0)
        .map((b) => ({
          id: b.id,
          name: b.name,
          country: b.country,
          revenue30: b.stats.revenue30,
          sales30: b.stats.sales30,
        })),
      latest: alive.slice(0, 6).map((b) => ({
        id: b.id,
        name: b.name,
        country: b.country,
        ownerName: b.owner.name,
        createdAt: b.createdAt,
        plan: b.plan.state,
      })),
    };
  }
}
