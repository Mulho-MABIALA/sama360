import { Controller, Get, Query } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { z } from 'zod';
import { TenantContext } from '../../shared/auth/auth.types';
import { CurrentTenant, RequireModule, RequirePermission } from '../../shared/auth/decorators';
import { DbService, Tx } from '../../shared/db/db.service';
import { atLocation } from '../../shared/tenant/location';
import { AppError, proRequired } from '../../shared/http/app-error';
import { FREE_LIMITS, freeHistoryStart } from '../../shared/plans';
import { parse } from '../../shared/http/zod';
import {
  bucketsOf,
  changePct,
  DAY_MS,
  dayStart,
  granularity,
  MAX_REPORT_DAYS,
  previousPeriod,
  spanDays,
} from './reports';

const day = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'format AAAA-MM-JJ');
const Period = z.object({ from: day, to: day });

type Row = Record<string, string | number | null>;
const n = (v: unknown) => Number(v ?? 0);

/** Rapports : chiffres d'une période, comparés à la période précédente de même durée. */
@Controller('v1/reports')
@RequireModule('sales')
export class ReportsController {
  constructor(private readonly dbs: DbService) {}

  @Get('overview')
  @RequirePermission('reports:read')
  overview(@CurrentTenant() t: TenantContext, @Query() query: unknown) {
    const { from, to } = parse(Period, query);
    if (to < from) throw new AppError('VALIDATION_FAILED', 'La date de fin précède la date de début', 422);
    if (spanDays(from, to) > MAX_REPORT_DAYS) {
      throw new AppError('VALIDATION_FAILED', `Période trop longue (${MAX_REPORT_DAYS} jours maximum)`, 422);
    }
    // Gratuit : les 30 derniers jours ; au-delà, c'est Pro
    if (!t.pro && from < freeHistoryStart()) {
      throw proRequired(
        'history',
        `Version gratuite : rapports des ${FREE_LIMITS.historyDays} derniers jours. Passez à Pro pour tout votre historique`,
        { days: FREE_LIMITS.historyDays },
      );
    }
    const prev = previousPeriod(from, to);
    const g = granularity(from, to);

    return this.dbs.withTenant(t.businessId, async (tx) => {
      const [cur, before] = await Promise.all([this.totals(tx, from, to, t), this.totals(tx, prev.from, prev.to, t)]);
      const start = dayStart(from);
      const end = new Date(dayStart(to).getTime() + DAY_MS);
      const bucket = g === 'day' ? sql`to_char(sold_at, 'YYYY-MM-DD')` : sql`to_char(sold_at, 'YYYY-MM')`;

      const seriesRows = (
        await tx.execute(sql`
          SELECT ${bucket} AS bucket, count(*)::int AS count,
                 coalesce(sum(total), 0)::bigint AS revenue,
                 coalesce(sum(total - cost_total), 0)::bigint AS profit
          FROM sales.sales
          WHERE status = 'completed' AND sold_at >= ${start} AND sold_at < ${end} ${atLocation(t, 'warehouse_id')}
          GROUP BY 1`)
      ).rows as Row[];
      const byBucket = new Map(seriesRows.map((r) => [String(r.bucket), r]));
      const series = bucketsOf(from, to, g).map((b) => {
        const r = byBucket.get(b);
        return { period: b, salesCount: n(r?.count), revenue: n(r?.revenue), grossProfit: n(r?.profit) };
      });

      const byMethod = (
        await tx.execute(sql`
          SELECT p.method, coalesce(sum(p.amount), 0)::bigint AS amount, count(DISTINCT s.id)::int AS count
          FROM sales.sale_payments p JOIN sales.sales s ON s.id = p.sale_id
          WHERE s.status = 'completed' AND s.sold_at >= ${start} AND s.sold_at < ${end} ${atLocation(t, 's.warehouse_id')}
          GROUP BY p.method ORDER BY 2 DESC`)
      ).rows as Row[];

      const topProducts = (
        await tx.execute(sql`
          SELECT i.product_id, i.name, sum(i.quantity) AS quantity, sum(i.total)::bigint AS revenue,
                 sum(i.total - round(i.quantity * i.unit_cost))::bigint AS profit
          FROM sales.sale_items i JOIN sales.sales s ON s.id = i.sale_id
          WHERE s.status = 'completed' AND s.sold_at >= ${start} AND s.sold_at < ${end} ${atLocation(t, 's.warehouse_id')}
          GROUP BY i.product_id, i.name ORDER BY revenue DESC LIMIT 10`)
      ).rows as Row[];

      const sellers = (
        await tx.execute(sql`
          SELECT s.cashier_id, coalesce(u.full_name, u.phone) AS name, count(*)::int AS count,
                 coalesce(sum(s.total), 0)::bigint AS revenue
          FROM sales.sales s JOIN core.users u ON u.id = s.cashier_id
          WHERE s.status = 'completed' AND s.sold_at >= ${start} AND s.sold_at < ${end} ${atLocation(t, 's.warehouse_id')}
          GROUP BY s.cashier_id, u.full_name, u.phone ORDER BY revenue DESC`)
      ).rows as Row[];

      const expenses = (
        await tx.execute(sql`
          SELECT category, coalesce(sum(amount), 0)::bigint AS amount, count(*)::int AS count
          FROM sales.expenses WHERE spent_at >= ${from}::date AND spent_at <= ${to}::date
            ${atLocation(t, 'warehouse_id')}
          GROUP BY category ORDER BY 2 DESC`)
      ).rows as Row[];

      const invoices = (
        await tx.execute(sql`
          SELECT
            (SELECT coalesce(sum(total), 0) FROM invoicing.documents
              WHERE kind = 'invoice' AND status <> 'cancelled' AND issue_date >= ${from}::date AND issue_date <= ${to}::date)::bigint AS invoiced,
            (SELECT count(*) FROM invoicing.documents
              WHERE kind = 'invoice' AND status <> 'cancelled' AND issue_date >= ${from}::date AND issue_date <= ${to}::date)::int AS count,
            (SELECT coalesce(sum(amount), 0) FROM invoicing.payments
              WHERE paid_at >= ${start} AND paid_at < ${end})::bigint AS received`)
      ).rows[0] as Row;

      return {
        period: { from, to, days: spanDays(from, to), granularity: g },
        previous: { ...prev, revenue: before.revenue, netProfit: before.netProfit, salesCount: before.salesCount },
        ...cur,
        change: {
          revenue: changePct(cur.revenue, before.revenue),
          netProfit: changePct(cur.netProfit, before.netProfit),
          salesCount: changePct(cur.salesCount, before.salesCount),
        },
        series,
        byMethod: byMethod.map((m) => ({ method: m.method, amount: n(m.amount), salesCount: n(m.count) })),
        topProducts: topProducts.map((p) => ({
          productId: p.product_id,
          name: p.name,
          quantity: n(p.quantity),
          revenue: n(p.revenue),
          grossProfit: n(p.profit),
        })),
        bySeller: sellers.map((v) => ({
          userId: v.cashier_id,
          name: v.name,
          salesCount: n(v.count),
          revenue: n(v.revenue),
        })),
        expensesByCategory: expenses.map((e) => ({ category: e.category, amount: n(e.amount), count: n(e.count) })),
        invoices: { invoiced: n(invoices.invoiced), count: n(invoices.count), received: n(invoices.received) },
      };
    });
  }

  /** Totaux d'une période : chiffre d'affaires, coût, bénéfices, dépenses, encaissé, crédit. */
  private async totals(tx: Tx, from: string, to: string, t: Pick<TenantContext, 'locationFilter'>) {
    const start = dayStart(from);
    const end = new Date(dayStart(to).getTime() + DAY_MS);
    const s = (
      await tx.execute(sql`
        SELECT count(*)::int AS count,
               coalesce(sum(total), 0)::bigint AS revenue,
               coalesce(sum(cost_total), 0)::bigint AS cost,
               coalesce(sum(paid), 0)::bigint AS collected,
               coalesce(sum(total - paid), 0)::bigint AS on_credit,
               coalesce(sum(discount), 0)::bigint AS discounts
        FROM sales.sales
        WHERE status = 'completed' AND sold_at >= ${start} AND sold_at < ${end} ${atLocation(t, 'warehouse_id')}`)
    ).rows[0] as Row;
    const voided = (
      await tx.execute(sql`
        SELECT count(*)::int AS count FROM sales.sales
        WHERE status = 'voided' AND sold_at >= ${start} AND sold_at < ${end} ${atLocation(t, 'warehouse_id')}`)
    ).rows[0] as Row;
    const e = (
      await tx.execute(sql`
        SELECT coalesce(sum(amount), 0)::bigint AS total FROM sales.expenses
        WHERE spent_at >= ${from}::date AND spent_at <= ${to}::date ${atLocation(t, 'warehouse_id')}`)
    ).rows[0] as Row;
    const revenue = n(s.revenue);
    const cost = n(s.cost);
    const expenses = n(e.total);
    const salesCount = n(s.count);
    return {
      salesCount,
      voidedCount: n(voided.count),
      revenue,
      cost,
      grossProfit: revenue - cost,
      expenses,
      netProfit: revenue - cost - expenses,
      collected: n(s.collected),
      onCredit: n(s.on_credit),
      discounts: n(s.discounts),
      averageBasket: salesCount === 0 ? 0 : Math.round(revenue / salesCount),
      marginRate: revenue === 0 ? 0 : Math.round(((revenue - cost) / revenue) * 1000) / 10,
    };
  }
}
