import { Body, Controller, Get, Param, ParseUUIDPipe, Patch, Post, Query } from '@nestjs/common';
import { z } from 'zod';
import type { AuthUser, TenantContext } from '../../shared/auth/auth.types';
import { CurrentTenant, CurrentUser, RequirePermission, RequirePro } from '../../shared/auth/decorators';
import { parse } from '../../shared/http/zod';
import { DELIVERY_STATUSES, VEHICLES } from './delivery';
import { DeliveryService } from './delivery.service';

const money = z.number().int().min(0).max(100_000_000);
const Courier = z.object({
  name: z.string().trim().min(2).max(120),
  phone: z.string().trim().max(25).nullish(),
  vehicle: z.enum(VEHICLES).optional(),
});
const CourierPatch = Courier.partial().extend({ active: z.boolean().optional() });
const Delivery = z.object({
  orderId: z.string().uuid().nullish(),
  customerName: z.string().trim().max(120).nullish(),
  customerPhone: z.string().trim().max(25).nullish(),
  address: z.string().trim().max(500).nullish(),
  note: z.string().trim().max(500).nullish(),
  fee: money.optional(),
  amountToCollect: money.optional(),
  courierId: z.string().uuid().nullish(),
});
const DeliveryPatch = z
  .object({
    status: z.enum(DELIVERY_STATUSES).optional(),
    courierId: z.string().uuid().optional(),
    failureReason: z.string().trim().max(200).nullish(),
    amountToCollect: money.optional(),
  })
  .refine((v) => Object.keys(v).length > 0, 'rien à modifier');
const Board = z.object({ view: z.enum(['active', 'done']).default('active') });

/** Livraison : livreurs, courses (commandes en ligne ou à la main), argent encaissé par les livreurs. */
@Controller('v1')
export class DeliveryController {
  constructor(private readonly delivery: DeliveryService) {}

  @Get('couriers')
  @RequirePermission('sales:read')
  couriers(@CurrentTenant() t: TenantContext) {
    return this.delivery.couriers(t.businessId);
  }

  @Post('couriers')
  @RequirePro('delivery')
  @RequirePermission('sales:create')
  addCourier(@CurrentTenant() t: TenantContext, @Body() body: unknown) {
    return this.delivery.addCourier(t.businessId, parse(Courier, body));
  }

  @Patch('couriers/:id')
  @RequirePro('delivery')
  @RequirePermission('sales:create')
  updateCourier(@CurrentTenant() t: TenantContext, @Param('id', ParseUUIDPipe) id: string, @Body() body: unknown) {
    return this.delivery.updateCourier(t.businessId, id, parse(CourierPatch, body));
  }

  @Get('deliveries')
  @RequirePermission('sales:read')
  board(@CurrentTenant() t: TenantContext, @Query() query: unknown) {
    return this.delivery.board(t.businessId, parse(Board, query).view);
  }

  @Post('deliveries')
  @RequirePro('delivery')
  @RequirePermission('sales:create')
  create(@CurrentTenant() t: TenantContext, @CurrentUser() user: AuthUser, @Body() body: unknown) {
    return this.delivery.create(t.businessId, user.id, parse(Delivery, body));
  }

  @Patch('deliveries/:id')
  @RequirePro('delivery')
  @RequirePermission('sales:create')
  update(
    @CurrentTenant() t: TenantContext,
    @CurrentUser() user: AuthUser,
    @Param('id', ParseUUIDPipe) id: string,
    @Body() body: unknown,
  ) {
    return this.delivery.update(t.businessId, user.id, id, parse(DeliveryPatch, body));
  }

  /** Le livreur a remis l'argent : ses courses livrées sont soldées. */
  @Post('couriers/:id/settle')
  @RequirePro('delivery')
  @RequirePermission('sales:create')
  settle(@CurrentTenant() t: TenantContext, @Param('id', ParseUUIDPipe) id: string) {
    return this.delivery.settle(t.businessId, id);
  }
}
