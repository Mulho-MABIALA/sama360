import { Body, Controller, Get, HttpCode, Param, ParseUUIDPipe, Post, Query, Res } from '@nestjs/common';
import { and, desc, eq, gte, lt, SQL, sql } from 'drizzle-orm';
import type { Response } from 'express';
import { hasPermission } from '@sama360/contracts';
import { z } from 'zod';
import { AuthUser, TenantContext, locationFor } from '../../shared/auth/auth.types';
import { CurrentTenant, CurrentUser, RequireModule, RequirePermission } from '../../shared/auth/decorators';
import { DbService } from '../../shared/db/db.service';
import { contacts, customerLedger, expenses, sales, users } from '../../shared/db/schema';
import { AppError } from '../../shared/http/app-error';
import { atLocation, unpaidByCustomer } from '../../shared/tenant/location';
import { PageQuery, parse } from '../../shared/http/zod';
import { freeHistoryStart } from '../../shared/plans';
import { SalesService } from './sales.service';

const amount = z.coerce.number().int().min(0).max(1_000_000_000_000);
const positive = z.coerce.number().int().min(1).max(1_000_000_000_000);
const method = z.enum(['cash', 'wave', 'orange_money', 'free_money', 'mtn_momo', 'moov_money', 'airtel_money', 'card']);
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
        // Restaurant : suppléments choisis ; téléphonie : un IMEI / numéro de série par unité
        extras: z.array(z.string().trim().min(1).max(40)).max(20).optional(),
        serials: z.array(z.string().trim().min(3).max(40)).max(500).optional(),
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
  redeemRewards: z.coerce.number().int().min(0).max(100).optional(),
  /** Point de vente de la vente (vente hors ligne envoyée plus tard depuis une autre boutique). */
  locationId: z.string().uuid().nullish(),
});

const VoidSale = z.object({ reason: z.string().trim().min(3).max(500) });
const RejectVoid = z.object({ reason: z.string().trim().max(500).nullish() });
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
  cashierId: z.string().uuid().optional(),
  /** « true » : seulement mes ventes (vendeur connecté). */
  mine: z.enum(['true', 'false']).optional(),
  status: z.enum(['completed', 'voided']).optional(),
  /** « pending » : ventes dont le vendeur demande l'annulation. */
  voidRequest: z.enum(['pending']).optional(),
  /** Numéro du reçu : « 42 », « 0042 » ou « VEN-2026-0042 ». */
  number: z.string().trim().min(1).max(30).optional(),
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
    // Remises : réservées à ceux qui fixent les prix (propriétaire, gérant)
    const discounted = (input.discount ?? 0) > 0 || input.items.some((i) => (i.discount ?? 0) > 0);
    if (discounted && !hasPermission(t.permissions, 'catalog:write')) {
      throw AppError.forbidden('Seuls le propriétaire et le gérant peuvent accorder une remise');
    }
    const result = await this.salesService.create(t.businessId, user.id, {
      ...input,
      locationId: locationFor(t, input.locationId),
    });
    res.status(result.created ? 201 : 200);
    return result.sale;
  }

  @Get()
  @RequirePermission('sales:read')
  list(@CurrentTenant() t: TenantContext, @CurrentUser() user: AuthUser, @Query() query: unknown) {
    const q = parse(ListSales, query);
    return this.dbs.withTenant(t.businessId, async (tx) => {
      const where: SQL[] = [];
      if (q.cashierId) where.push(eq(sales.cashierId, q.cashierId));
      if (q.mine === 'true') where.push(eq(sales.cashierId, user.id));
      if (q.from) where.push(gte(sales.soldAt, startOf(q.from)));
      // Gratuit : la liste des ventes s'arrête aux 30 derniers jours (les crédits restent tous visibles ailleurs)
      if (!t.pro) where.push(gte(sales.soldAt, startOf(freeHistoryStart())));
      if (q.to) where.push(lt(sales.soldAt, endOf(q.to)));
      if (q.customerId) where.push(eq(sales.customerId, q.customerId));
      if (q.status) where.push(eq(sales.status, q.status));
      if (q.voidRequest) where.push(and(eq(sales.voidRequestStatus, 'pending'), eq(sales.status, 'completed'))!);
      if (q.number) {
        // Que des chiffres : la fin du numéro (« 42 » → …-0042) ; sinon le numéro complet ou une partie
        const digits = /^\d+$/.test(q.number) ? q.number.replace(/^0+(?=\d)/, '') : null;
        where.push(
          digits
            ? sql`${sales.number} ~ ${`-0*${digits}$`}`
            : sql`${sales.number} ILIKE ${`%${q.number.replace(/[%_\\]/g, '')}%`}`,
        );
      }
      if (q.cursor) where.push(lt(sales.id, q.cursor));
      if (t.locationFilter) where.push(eq(sales.warehouseId, t.locationFilter));
      // Sans accès aux rapports (vendeur), on ne voit que ses propres ventes
      if (!hasPermission(t.permissions, 'reports:read')) where.push(eq(sales.cashierId, user.id));
      const rows = await tx
        .select({
          id: sales.id,
          number: sales.number,
          status: sales.status,
          customerId: sales.customerId,
          customerName: contacts.name,
          cashierId: sales.cashierId,
          cashierName: sql<string | null>`coalesce(${users.fullName}, ${users.phone})`,
          total: sales.total,
          paid: sales.paid,
          soldAt: sales.soldAt,
          locationId: sales.warehouseId,
          voidRequestStatus: sales.voidRequestStatus,
          voidRequestReason: sales.voidRequestReason,
          // Pour titrer la vente dans la liste : « Savon noir + 2 autres »
          firstItem: sql<
            string | null
          >`(SELECT si.name FROM sales.sale_items si WHERE si.sale_id = ${sales.id} ORDER BY si.id LIMIT 1)`,
          itemCount: sql<number>`(SELECT count(*)::int FROM sales.sale_items si WHERE si.sale_id = ${sales.id})`,
        })
        .from(sales)
        .leftJoin(contacts, eq(contacts.id, sales.customerId))
        .leftJoin(users, eq(users.id, sales.cashierId))
        .where(where.length ? and(...where) : undefined)
        .orderBy(desc(sales.id))
        .limit(q.limit + 1);
      const hasMore = rows.length > q.limit;
      const data = rows.slice(0, q.limit).map((r) => ({ ...r, due: r.total - r.paid }));
      return { data, nextCursor: hasMore ? data[data.length - 1].id : null };
    });
  }

  /** Téléphonie : la vente d'un appareil par son IMEI / numéro de série (garantie, retour). */
  @Get('by-serial/:serial')
  @RequirePermission('sales:read')
  bySerial(@CurrentTenant() t: TenantContext, @Param('serial') serial: string) {
    const code = serial.trim().slice(0, 40);
    return this.dbs.withTenant(t.businessId, async (tx) => {
      const [row] = (
        await tx.execute(sql`
          SELECT s.id, s.number, s.sold_at, s.status, i.name, i.unit_price, i.warranty_until::text AS warranty_until,
                 c.name AS customer_name, c.phone AS customer_phone
          FROM sales.sale_items i
          JOIN sales.sales s ON s.id = i.sale_id
          LEFT JOIN contacts.contacts c ON c.id = s.customer_id
          WHERE i.serials @> ARRAY[${code}]::text[]
          ORDER BY s.sold_at DESC LIMIT 1`)
      ).rows as Record<string, unknown>[];
      if (!row) throw new AppError('NOT_FOUND', `Aucune vente avec le numéro ${code}`, 404);
      const until = row.warranty_until as string | null;
      return {
        saleId: row.id,
        number: row.number,
        soldAt: row.sold_at,
        status: row.status,
        product: row.name,
        price: Number(row.unit_price),
        customerName: row.customer_name ?? null,
        customerPhone: row.customer_phone ?? null,
        warrantyUntil: until,
        underWarranty: until !== null && until >= new Date().toISOString().slice(0, 10),
      };
    });
  }

  /** Résumé de la période (aujourd'hui par défaut) : écran d'accueil et tableau de bord. */
  @Get('summary')
  @RequirePermission('reports:read')
  summary(@CurrentTenant() t: TenantContext, @Query() query: unknown) {
    const q = parse(Period, query);
    const from = q.from ?? today();
    const to = q.to ?? from;
    if (startOf(to) < startOf(from))
      throw new AppError('VALIDATION_FAILED', 'La date de fin précède la date de début', 422);
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
          WHERE status = 'completed' AND sold_at >= ${start} AND sold_at < ${end} ${atLocation(t, 'warehouse_id')}`)
      ).rows[0] as Record<string, string | number>;

      const byMethod = (
        await tx.execute(sql`
          SELECT p.method, coalesce(sum(p.amount), 0)::bigint AS amount
          FROM sales.sale_payments p JOIN sales.sales s ON s.id = p.sale_id
          WHERE s.status = 'completed' AND s.sold_at >= ${start} AND s.sold_at < ${end} ${atLocation(t, 's.warehouse_id')}
          GROUP BY p.method ORDER BY 2 DESC`)
      ).rows as { method: string; amount: string }[];

      const exp = (
        await tx.execute(sql`
          SELECT coalesce(sum(amount), 0)::bigint AS total FROM sales.expenses
          WHERE spent_at >= ${from}::date AND spent_at <= ${to}::date ${atLocation(t, 'warehouse_id')}`)
      ).rows[0] as { total: string };

      const top = (
        await tx.execute(sql`
          SELECT i.product_id, i.name, sum(i.quantity) AS quantity, sum(i.total)::bigint AS revenue
          FROM sales.sale_items i JOIN sales.sales s ON s.id = i.sale_id
          WHERE s.status = 'completed' AND s.sold_at >= ${start} AND s.sold_at < ${end} ${atLocation(t, 's.warehouse_id')}
          GROUP BY i.product_id, i.name ORDER BY revenue DESC LIMIT 5`)
      ).rows as { product_id: string | null; name: string; quantity: string; revenue: string }[];

      // Ventes par vendeur (le nom, à défaut le numéro de téléphone)
      const sellers = (
        await tx.execute(sql`
          SELECT s.cashier_id, coalesce(u.full_name, u.phone) AS name, u.avatar_file_id,
                 count(*)::int AS count, coalesce(sum(s.total), 0)::bigint AS revenue
          FROM sales.sales s JOIN core.users u ON u.id = s.cashier_id
          WHERE s.status = 'completed' AND s.sold_at >= ${start} AND s.sold_at < ${end} ${atLocation(t, 's.warehouse_id')}
          GROUP BY s.cashier_id, u.full_name, u.phone, u.avatar_file_id ORDER BY revenue DESC`)
      ).rows as { cashier_id: string; name: string; avatar_file_id: string | null; count: number; revenue: string }[];

      const receivables = (
        await tx.execute(sql`SELECT coalesce(sum(unpaid), 0)::bigint AS total FROM ${unpaidByCustomer(t)} u`)
      ).rows[0] as { total: string };

      // Courbe de l'accueil : chiffre d'affaires des 7 derniers jours (jusqu'à « to »)
      // et total des 7 jours d'avant, pour la tendance.
      const week = (
        await tx.execute(sql`
          SELECT to_char(d, 'YYYY-MM-DD') AS day, coalesce(sum(s.total), 0)::bigint AS revenue
          FROM generate_series(${to}::date - 6, ${to}::date, interval '1 day') d
          LEFT JOIN sales.sales s
            ON s.status = 'completed' AND s.sold_at >= d AND s.sold_at < d + interval '1 day'
              ${atLocation(t, 's.warehouse_id')}
          GROUP BY d ORDER BY d`)
      ).rows as { day: string; revenue: string }[];
      const prevWeek = (
        await tx.execute(sql`
          SELECT coalesce(sum(total), 0)::bigint AS revenue FROM sales.sales
          WHERE status = 'completed' AND sold_at >= ${to}::date - 13 AND sold_at < ${to}::date - 6
            ${atLocation(t, 'warehouse_id')}`)
      ).rows[0] as { revenue: string };

      // Tous les points de vente : la part de chacun sur la période
      const byLocation = (
        await tx.execute(sql`
          SELECT w.id, w.name, count(s.id)::int AS count, coalesce(sum(s.total), 0)::bigint AS revenue
          FROM inventory.warehouses w
          LEFT JOIN sales.sales s ON s.warehouse_id = w.id AND s.status = 'completed'
            AND s.sold_at >= ${start} AND s.sold_at < ${end}
          WHERE w.archived_at IS NULL ${atLocation(t, 'w.id')}
          GROUP BY w.id, w.name, w.is_default ORDER BY w.is_default DESC, w.name`)
      ).rows as { id: string; name: string; count: number; revenue: string }[];

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
        // Total dû par les clients, toutes périodes (dans le point de vente choisi : la part de ses dettes)
        receivables: Number(receivables.total),
        byMethod: byMethod.map((m) => ({ method: m.method, amount: Number(m.amount) })),
        bySeller: sellers.map((v) => ({
          userId: v.cashier_id,
          name: v.name,
          avatarFileId: v.avatar_file_id,
          salesCount: Number(v.count),
          revenue: Number(v.revenue),
        })),
        last7Days: week.map((d) => ({ date: d.day, revenue: Number(d.revenue) })),
        previous7DaysRevenue: Number(prevWeek.revenue),
        locationId: t.locationFilter,
        byLocation: byLocation.map((l) => ({
          locationId: l.id,
          name: l.name,
          salesCount: Number(l.count),
          revenue: Number(l.revenue),
        })),
        topProducts: top.map((p) => ({
          productId: p.product_id,
          name: p.name,
          quantity: Number(p.quantity),
          revenue: Number(p.revenue),
        })),
      };
    });
  }

  /** Ma journée de vendeur : nombre de ventes et montant (sans coûts ni bénéfices). */
  @Get('my-day')
  @RequirePermission('sales:create')
  myDay(@CurrentTenant() t: TenantContext, @CurrentUser() user: AuthUser) {
    const [start, end] = [startOf(today()), endOf(today())];
    return this.dbs.withTenant(t.businessId, async (tx) => {
      const row = (
        await tx.execute(sql`
          SELECT count(*)::int AS count,
                 coalesce(sum(total), 0)::bigint AS revenue,
                 coalesce(sum(paid), 0)::bigint AS collected
          FROM sales.sales
          WHERE status = 'completed' AND cashier_id = ${user.id} AND sold_at >= ${start} AND sold_at < ${end}`)
      ).rows[0] as { count: number; revenue: string; collected: string };
      return {
        date: today(),
        salesCount: Number(row.count),
        revenue: Number(row.revenue),
        collected: Number(row.collected),
      };
    });
  }

  /** Clients qui doivent de l'argent, du plus gros solde au plus petit. */
  @Get('debtors')
  @RequirePermission('sales:read')
  debtors(@CurrentTenant() t: TenantContext) {
    return this.dbs.withTenant(t.businessId, async (tx) => {
      const rows = await tx.execute(sql`
        SELECT c.id, c.name, c.phone, u.unpaid AS balance, max(l.occurred_at) AS last_entry_at,
               min(l.occurred_at) FILTER (WHERE l.entry_type = 'debt') AS first_debt_at
        FROM ${unpaidByCustomer(t)} u
        JOIN contacts.contacts c ON c.id = u.customer_id
        JOIN sales.customer_ledger l ON l.customer_id = u.customer_id
        GROUP BY c.id, c.name, c.phone, u.unpaid
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
    return this.salesService.recordRepayment(t.businessId, user.id, customerId, parse(Repayment, body), t.warehouseId);
  }

  @Get('expenses')
  @RequirePermission('reports:read')
  listExpenses(@CurrentTenant() t: TenantContext, @Query() query: unknown) {
    const q = parse(Period, query);
    return this.dbs.withTenant(t.businessId, async (tx) => {
      const where: SQL[] = [];
      if (t.locationFilter) where.push(eq(expenses.warehouseId, t.locationFilter));
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
    return this.salesService.recordExpense(
      t.businessId,
      user.id,
      { ...input, spentAt: input.spentAt ?? today() },
      t.warehouseId,
    );
  }

  @Get(':id')
  @RequirePermission('sales:read')
  get(@CurrentTenant() t: TenantContext, @CurrentUser() user: AuthUser, @Param('id', ParseUUIDPipe) id: string) {
    return this.dbs.withTenant(t.businessId, async (tx) => {
      const sale = await this.salesService.findFull(tx, id);
      if (!sale) throw AppError.notFound('Vente');
      // Un vendeur ne consulte que ses ventes (le reçu d'une vente d'un collègue reste privé)
      if (!hasPermission(t.permissions, 'reports:read') && sale.cashierId !== user.id) throw AppError.notFound('Vente');
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

  /** Le vendeur demande l'annulation d'une de ses ventes (le gérant décide). */
  @Post(':id/void-request')
  @HttpCode(200)
  @RequirePermission('sales:create')
  requestVoid(
    @CurrentTenant() t: TenantContext,
    @CurrentUser() user: AuthUser,
    @Param('id', ParseUUIDPipe) id: string,
    @Body() body: unknown,
  ) {
    const own = !hasPermission(t.permissions, 'reports:read');
    return this.salesService.requestVoid(t.businessId, user.id, id, parse(VoidSale, body).reason, own);
  }

  /** Le gérant refuse la demande : la vente reste valable. */
  @Post(':id/void-request/reject')
  @HttpCode(200)
  @RequirePermission('sales:void')
  rejectVoid(
    @CurrentTenant() t: TenantContext,
    @CurrentUser() user: AuthUser,
    @Param('id', ParseUUIDPipe) id: string,
    @Body() body: unknown,
  ) {
    return this.salesService.rejectVoid(t.businessId, user.id, id, parse(RejectVoid, body ?? {}).reason ?? null);
  }
}
