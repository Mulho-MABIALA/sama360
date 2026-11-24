import { Body, Controller, Get, HttpCode, Param, ParseUUIDPipe, Post, Query } from '@nestjs/common';
import { z } from 'zod';
import type { AuthUser } from '../../shared/auth/auth.types';
import { CurrentUser } from '../../shared/auth/decorators';
import { parse } from '../../shared/http/zod';
import { AdminService } from './admin.service';

const ListQuery = z.object({
  q: z.string().trim().max(80).optional(),
  country: z.enum(['SN', 'CI', 'CG']).optional(),
  plan: z.enum(['trial', 'active', 'expired', 'free']).optional(),
  status: z.enum(['active', 'suspended', 'deleted']).optional(),
  sort: z.enum(['recent', 'name', 'activity', 'revenue']).optional(),
  page: z.coerce.number().int().min(1).max(10_000).optional(),
  pageSize: z.coerce.number().int().min(1).max(100).optional(),
});

const PaymentsQuery = z.object({
  source: z.enum(['online', 'manual']).optional(),
  status: z.enum(['paid', 'pending', 'to_check', 'rejected', 'failed']).optional(),
  page: z.coerce.number().int().min(1).max(10_000).optional(),
  pageSize: z.coerce.number().int().min(1).max(100).optional(),
});

const Gift = z.object({
  days: z.number().int().min(1).max(366),
  reason: z.string().trim().max(200).nullish(),
});
const Suspend = z.object({ reason: z.string().trim().min(3).max(300) });

/** Back office de l'équipe Sama360 (numéros dans ADMIN_PHONES). */
@Controller('v1/admin')
export class AdminController {
  constructor(private readonly admin: AdminService) {}

  @Get('overview')
  async overview(@CurrentUser() user: AuthUser, @Query('days') days?: string) {
    await this.admin.assertAdmin(user.id);
    const d = [7, 30, 90, 365].includes(Number(days)) ? Number(days) : 30;
    return this.admin.overview(d);
  }

  @Get('businesses')
  async businesses(@CurrentUser() user: AuthUser, @Query() query: unknown) {
    await this.admin.assertAdmin(user.id);
    const q = parse(ListQuery, query);
    return this.admin.listBusinesses({ ...q, search: q.q });
  }

  @Get('businesses/:id')
  async business(@CurrentUser() user: AuthUser, @Param('id', ParseUUIDPipe) id: string) {
    await this.admin.assertAdmin(user.id);
    return this.admin.business(id);
  }

  @Post('businesses/:id/gift')
  @HttpCode(200)
  async gift(@CurrentUser() user: AuthUser, @Param('id', ParseUUIDPipe) id: string, @Body() body: unknown) {
    await this.admin.assertAdmin(user.id);
    const b = parse(Gift, body);
    return this.admin.gift(user.id, id, b.days, b.reason || null);
  }

  @Post('businesses/:id/suspend')
  @HttpCode(200)
  async suspend(@CurrentUser() user: AuthUser, @Param('id', ParseUUIDPipe) id: string, @Body() body: unknown) {
    await this.admin.assertAdmin(user.id);
    return this.admin.suspend(user.id, id, parse(Suspend, body).reason);
  }

  @Post('businesses/:id/unsuspend')
  @HttpCode(200)
  async unsuspend(@CurrentUser() user: AuthUser, @Param('id', ParseUUIDPipe) id: string) {
    await this.admin.assertAdmin(user.id);
    return this.admin.unsuspend(user.id, id);
  }

  @Post('businesses/:id/restore')
  @HttpCode(200)
  async restore(@CurrentUser() user: AuthUser, @Param('id', ParseUUIDPipe) id: string) {
    await this.admin.assertAdmin(user.id);
    return this.admin.restore(user.id, id);
  }

  @Get('payments')
  async payments(@CurrentUser() user: AuthUser, @Query() query: unknown) {
    await this.admin.assertAdmin(user.id);
    return this.admin.payments(parse(PaymentsQuery, query));
  }
}
