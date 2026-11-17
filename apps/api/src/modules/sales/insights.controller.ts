import { Controller, Get, Query } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { z } from 'zod';
import { TenantContext } from '../../shared/auth/auth.types';
import { CurrentTenant, RequireModule, RequirePermission } from '../../shared/auth/decorators';
import { DbService, Tx } from '../../shared/db/db.service';
import { parse } from '../../shared/http/zod';
import {
  bestWeekday,
  DEFAULT_INSIGHT_DAYS,
  fillHours,
  fillWeekdays,
  HourStat,
  LOW_MARGIN_RATE,
  marginRate,
  peakWindow,
  WeekdayStat,
  weeklyReportText,
  weekOf,
} from './insights';
import { changePct, DAY_MS, dayStart, toDay } from './reports';

type Row = Record<string, string | number | null>;
const n = (v: unknown) => Number(v ?? 0);
const day = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'format AAAA-MM-JJ');

const InsightsQuery = z.object({
  days: z.coerce.number().int().min(7).max(365).default(DEFAULT_INSIGHT_DAYS),
});
const WeeklyQuery = z.object({ week: day.optional() });

/** Analyses : produits qui dorment, heures de pointe, marge par produit, rapport de la semaine. */
@Controller('v1/reports')
@RequireModule('sales')
export class InsightsController {
  constructor(private readonly dbs: DbService) {}

  @Get('insights')
  @RequirePermission('reports:read')
  insights(@CurrentTenant() t: TenantContext, @Query() query: unknown) {
    const { days } = parse(InsightsQuery, query);
    const end = new Date(
      Date.UTC(new Date().getUTCFullYear(), new Date().getUTCMonth(), new Date().getUTCDate()) + DAY_MS,
    );
    const start = new Date(end.getTime() - days * DAY_MS);
    return this.dbs.withTenant(t.businessId, async (tx) => {
      const [dormant, rhythm, margins] = await Promise.all([
        this.dormant(tx, days),
        this.rhythm(tx, start, end),
        this.margins(tx, start, end),
      ]);
      return {
        period: { from: toDay(start), to: toDay(new Date(end.getTime() - DAY_MS)), days },
        dormant,
        ...rhythm,
        margins,
      };
    });
  }

  @Get('weekly')
  @RequirePermission('reports:read')
  weekly(@CurrentTenant() t: TenantContext, @Query() query: unknown) {
    const { week } = parse(WeeklyQuery, query);
    const { from, to } = weekOf(week);
    const start = dayStart(from);
    const end = new Date(dayStart(to).getTime() + DAY_MS);
    const prevStart = new Date(start.getTime() - 7 * DAY_MS);
    return this.dbs.withTenant(t.businessId, async (tx) => {
      const biz = (await tx.execute(sql`SELECT name FROM core.businesses WHERE id = ${t.businessId}`)).rows[0] as Row;
      const totals = async (a: Date, b: Date) =>
        (
          await tx.execute(sql`
            SELECT count(*)::int AS count, coalesce(sum(total), 0)::bigint AS revenue,
                   coalesce(sum(cost_total), 0)::bigint AS cost
            FROM sales.sales WHERE status = 'completed' AND sold_at >= ${a} AND sold_at < ${b}`)
        ).rows[0] as Row;
      const [cur, prev, rhythm, margins, dormant] = await Promise.all([
        totals(start, end),
        totals(prevStart, start),
        this.rhythm(tx, start, end),
        this.margins(tx, start, end),
        this.dormant(tx, 30),
      ]);
      const exp = (
        await tx.execute(sql`
          SELECT coalesce(sum(amount), 0)::bigint AS total FROM sales.expenses
          WHERE spent_at >= ${from}::date AND spent_at <= ${to}::date`)
      ).rows[0] as Row;
      const owe = (
        await tx.execute(sql`
          SELECT coalesce(sum(balance), 0)::bigint AS due FROM contacts.contacts
          WHERE deleted_at IS NULL AND balance > 0`)
      ).rows[0] as Row;

      const revenue = n(cur.revenue);
      const best = bestWeekday(rhythm.byWeekday);
      const report = {
        businessName: String(biz?.name ?? 'Ma boutique'),
        from,
        to,
        salesCount: n(cur.count),
        revenue,
        netProfit: revenue - n(cur.cost) - n(exp.total),
        revenueChange: changePct(revenue, n(prev.revenue)),
        bestDay: best ? { weekday: best.weekday, revenue: best.revenue } : null,
        peak: rhythm.peak,
        topProducts: [...margins.products]
          .sort((a, b) => b.revenue - a.revenue)
          .slice(0, 3)
          .map((p) => ({ name: p.name, quantity: p.quantity, revenue: p.revenue })),
        dormant: {
          count: dormant.count,
          stockValue: dormant.stockValue,
          names: dormant.items.slice(0, 3).map((d) => d.name),
        },
        lowMargin: margins.lowMargin.slice(0, 3).map((p) => ({ name: p.name, marginRate: p.marginRate })),
        customersOwe: n(owe.due),
      };
      return { ...report, text: weeklyReportText(report) };
    });
  }

  /** Produits en stock sans aucune vente depuis `days` jours (créés avant), triés par argent immobilisé. */
  private async dormant(tx: Tx, days: number) {
    const rows = (
      await tx.execute(sql`
        WITH stock AS (
          SELECT product_id, sum(on_hand) AS on_hand FROM inventory.stock_levels GROUP BY product_id
        ), last_sale AS (
          SELECT i.product_id, max(s.sold_at) AS last_sold
          FROM sales.sale_items i JOIN sales.sales s ON s.id = i.sale_id
          WHERE s.status = 'completed' AND i.product_id IS NOT NULL
          GROUP BY i.product_id
        )
        SELECT p.id, p.name, p.cost, st.on_hand, ls.last_sold
        FROM catalog.products p
        JOIN stock st ON st.product_id = p.id
        LEFT JOIN last_sale ls ON ls.product_id = p.id
        WHERE p.deleted_at IS NULL AND p.type = 'product' AND p.track_stock AND st.on_hand > 0
          AND p.created_at < now() - make_interval(days => ${days})
          AND (ls.last_sold IS NULL OR ls.last_sold < now() - make_interval(days => ${days}))
        ORDER BY st.on_hand * p.cost DESC, p.name
        LIMIT 200`)
    ).rows as Row[];
    const now = Date.now();
    const items = rows.map((r) => {
      const last = r.last_sold ? new Date(String(r.last_sold)) : null;
      return {
        productId: String(r.id),
        name: String(r.name),
        onHand: n(r.on_hand),
        stockValue: Math.round(n(r.on_hand) * n(r.cost)),
        lastSoldAt: last ? last.toISOString() : null,
        daysSinceSale: last ? Math.floor((now - last.getTime()) / DAY_MS) : null,
      };
    });
    return {
      days,
      count: items.length,
      stockValue: items.reduce((s, i) => s + i.stockValue, 0),
      items: items.slice(0, 30),
    };
  }

  /** Rythme des ventes : par heure, par jour de la semaine (heure de Dakar). */
  private async rhythm(tx: Tx, start: Date, end: Date) {
    const local = sql`(sold_at AT TIME ZONE 'Africa/Dakar')`;
    const hours = (
      await tx.execute(sql`
        SELECT extract(hour FROM ${local})::int AS hour, count(*)::int AS count, coalesce(sum(total), 0)::bigint AS revenue
        FROM sales.sales WHERE status = 'completed' AND sold_at >= ${start} AND sold_at < ${end}
        GROUP BY 1`)
    ).rows as Row[];
    const days = (
      await tx.execute(sql`
        SELECT extract(isodow FROM ${local})::int AS weekday, count(*)::int AS count, coalesce(sum(total), 0)::bigint AS revenue
        FROM sales.sales WHERE status = 'completed' AND sold_at >= ${start} AND sold_at < ${end}
        GROUP BY 1`)
    ).rows as Row[];
    const byHour: HourStat[] = fillHours(
      hours.map((h) => ({ hour: n(h.hour), salesCount: n(h.count), revenue: n(h.revenue) })),
    );
    const byWeekday: WeekdayStat[] = fillWeekdays(
      days.map((d) => ({ weekday: n(d.weekday), salesCount: n(d.count), revenue: n(d.revenue) })),
    );
    const best = bestWeekday(byWeekday);
    return { byHour, byWeekday, peak: peakWindow(byHour), bestWeekday: best?.weekday ?? null };
  }

  /** Marge par produit sur la période : ce qui rapporte vraiment, et ce qui se vend presque à perte. */
  private async margins(tx: Tx, start: Date, end: Date) {
    const rows = (
      await tx.execute(sql`
        SELECT i.product_id, i.name, sum(i.quantity) AS quantity, sum(i.total)::bigint AS revenue,
               sum(round(i.quantity * i.unit_cost))::bigint AS cost,
               bool_or(i.unit_cost = 0) AS unknown_cost
        FROM sales.sale_items i JOIN sales.sales s ON s.id = i.sale_id
        WHERE s.status = 'completed' AND s.sold_at >= ${start} AND s.sold_at < ${end}
        GROUP BY i.product_id, i.name
        ORDER BY sum(i.total - round(i.quantity * i.unit_cost)) DESC
        LIMIT 100`)
    ).rows as Row[];
    const products = rows.map((r) => {
      const revenue = n(r.revenue);
      const cost = n(r.cost);
      const costKnown = !(String(r.unknown_cost) === 'true');
      return {
        productId: r.product_id ? String(r.product_id) : null,
        name: String(r.name),
        quantity: n(r.quantity),
        revenue,
        cost,
        profit: revenue - cost,
        marginRate: costKnown ? marginRate(revenue, cost) : null,
        costKnown,
      };
    });
    const revenue = products.reduce((s, p) => s + p.revenue, 0);
    const known = products.filter((p) => p.costKnown);
    const lowMargin = known
      .filter((p) => p.marginRate !== null && p.marginRate < LOW_MARGIN_RATE)
      .sort((a, b) => (a.marginRate ?? 0) - (b.marginRate ?? 0));
    return {
      revenue,
      profit: known.reduce((s, p) => s + p.profit, 0),
      marginRate: marginRate(
        known.reduce((s, p) => s + p.revenue, 0),
        known.reduce((s, p) => s + p.cost, 0),
      ),
      lowMarginThreshold: LOW_MARGIN_RATE,
      unknownCostCount: products.length - known.length,
      products,
      lowMargin,
    };
  }
}
