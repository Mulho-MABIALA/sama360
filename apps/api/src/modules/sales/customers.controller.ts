import { Body, Controller, Get, Param, ParseUUIDPipe, Post, Query } from '@nestjs/common';
import { z } from 'zod';
import { AuthUser, TenantContext } from '../../shared/auth/auth.types';
import { CurrentTenant, CurrentUser, RequireModule, RequirePermission } from '../../shared/auth/decorators';
import { parse } from '../../shared/http/zod';
import { CustomersService } from './customers.service';
import { RemindersService } from './reminders.service';

const ListCustomers = z.object({
  search: z.string().trim().max(80).optional(),
  filter: z.enum(['all', 'debt', 'over_limit']).default('all'),
  sort: z.enum(['name', 'balance', 'recent']).default('name'),
  limit: z.coerce.number().int().min(1).max(100).default(50),
  offset: z.coerce.number().int().min(0).max(100_000).default(0),
});
const Adjustment = z.object({
  amount: z.coerce
    .number()
    .int()
    .min(-1_000_000_000_000)
    .max(1_000_000_000_000)
    .refine((n) => n !== 0, 'Le montant ne peut pas être nul'),
  reason: z.string().trim().min(3).max(300),
});
const Reminder = z.object({ channel: z.enum(['whatsapp', 'sms', 'call']).default('whatsapp') });

/** Clients et crédit : annuaire avec soldes, fiche client, ajustements et rappels. */
@Controller('v1/customers')
@RequireModule('sales')
export class CustomersController {
  constructor(
    private readonly customers: CustomersService,
    private readonly reminders: RemindersService,
  ) {}

  @Get()
  @RequirePermission('contacts:read')
  list(@CurrentTenant() t: TenantContext, @Query() query: unknown) {
    return this.customers.list(t.businessId, parse(ListCustomers, query));
  }

  @Get(':id')
  @RequirePermission('contacts:read')
  overview(@CurrentTenant() t: TenantContext, @Param('id', ParseUUIDPipe) id: string) {
    return this.customers.overview(t.businessId, id);
  }

  /** Reprise d'une ancienne dette ou remise de dette : réservé au gérant et au propriétaire. */
  @Post(':id/adjustments')
  @RequirePermission('sales:void')
  adjust(
    @CurrentTenant() t: TenantContext,
    @CurrentUser() user: AuthUser,
    @Param('id', ParseUUIDPipe) id: string,
    @Body() body: unknown,
  ) {
    return this.customers.adjust(t.businessId, user.id, id, parse(Adjustment, body), t.warehouseId);
  }

  @Post(':id/reminders')
  @RequirePermission('contacts:write')
  async remind(
    @CurrentTenant() t: TenantContext,
    @CurrentUser() u: AuthUser,
    @Param('id', ParseUUIDPipe) id: string,
    @Body() body: unknown,
  ) {
    const { channel } = parse(Reminder, body ?? {});
    const r = await this.reminders.record(t.businessId, u.id, t.permissions, { kind: 'credit', id, channel });
    return { lastRemindedAt: r.lastRemindedAt };
  }
}
