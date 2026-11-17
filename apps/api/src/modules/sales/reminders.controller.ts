import { Body, Controller, Get, Post } from '@nestjs/common';
import { z } from 'zod';
import { AuthUser, TenantContext } from '../../shared/auth/auth.types';
import { CurrentTenant, CurrentUser, RequireModule, RequirePermission } from '../../shared/auth/decorators';
import { parse } from '../../shared/http/zod';
import { RemindersService } from './reminders.service';

const Record = z.object({
  kind: z.enum(['credit', 'invoice']),
  id: z.string().uuid(),
  channel: z.enum(['whatsapp', 'sms', 'call']).default('whatsapp'),
});

/** Relances : crédits clients et factures impayées à rappeler, et historique des rappels. */
@Controller('v1/reminders')
@RequireModule('sales')
export class RemindersController {
  constructor(private readonly reminders: RemindersService) {}

  @Get()
  @RequirePermission('contacts:read')
  queue(@CurrentTenant() t: TenantContext) {
    return this.reminders.queue(t.businessId, t.permissions);
  }

  @Post()
  @RequirePermission('contacts:read')
  record(@CurrentTenant() t: TenantContext, @CurrentUser() u: AuthUser, @Body() body: unknown) {
    return this.reminders.record(t.businessId, u.id, t.permissions, parse(Record, body));
  }
}
