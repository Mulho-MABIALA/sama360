import { Body, Controller, Get, Header, Param, ParseUUIDPipe, Patch, Post, Put, Query, Res } from '@nestjs/common';
import { Throttle } from '@nestjs/throttler';
import type { Response } from 'express';
import { z } from 'zod';
import type { AuthUser, TenantContext } from '../../shared/auth/auth.types';
import { CurrentTenant, CurrentUser, Public, RequirePermission } from '../../shared/auth/decorators';
import { AppError } from '../../shared/http/app-error';
import { parse } from '../../shared/http/zod';
import { APPOINTMENT_STATUSES } from './booking';
import { BookingService } from './booking.service';
import { bookingPage } from './booking.page';

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

const hhmm = z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/, 'heure au format HH:MM');
const Settings = z
  .object({
    onlineEnabled: z.boolean(),
    openDays: z.array(z.number().int().min(1).max(7)).min(1).max(7),
    openTime: hhmm,
    closeTime: hhmm,
    slotMinutes: z.union([z.literal(15), z.literal(30), z.literal(60)]),
    capacity: z.number().int().min(1).max(20),
    minNoticeMinutes: z.number().int().min(0).max(10080),
    maxDaysAhead: z.number().int().min(1).max(90),
  })
  .refine((s) => s.closeTime > s.openTime, 'l’heure de fermeture doit suivre l’ouverture');
const PublicBook = z.object({
  id: z.string().uuid(),
  serviceId: z.string().uuid(),
  day,
  time: hhmm,
  name: z.string().trim().min(2).max(120),
  phone: z.string().trim().min(6).max(25),
  note: z.string().trim().max(500).nullish(),
});
const SlotsQuery = z.object({ serviceId: z.string().uuid(), day });

/** Adresse de boutique (slug) : lettres, chiffres, tirets. */
function slugOf(v: string): string {
  if (!/^[a-z0-9-]{2,60}$/i.test(v)) throw AppError.notFound('Réservation');
  return v.toLowerCase();
}

/** Réservation : rendez-vous des clients. Le vendeur peut prendre et gérer les rendez-vous. */
@Controller('v1/appointments')
export class BookingController {
  constructor(private readonly booking: BookingService) {}

  @Get('settings')
  @RequirePermission('sales:read')
  settings(@CurrentTenant() t: TenantContext) {
    return this.booking.settings(t.businessId);
  }

  @Put('settings')
  @RequirePermission('business:update')
  saveSettings(@CurrentTenant() t: TenantContext, @Body() body: unknown) {
    return this.booking.saveSettings(t.businessId, parse(Settings, body));
  }

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

/** Réservation en ligne : page publique /r/{boutique} et son API (sans compte). */
@Controller()
export class BookingPublicController {
  constructor(private readonly booking: BookingService) {}

  @Public()
  @Get('r/:slug')
  @Header('Content-Type', 'text/html; charset=utf-8')
  @Header('Cache-Control', 'no-cache')
  page(@Param('slug') slug: string) {
    return bookingPage(slugOf(slug));
  }

  @Public()
  @Get('v1/public/shops/:slug/booking')
  info(@Param('slug') slug: string) {
    return this.booking.publicInfo(slugOf(slug));
  }

  @Public()
  @Throttle({ default: { limit: 60, ttl: 60_000 } })
  @Get('v1/public/shops/:slug/booking/slots')
  slots(@Param('slug') slug: string, @Query() query: unknown) {
    const q = parse(SlotsQuery, query);
    return this.booking.publicSlots(slugOf(slug), q.serviceId, q.day);
  }

  /** 201 si créé, 200 si la même réservation a déjà été reçue (renvoi). */
  @Public()
  @Throttle({ default: { limit: 5, ttl: 60_000 } })
  @Post('v1/public/shops/:slug/booking')
  async book(@Param('slug') slug: string, @Body() body: unknown, @Res({ passthrough: true }) res: Response) {
    const { created, appointment } = await this.booking.publicBook(slugOf(slug), parse(PublicBook, body));
    res.status(created ? 201 : 200);
    return appointment;
  }
}
