import { Body, Controller, Get, Param, ParseUUIDPipe, Post, Put } from '@nestjs/common';
import { z } from 'zod';
import { AuthUser, TenantContext } from '../../shared/auth/auth.types';
import { CurrentTenant, CurrentUser, RequireModule, RequirePermission } from '../../shared/auth/decorators';
import { parse } from '../../shared/http/zod';
import { LoyaltyService } from './loyalty.service';

const Settings = z
  .object({
    enabled: z.boolean(),
    earnPer: z.coerce.number().int().min(50).max(1_000_000),
    rewardPoints: z.coerce.number().int().min(1).max(1_000_000),
    rewardValue: z.coerce.number().int().min(50).max(10_000_000),
  })
  .refine((s) => s.rewardValue <= s.rewardPoints * s.earnPer, {
    message: 'La récompense ne peut pas valoir plus que ce que le client a dépensé pour l’obtenir',
    path: ['rewardValue'],
  });

const Adjust = z.object({
  points: z.coerce
    .number()
    .int()
    .min(-100_000)
    .max(100_000)
    .refine((n) => n !== 0, 'Le nombre de points ne peut pas être nul'),
  reason: z.string().trim().min(3).max(200),
});

/** Fidélité : programme de points, carte des clients, meilleurs clients et anniversaires. */
@Controller('v1/loyalty')
@RequireModule('sales')
export class LoyaltyController {
  constructor(private readonly loyalty: LoyaltyService) {}

  @Get()
  @RequirePermission('contacts:read')
  dashboard(@CurrentTenant() t: TenantContext) {
    return this.loyalty.dashboard(t.businessId);
  }

  @Get('settings')
  @RequirePermission('contacts:read')
  settings(@CurrentTenant() t: TenantContext) {
    return this.loyalty.settings(t.businessId);
  }

  @Put('settings')
  @RequirePermission('sales:void')
  save(@CurrentTenant() t: TenantContext, @Body() body: unknown) {
    return this.loyalty.saveSettings(t.businessId, parse(Settings, body));
  }

  @Get('customers/:id')
  @RequirePermission('contacts:read')
  customer(@CurrentTenant() t: TenantContext, @Param('id', ParseUUIDPipe) id: string) {
    return this.loyalty.customer(t.businessId, id);
  }

  /** Cadeau ou correction : réservé au gérant et au propriétaire. */
  @Post('customers/:id/adjust')
  @RequirePermission('sales:void')
  adjust(
    @CurrentTenant() t: TenantContext,
    @CurrentUser() u: AuthUser,
    @Param('id', ParseUUIDPipe) id: string,
    @Body() body: unknown,
  ) {
    const { points, reason } = parse(Adjust, body);
    return this.loyalty.adjust(t.businessId, u.id, id, points, reason);
  }
}
