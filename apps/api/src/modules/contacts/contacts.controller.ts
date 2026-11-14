import { Body, Controller, Delete, Get, HttpCode, Param, ParseUUIDPipe, Patch, Post, Query } from '@nestjs/common';
import { and, desc, eq, ilike, isNull, lt, or, SQL } from 'drizzle-orm';
import { z } from 'zod';
import { AuthUser, TenantContext } from '../../shared/auth/auth.types';
import { CurrentTenant, CurrentUser, RequirePermission } from '../../shared/auth/decorators';
import { DbService } from '../../shared/db/db.service';
import { contacts } from '../../shared/db/schema';
import { OutboxService } from '../../shared/events/outbox.service';
import { AppError } from '../../shared/http/app-error';
import { PageQuery, parse } from '../../shared/http/zod';
import { newId } from '../../shared/ids';
import { normalizePhone } from '../../shared/phone';

const ContactInput = z.object({
  type: z.enum(['customer', 'supplier', 'both']).default('customer'),
  name: z.string().trim().min(1).max(120),
  phone: z.string().max(25).nullish(),
  email: z.string().email().max(160).nullish(),
  address: z.string().max(500).nullish(),
  notes: z.string().max(2000).nullish(),
});
const ListQuery = PageQuery.extend({
  search: z.string().trim().max(80).optional(),
  type: z.enum(['customer', 'supplier', 'both']).optional(),
});

function cleanPhone(phone: string | null | undefined): string | null | undefined {
  if (phone === undefined || phone === null || phone === '') return phone === '' ? null : phone;
  const normalized = normalizePhone(phone);
  if (!normalized) throw new AppError('PHONE_INVALID', 'Numéro de téléphone invalide', 422);
  return normalized;
}

/** Annuaire partagé clients / fournisseurs. Toutes les requêtes passent par la RLS. */
@Controller('v1/contacts')
export class ContactsController {
  constructor(
    private readonly dbs: DbService,
    private readonly outbox: OutboxService,
  ) {}

  @Get()
  @RequirePermission('contacts:read')
  list(@CurrentTenant() t: TenantContext, @Query() query: unknown) {
    const q = parse(ListQuery, query);
    return this.dbs.withTenant(t.businessId, async (tx) => {
      const where: SQL[] = [isNull(contacts.deletedAt)];
      if (q.type) where.push(eq(contacts.type, q.type));
      if (q.cursor) where.push(lt(contacts.id, q.cursor));
      if (q.search) {
        where.push(or(ilike(contacts.name, `%${q.search}%`), ilike(contacts.phone, `%${q.search}%`))!);
      }
      const rows = await tx
        .select()
        .from(contacts)
        .where(and(...where))
        .orderBy(desc(contacts.id))
        .limit(q.limit + 1);
      const hasMore = rows.length > q.limit;
      const data = rows.slice(0, q.limit);
      return { data, nextCursor: hasMore ? data[data.length - 1].id : null };
    });
  }

  @Post()
  @RequirePermission('contacts:write')
  create(@CurrentTenant() t: TenantContext, @CurrentUser() user: AuthUser, @Body() body: unknown) {
    const input = parse(ContactInput, body);
    const phone = cleanPhone(input.phone) ?? null;
    return this.dbs.withTenant(t.businessId, async (tx) => {
      const [contact] = await tx
        .insert(contacts)
        .values({ ...input, phone, id: newId(), businessId: t.businessId })
        .returning();
      await this.outbox.record(tx, {
        type: 'contact.created',
        businessId: t.businessId,
        aggregateId: contact.id,
        actorId: user.id,
        payload: { contactId: contact.id, type: contact.type, name: contact.name, phone: contact.phone },
      });
      return contact;
    });
  }

  @Get(':id')
  @RequirePermission('contacts:read')
  get(@CurrentTenant() t: TenantContext, @Param('id', ParseUUIDPipe) id: string) {
    return this.dbs.withTenant(t.businessId, async (tx) => {
      const [contact] = await tx
        .select()
        .from(contacts)
        .where(and(eq(contacts.id, id), isNull(contacts.deletedAt)))
        .limit(1);
      if (!contact) throw AppError.notFound('Contact');
      return contact;
    });
  }

  @Patch(':id')
  @RequirePermission('contacts:write')
  update(@CurrentTenant() t: TenantContext, @Param('id', ParseUUIDPipe) id: string, @Body() body: unknown) {
    const input = parse(ContactInput.partial(), body);
    const phone = cleanPhone(input.phone);
    return this.dbs.withTenant(t.businessId, async (tx) => {
      const [current] = await tx
        .select({ version: contacts.version })
        .from(contacts)
        .where(and(eq(contacts.id, id), isNull(contacts.deletedAt)))
        .limit(1);
      if (!current) throw AppError.notFound('Contact');
      const [contact] = await tx
        .update(contacts)
        .set({ ...input, ...(phone !== undefined ? { phone } : {}), version: current.version + 1, updatedAt: new Date() })
        .where(eq(contacts.id, id))
        .returning();
      return contact;
    });
  }

  @Delete(':id')
  @HttpCode(204)
  @RequirePermission('contacts:write')
  async remove(@CurrentTenant() t: TenantContext, @Param('id', ParseUUIDPipe) id: string) {
    await this.dbs.withTenant(t.businessId, async (tx) => {
      const res = await tx
        .update(contacts)
        .set({ deletedAt: new Date(), updatedAt: new Date() })
        .where(and(eq(contacts.id, id), isNull(contacts.deletedAt)))
        .returning({ id: contacts.id });
      if (res.length === 0) throw AppError.notFound('Contact');
    });
  }
}
