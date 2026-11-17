import { Body, Controller, Get, Param, ParseUUIDPipe, Patch, Post, Query } from '@nestjs/common';
import { z } from 'zod';
import type { AuthUser, TenantContext } from '../../shared/auth/auth.types';
import { CurrentTenant, CurrentUser, RequirePermission } from '../../shared/auth/decorators';
import { parse } from '../../shared/http/zod';
import { APPOINTMENT_STATUSES } from './booking';
import { BookingService } from './booking.service';

const day = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'date au format AAAA-MM-JJ');
const text = (max: number) => z.string().trim().min(1).max(max);
const Fields = z.object({
  customerId: z.string().uuid().nullish(),
  customerName: text(120).nullish(),
  customerPhone: z.string().trim().max(25).nullish(),
  serviceId: z.string().uuid().nullish(),
  serviceName: text(160).nullish(),
  price: z.number().int().min(0).max(100_000_000).nullish(),
  startsAt: z.string().datetime({ offset: true }),
  durationMinutes: z.number().int().min(5).max(720),
  note: z.string().trim().max(1000).nullish(),
});
const Update = Fields.partial().extend({ status: z.enum(APPOINTMENT_STATUSES).optional() });
const ListQuery = z
  .object({ from: day, to: day })
  .refine((q) => q.from <= q.to, 'from doit précéder to')
  .refine((q) => (Date.parse(q.to) - Date.parse(q.from)) / 86_400_000 <= 62, 'période de 62 jours au plus');

/** Réservation : rendez-vous des clients. Le vendeur peut prendre et gérer les rendez-vous. */
@Controller('v1/appointments')
export class BookingController {
  constructor(private readonly booking: BookingService) {}

  @Get()
  @RequirePermission('sales:read')
  list(@CurrentTenant() t: TenantContext, @Query() query: unknown) {
    const q = parse(ListQuery, query);
    return this.booking.list(t.businessId, q.from, q.to);
  }

  @Post()
  @RequirePermission('sales:create')
  create(@CurrentTenant() t: TenantContext, @CurrentUser() user: AuthUser, @Body() body: unknown) {
    return this.booking.create(t.businessId, user.id, parse(Fields, body));
  }

  @Patch(':id')
  @RequirePermission('sales:create')
  update(@CurrentTenant() t: TenantContext, @Param('id', ParseUUIDPipe) id: string, @Body() body: unknown) {
    return this.booking.update(t.businessId, id, parse(Update, body));
  }
}
