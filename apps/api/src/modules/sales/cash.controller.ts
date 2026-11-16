import { Body, Controller, Get, HttpCode, Param, ParseUUIDPipe, Post, Query } from '@nestjs/common';
import { hasPermission } from '@sama360/contracts';
import { z } from 'zod';
import { AuthUser, TenantContext } from '../../shared/auth/auth.types';
import { CurrentTenant, CurrentUser, RequireModule, RequirePermission } from '../../shared/auth/decorators';
import { parse } from '../../shared/http/zod';
import { CASH_METHODS, CashService } from './cash.service';

const money = z.coerce.number().int().min(0).max(1_000_000_000);
const Open = z.object({ openingFloat: money.default(0), note: z.string().trim().max(300).nullish() });
const Movement = z.object({
  direction: z.enum(['in', 'out']),
  amount: z.coerce.number().int().min(1).max(1_000_000_000),
  reason: z.string().trim().min(3).max(200),
});
const Close = z.object({
  counted: z.object(Object.fromEntries(CASH_METHODS.map((m) => [m, money.optional()]))).partial(),
  note: z.string().trim().max(500).nullish(),
});
const List = z.object({
  userId: z.string().uuid().optional(),
  limit: z.coerce.number().int().min(1).max(100).default(30),
  offset: z.coerce.number().int().min(0).max(100_000).default(0),
});

/** Le gérant voit et clôture les caisses de tous les vendeurs. */
const manages = (t: TenantContext) => hasPermission(t.permissions, 'sales:void');

/** Caisse : ouverture avec fond de caisse, entrées et sorties d'argent, clôture et rapport Z. */
@Controller('v1/cash')
@RequireModule('sales')
export class CashController {
  constructor(private readonly cash: CashService) {}

  /** Ma caisse ouverte (null si fermée). */
  @Get('current')
  @RequirePermission('sales:create')
  async current(@CurrentTenant() t: TenantContext, @CurrentUser() u: AuthUser) {
    return { session: await this.cash.current(t.businessId, u.id) };
  }

  @Post('open')
  @RequirePermission('sales:create')
  open(@CurrentTenant() t: TenantContext, @CurrentUser() u: AuthUser, @Body() body: unknown) {
    return this.cash.open(t.businessId, u.id, parse(Open, body ?? {}));
  }

  @Post('current/movements')
  @RequirePermission('sales:create')
  movement(@CurrentTenant() t: TenantContext, @CurrentUser() u: AuthUser, @Body() body: unknown) {
    return this.cash.addMovement(t.businessId, u.id, parse(Movement, body));
  }

  @Post('current/close')
  @HttpCode(200)
  @RequirePermission('sales:create')
  closeMine(@CurrentTenant() t: TenantContext, @CurrentUser() u: AuthUser, @Body() body: unknown) {
    return this.cash.close(t.businessId, u.id, parse(Close, body), manages(t));
  }

  /** Clôture de la caisse d'un vendeur par le gérant (vendeur parti sans clôturer). */
  @Post('sessions/:id/close')
  @HttpCode(200)
  @RequirePermission('sales:void')
  closeOther(
    @CurrentTenant() t: TenantContext,
    @CurrentUser() u: AuthUser,
    @Param('id', ParseUUIDPipe) id: string,
    @Body() body: unknown,
  ) {
    return this.cash.close(t.businessId, u.id, { ...parse(Close, body), sessionId: id }, true);
  }

  @Get('sessions')
  @RequirePermission('sales:read')
  list(@CurrentTenant() t: TenantContext, @CurrentUser() u: AuthUser, @Query() query: unknown) {
    return this.cash.list(t.businessId, u.id, parse(List, query), manages(t));
  }

  @Get('sessions/:id')
  @RequirePermission('sales:read')
  get(@CurrentTenant() t: TenantContext, @CurrentUser() u: AuthUser, @Param('id', ParseUUIDPipe) id: string) {
    return this.cash.get(t.businessId, u.id, id, manages(t));
  }
}
