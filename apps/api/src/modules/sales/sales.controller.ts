import { Body, Controller, Get, HttpCode, Param, ParseUUIDPipe, Post, Query, Res } from '@nestjs/common';
import { and, desc, eq, gte, lt, SQL, sql } from 'drizzle-orm';
import type { Response } from 'express';
import { z } from 'zod';
import { AuthUser, TenantContext } from '../../shared/auth/auth.types';
import { CurrentTenant, CurrentUser, RequireModule, RequirePermission } from '../../shared/auth/decorators';
import { DbService } from '../../shared/db/db.service';
import { contacts, customerLedger, expenses, sales } from '../../shared/db/schema';
import { AppError } from '../../shared/http/app-error';
import { PageQuery, parse } from '../../shared/http/zod';
import { SalesService } from './sales.service';

const amount = z.coerce.number().int().min(0).max(1_000_000_000_000);
const positive = z.coerce.number().int().min(1).max(1_000_000_000_000);
const method = z.enum(['cash', 'wave', 'orange_money', 'free_money', 'card']);
const day = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'format AAAA-MM-JJ');

const CreateSale = z.object({
  id: z.string().uuid().optional(),
  customerId: z.string().uuid().nullish(),
  items: z
    .array(
      z.object({
        productId: z.string().uuid().nullish(),
        name: z.string().trim().min(1).max(160).optional(),
        quantity: z.coerce.number().positive().max(1_000_000),
        unitPrice: amount.optional(),
        discount: amount.optional(),
      }),
    )
    .min(1)
    .max(200),
  discount: amount.optional(),
  payments: z
    .array(z.object({ method, amount: positive, reference: z.string().max(80).nullish() }))
    .max(10)
    .default([]),
  soldAt: z.coerce.date().optional(),
  note: z.string().max(500).nullish(),
});

const VoidSale = z.object({ reason: z.string().trim().min(3).max(500) });
const Repayment = z.object({ amount: positive, method, note: z.string().max(500).nullish() });
const Expense = z.object({
  category: z.string().trim().min(2).max(40),
  amount: positive,
  method: method.nullish(),
  note: z.string().max(500).nullish(),
  spentAt: day.optional(),
});
const ListSales = PageQuery.extend({
  from: day.optional(),
  to: day.optional(),
  customerId: z.string().uuid().optional(),
  status: z.enum(['completed', 'voided']).optional(),
});
const Period = z.object({ from: day.optional(), to: day.optional() });

const today = () => new Date().toISOString().slice(0, 10); // Dakar = UTC+0
const startOf = (d: string) => new Date(`${d}T00:00:00Z`);
const endOf = (d: string) => new Date(startOf(d).getTime() + 24 * 3600 * 1000);

@Controller('v1/sales')
@RequireModule('sales')
export class SalesController {
  constructor(
    private readonly dbs: DbService,
    private readonly salesService: SalesService,
  ) {}

  /** Encaisser une vente. 201 si créée, 200 si l'id existait déjà (renvoi hors ligne). */
  @Post()
  @RequirePermission('sales:create')
  async create(
    @CurrentTenant() t: TenantContext,
    @CurrentUser() user: AuthUser,
    @Body() body: unknown,
    @Res({ passthrough: true }) res: Response,
  ) {
    const input = parse(CreateSale, body);
    const result = await this.salesService.create(t.businessId, user.id, input);
    res.status(result.created ? 201 : 200);
    return result.sale;
  }

  @Get()
  @RequirePermission('sales:read')
  list(@CurrentTenant() t: TenantContext, @Query() query: unknown) {
    const q = parse(ListSales, query);
    return this.dbs.withTenant(t.businessId, async (tx) => {
      const where: SQL[] = [];
      if (q.from) where.push(gte(sales.soldAt, startOf(q.from)));
      if (q.to) where.push(lt(sales.soldAt, endOf(q.to)));
      if (q.customerId) where.push(eq(sales.customerId, q.customerId));
      if (q.status) where.push(eq(sales.status, q.status));
      if (q.cursor) where.push(lt(sales.id, q.cursor));
      const rows = await tx
        .select({
          id: sales.id,
          number: sales.number,
          status: sales.status,
          customerId: sales.customerId,
          customerName: contacts.name,
          total: sales.total,
          paid: sales.paid,
          soldAt: sales.soldAt,
        })
        .from(sales)
        .leftJoin(contacts, eq(contacts.id, sales.customerId))
        .where(where.length ? and(...where) : undefined)
        .orderBy(desc(sales.id))
        .limit(q.limit + 1);
      const hasMore = rows.length > q.limit;
      const data = rows.slice(0, q.limit).map((r) => ({ ...r, due: r.total - r.paid }));
      return { data, nextCursor: hasMore ? data[data.length - 1].id : null };
    });
  }

  /** Résumé de la période (aujourd'hui par défaut) : écran d'accueil et tableau de bord. */
  @Get('summary')
  @RequirePermission('reports:read')
  summary(@CurrentTenant() t: TenantContext, @Query() query: unknown) {
    const q = parse(Period, query);
    const from = q.from ?? today();
    const to = q.to ?? from;
    if (startOf(to) < startOf(from)) throw new AppError('VALIDATION_FAILED', 'La date de fin précède la date de début', 422);
    const [start, end] = [startOf(from), endOf(to)];

    return this.dbs.withTenant(t.businessId, async (tx) => {
      const totals = (
        await tx.execute(sql`
          SELECT count(*)::int AS count,
                 coalesce(sum(total), 0)::bigint AS revenue,
                 coalesce(sum(cost_total), 0)::bigint AS cost,
                 coalesce(sum(paid), 0)::bigint AS collected,
                 coalesce(sum(total - paid), 0)::bigint AS on_credit
          FROM sales.sales
          WHERE status = 'completed' AND sold_at >= ${start} AND sold_at < ${end}`)
      ).rows[0] as Record<string, string | number>;

      const byMethod = (
        await tx.execute(sql`
          SELECT p.method, coalesce(sum(p.amount), 0)::bigint AS amount
          FROM sales.sale_payments p JOIN sales.sales s ON s.id = p.sale_id
          WHERE s.status = 'completed' AND s.sold_at >= ${start} AND s.sold_at < ${end}
          GROUP BY p.method ORDER BY 2 DESC`)
      ).rows as { method: string; amount: string }[];

      const exp = (
        await tx.execute(sql`
          SELECT coalesce(sum(amount), 0)::bigint AS total FROM sales.expenses
          WHERE spent_at >= ${from}::date AND spent_at <= ${to}::date`)
      ).rows[0] as { total: string };

      const top = (
        await tx.execute(sql`
          SELECT i.product_id, i.name, sum(i.quantity) AS quantity, sum(i.total)::bigint AS revenue
          FROM sales.sale_items i JOIN sales.sales s ON s.id = i.sale_id
          WHERE s.status = 'completed' AND s.sold_at >= ${start} AND s.sold_at < ${end}
          GROUP BY i.product_id, i.name ORDER BY revenue DESC LIMIT 5`)
      ).rows as { product_id: string | null; name: string; quantity: string; revenue: string }[];

      const receivables = (
        await tx.execute(sql`SELECT coalesce(sum(amount), 0)::bigint AS total FROM sales.customer_ledger`)
      ).rows[0] as { total: string };

      const revenue = Number(totals.revenue);
      const cost = Number(totals.cost);
      const expensesTotal = Number(exp.total);
      return {
        period: { from, to },
        salesCount: Number(totals.count),
        revenue,
        cost,
        grossProfit: revenue - cost,
        expenses: expensesTotal,
        netProfit: revenue - cost - expensesTotal,
        collected: Number(totals.collected),
        onCredit: Number(totals.on_credit),
        receivables: Number(receivables.total), // total dû par tous les clients, toutes périodes
        byMethod: byMethod.map((m) => ({ method: m.method, amount: Number(m.amount) })),
        topProducts: top.map((p) => ({
          productId: p.product_id,
          name: p.name,
          quantity: Number(p.quantity),
          revenue: Number(p.revenue),
        })),
      };
    });
  }

  /** Clients qui doivent de l'argent, du plus gros solde au plus petit. */
  @Get('debtors')
  @RequirePermission('sales:read')
  debtors(@CurrentTenant() t: TenantContext) {
    return this.dbs.withTenant(t.businessId, async (tx) => {
      const rows = await tx.execute(sql`
        SELECT c.id, c.name, c.phone, sum(l.amount)::bigint AS balance, max(l.occurred_at) AS last_entry_at,
               min(l.occurred_at) FILTER (WHERE l.entry_type = 'debt') AS first_debt_at
        FROM sales.customer_ledger l JOIN contacts.contacts c ON c.id = l.customer_id
        GROUP BY c.id, c.name, c.phone
        HAVING sum(l.amount) > 0
        ORDER BY balance DESC`);
      return (rows.rows as Record<string, unknown>[]).map((r) => ({
        customerId: r.id,
        name: r.name,
        phone: r.phone,
        balance: Number(r.balance),
        firstDebtAt: r.first_debt_at,
        lastEntryAt: r.last_entry_at,
      }));
    });
  }

  @Get('customers/:customerId/ledger')
  @RequirePermission('sales:read')
  ledger(@CurrentTenant() t: TenantContext, @Param('customerId', ParseUUIDPipe) customerId: string) {
    return this.dbs.withTenant(t.businessId, async (tx) => {
      const [customer] = await tx
        .select({ id: contacts.id, name: contacts.name, phone: contacts.phone })
        .from(contacts)
        .where(eq(contacts.id, customerId))
        .limit(1);
      if (!customer) throw AppError.notFound('Client');
      const entries = await tx
        .select()
        .from(customerLedger)
        .where(eq(customerLedger.customerId, customerId))
        .orderBy(desc(customerLedger.occurredAt), desc(customerLedger.id))
        .limit(200);
      return {
        customer,
        balance: await this.salesService.balance(tx, customerId),
        entries: entries.map(({ businessId: _b, ...e }) => e),
      };
    });
  }

  @Post('customers/:customerId/repayments')
  @RequirePermission('sales:create')
  repay(
    @CurrentTenant() t: TenantContext,
    @CurrentUser() user: AuthUser,
    @Param('customerId', ParseUUIDPipe) customerId: string,
    @Body() body: unknown,
  ) {
    return this.salesService.recordRepayment(t.businessId, user.id, customerId, parse(Repayment, body));
  }

  @Get('expenses')
  @RequirePermission('reports:read')
  listExpenses(@CurrentTenant() t: TenantContext, @Query() query: unknown) {
    const q = parse(Period, query);
    return this.dbs.withTenant(t.businessId, async (tx) => {
      const where: SQL[] = [];
      if (q.from) where.push(gte(expenses.spentAt, q.from));
      if (q.to) where.push(sql`${expenses.spentAt} <= ${q.to}::date`);
      return tx
        .select()
        .from(expenses)
        .where(where.length ? and(...where) : undefined)
        .orderBy(desc(expenses.spentAt), desc(expenses.id))
        .limit(500);
    });
  }

  @Post('expenses')
  @RequirePermission('sales:create')
  addExpense(@CurrentTenant() t: TenantContext, @CurrentUser() user: AuthUser, @Body() body: unknown) {
    const input = parse(Expense, body);
    return this.salesService.recordExpense(t.businessId, user.id, { ...input, spentAt: input.spentAt ?? today() });
  }

  @Get(':id')
  @RequirePermission('sales:read')
  get(@CurrentTenant() t: TenantContext, @Param('id', ParseUUIDPipe) id: string) {
    return this.dbs.withTenant(t.businessId, async (tx) => {
      const sale = await this.salesService.findFull(tx, id);
      if (!sale) throw AppError.notFound('Vente');
      return sale;
    });
  }

  @Post(':id/void')
  @HttpCode(200)
  @RequirePermission('sales:void')
  void(
    @CurrentTenant() t: TenantContext,
    @CurrentUser() user: AuthUser,
    @Param('id', ParseUUIDPipe) id: string,
    @Body() body: unknown,
  ) {
    return this.salesService.void(t.businessId, user.id, id, parse(VoidSale, body).reason);
  }
}
