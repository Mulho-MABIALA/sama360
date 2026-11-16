import { Body, Controller, Get, HttpCode, Param, ParseUUIDPipe, Patch, Post, Query, Res } from '@nestjs/common';
import { and, desc, eq, ilike, inArray, lt, or, SQL, sql } from 'drizzle-orm';
import type { Response } from 'express';
import { z } from 'zod';
import { AuthUser, TenantContext } from '../../shared/auth/auth.types';
import { CurrentTenant, CurrentUser, RequireModule, RequirePermission } from '../../shared/auth/decorators';
import { DbService } from '../../shared/db/db.service';
import { contacts, documents } from '../../shared/db/schema';
import { AppError } from '../../shared/http/app-error';
import { PageQuery, parse } from '../../shared/http/zod';
import { isOverdue, InvoicingService } from './invoicing.service';

const amount = z.coerce.number().int().min(0).max(1_000_000_000_000);
const day = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Date attendue : AAAA-MM-JJ');

const Line = z.object({
  productId: z.string().uuid().nullish(),
  name: z.string().trim().min(1).max(160).optional(),
  description: z.string().trim().max(500).nullish(),
  quantity: z.coerce.number().positive().max(1_000_000),
  unitPrice: amount.optional(),
  discount: amount.optional(),
});

const DocumentBody = z.object({
  customerId: z.string().uuid(),
  lines: z.array(Line).min(1).max(200),
  discount: amount.optional(),
  issueDate: day.optional(),
  dueDate: day.nullish(),
  note: z.string().trim().max(1000).nullish(),
});
const CreateDocument = DocumentBody.extend({
  id: z.string().uuid().optional(),
  kind: z.enum(['quote', 'invoice']),
});

const Payment = z.object({
  id: z.string().uuid().optional(),
  amount: z.coerce.number().int().positive().max(1_000_000_000_000),
  method: z.enum(['cash', 'wave', 'orange_money', 'free_money', 'card', 'transfer', 'cheque']),
  reference: z.string().trim().max(80).nullish(),
  paidAt: z.coerce.date().optional(),
});

const ListDocuments = PageQuery.extend({
  kind: z.enum(['quote', 'invoice']).optional(),
  status: z.string().max(40).optional(), // un ou plusieurs statuts séparés par des virgules
  customerId: z.string().uuid().optional(),
  search: z.string().trim().max(80).optional(),
  overdue: z.enum(['true', 'false']).optional(),
});

const today = () => new Date().toISOString().slice(0, 10);

@Controller('v1/invoicing')
@RequireModule('invoicing')
export class InvoicingController {
  constructor(
    private readonly dbs: DbService,
    private readonly invoicing: InvoicingService,
  ) {}

  @Post('documents')
  @RequirePermission('invoicing:write')
  async create(
    @CurrentTenant() t: TenantContext,
    @CurrentUser() user: AuthUser,
    @Body() body: unknown,
    @Res({ passthrough: true }) res: Response,
  ) {
    const r = await this.invoicing.create(t.businessId, user.id, parse(CreateDocument, body));
    res.status(r.created ? 201 : 200);
    return r.document;
  }

  @Get('documents')
  @RequirePermission('invoicing:read')
  list(@CurrentTenant() t: TenantContext, @Query() query: unknown) {
    const q = parse(ListDocuments, query);
    return this.dbs.withTenant(t.businessId, async (tx) => {
      const where: SQL[] = [];
      if (q.kind) where.push(eq(documents.kind, q.kind));
      if (q.status) where.push(inArray(documents.status, q.status.split(',') as never[]));
      if (q.customerId) where.push(eq(documents.customerId, q.customerId));
      if (q.search) where.push(or(ilike(documents.number, `%${q.search}%`), ilike(contacts.name, `%${q.search}%`))!);
      if (q.overdue === 'true') {
        where.push(sql`${documents.status} IN ('unpaid', 'partial') AND ${documents.dueDate} < ${today()}::date`);
      }
      if (q.cursor) where.push(lt(documents.id, q.cursor));
      const rows = await tx
        .select({
          id: documents.id,
          kind: documents.kind,
          number: documents.number,
          status: documents.status,
          customerId: documents.customerId,
          customerName: contacts.name,
          issueDate: documents.issueDate,
          dueDate: documents.dueDate,
          total: documents.total,
          paid: documents.paid,
        })
        .from(documents)
        .innerJoin(contacts, eq(contacts.id, documents.customerId))
        .where(where.length ? and(...where) : undefined)
        .orderBy(desc(documents.id))
        .limit(q.limit + 1);
      const hasMore = rows.length > q.limit;
      const data = rows.slice(0, q.limit).map((r) => ({ ...r, due: r.total - r.paid, overdue: isOverdue(r) }));
      return { data, nextCursor: hasMore ? data[data.length - 1].id : null };
    });
  }

  /** Tableau de bord : à encaisser, en retard, devis en attente, facturé ce mois-ci. */
  @Get('summary')
  @RequirePermission('invoicing:read')
  summary(@CurrentTenant() t: TenantContext) {
    const d = today();
    const monthStart = `${d.slice(0, 7)}-01`;
    return this.dbs.withTenant(t.businessId, async (tx) => {
      const r = (
        await tx.execute(sql`
          SELECT
            coalesce(sum(total - paid) FILTER (WHERE kind = 'invoice' AND status IN ('unpaid', 'partial')), 0)::bigint AS receivable,
            count(*) FILTER (WHERE kind = 'invoice' AND status IN ('unpaid', 'partial'))::int AS open_count,
            coalesce(sum(total - paid) FILTER (WHERE kind = 'invoice' AND status IN ('unpaid', 'partial') AND due_date < ${d}::date), 0)::bigint AS overdue,
            count(*) FILTER (WHERE kind = 'invoice' AND status IN ('unpaid', 'partial') AND due_date < ${d}::date)::int AS overdue_count,
            coalesce(sum(total) FILTER (WHERE kind = 'quote' AND status IN ('pending', 'accepted')), 0)::bigint AS quotes_open,
            count(*) FILTER (WHERE kind = 'quote' AND status IN ('pending', 'accepted'))::int AS quotes_open_count,
            coalesce(sum(total) FILTER (WHERE kind = 'invoice' AND status <> 'cancelled' AND issue_date >= ${monthStart}::date), 0)::bigint AS invoiced_month
          FROM invoicing.documents`)
      ).rows[0] as Record<string, string | number>;
      return {
        receivable: Number(r.receivable),
        openInvoices: Number(r.open_count),
        overdue: Number(r.overdue),
        overdueInvoices: Number(r.overdue_count),
        openQuotesTotal: Number(r.quotes_open),
        openQuotes: Number(r.quotes_open_count),
        invoicedThisMonth: Number(r.invoiced_month),
      };
    });
  }

  @Get('documents/:id')
  @RequirePermission('invoicing:read')
  async get(@CurrentTenant() t: TenantContext, @Param('id', ParseUUIDPipe) id: string) {
    const doc = await this.dbs.withTenant(t.businessId, (tx) => this.invoicing.findFull(tx, id));
    if (!doc) throw AppError.notFound('Document');
    return doc;
  }

  @Patch('documents/:id')
  @RequirePermission('invoicing:write')
  update(@CurrentTenant() t: TenantContext, @Param('id', ParseUUIDPipe) id: string, @Body() body: unknown) {
    return this.invoicing.updateQuote(t.businessId, id, parse(DocumentBody, body));
  }

  @Post('documents/:id/accept')
  @HttpCode(200)
  @RequirePermission('invoicing:write')
  accept(@CurrentTenant() t: TenantContext, @Param('id', ParseUUIDPipe) id: string) {
    return this.invoicing.setQuoteStatus(t.businessId, id, 'accepted');
  }

  @Post('documents/:id/decline')
  @HttpCode(200)
  @RequirePermission('invoicing:write')
  decline(@CurrentTenant() t: TenantContext, @Param('id', ParseUUIDPipe) id: string) {
    return this.invoicing.setQuoteStatus(t.businessId, id, 'declined');
  }

  @Post('documents/:id/reopen')
  @HttpCode(200)
  @RequirePermission('invoicing:write')
  reopen(@CurrentTenant() t: TenantContext, @Param('id', ParseUUIDPipe) id: string) {
    return this.invoicing.setQuoteStatus(t.businessId, id, 'pending');
  }

  /** Devis → facture. */
  @Post('documents/:id/convert')
  @RequirePermission('invoicing:write')
  async convert(
    @CurrentTenant() t: TenantContext,
    @CurrentUser() user: AuthUser,
    @Param('id', ParseUUIDPipe) id: string,
    @Body() body: unknown,
    @Res({ passthrough: true }) res: Response,
  ) {
    const input = parse(z.object({ dueDate: day.nullish() }), body ?? {});
    const r = await this.invoicing.convert(t.businessId, user.id, id, input);
    res.status(r.created ? 201 : 200);
    return r.document;
  }

  @Post('documents/:id/payments')
  @RequirePermission('invoicing:write')
  async pay(
    @CurrentTenant() t: TenantContext,
    @CurrentUser() user: AuthUser,
    @Param('id', ParseUUIDPipe) id: string,
    @Body() body: unknown,
    @Res({ passthrough: true }) res: Response,
  ) {
    const r = await this.invoicing.addPayment(t.businessId, user.id, id, parse(Payment, body));
    res.status(r.created ? 201 : 200);
    return r.document;
  }

  @Post('documents/:id/cancel')
  @HttpCode(200)
  @RequirePermission('invoicing:write')
  cancel(
    @CurrentTenant() t: TenantContext,
    @CurrentUser() user: AuthUser,
    @Param('id', ParseUUIDPipe) id: string,
    @Body() body: unknown,
  ) {
    const { reason } = parse(z.object({ reason: z.string().trim().min(3).max(300) }), body);
    return this.invoicing.cancel(t.businessId, user.id, id, reason);
  }
}
