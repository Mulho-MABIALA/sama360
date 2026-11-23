import { Body, Controller, Get, HttpCode, Param, ParseUUIDPipe, Patch, Post, Query, Res } from '@nestjs/common';
import type { Response } from 'express';
import { z } from 'zod';
import { AuthUser, TenantContext, seesCosts } from '../../shared/auth/auth.types';
import {
  CurrentTenant,
  CurrentUser,
  RequireModule,
  RequirePermission,
  TenantScoped,
} from '../../shared/auth/decorators';
import { parse } from '../../shared/http/zod';
import { LocationsService } from './locations.service';

const text = (max: number) => z.string().trim().min(1).max(max);
const LocationBody = z.object({
  name: text(80),
  address: z.string().trim().max(200).nullish(),
  phone: z.string().trim().max(20).nullish(),
});
const UpdateLocation = LocationBody.partial().extend({ makeDefault: z.boolean().optional() });
const Transfer = z.object({
  id: z.string().uuid().optional(),
  fromId: z.string().uuid(),
  toId: z.string().uuid(),
  lines: z
    .array(z.object({ productId: z.string().uuid(), quantity: z.coerce.number().positive().max(1_000_000) }))
    .min(1)
    .max(200),
  note: z.string().trim().max(500).nullish(),
});
const ListTransfers = z.object({ limit: z.coerce.number().int().min(1).max(100).default(30) });

/** Points de vente (boutiques) et transferts de marchandise entre eux. */
@Controller('v1')
export class LocationsController {
  constructor(private readonly locations: LocationsService) {}

  /** Tout membre voit la liste (choix du point de vente) ; « current » dit lequel est actif pour lui. */
  @Get('locations')
  @TenantScoped()
  async list(@CurrentTenant() t: TenantContext) {
    const costs = seesCosts(t);
    return {
      data: (await this.locations.list(t.businessId)).map((l) => (costs ? l : { ...l, stockValue: null })),
      current: { id: t.locationFilter, writeTo: t.warehouseId, locked: t.locationLocked },
    };
  }

  @Post('locations')
  @RequirePermission('business:update')
  create(@CurrentTenant() t: TenantContext, @Body() body: unknown) {
    return this.locations.create(t, parse(LocationBody, body));
  }

  @Patch('locations/:id')
  @RequirePermission('business:update')
  update(@CurrentTenant() t: TenantContext, @Param('id', ParseUUIDPipe) id: string, @Body() body: unknown) {
    return this.locations.update(t.businessId, id, parse(UpdateLocation, body));
  }

  @Post('locations/:id/archive')
  @HttpCode(200)
  @RequirePermission('business:update')
  archive(@CurrentTenant() t: TenantContext, @Param('id', ParseUUIDPipe) id: string) {
    return this.locations.archive(t.businessId, id);
  }

  /** 201 si créé, 200 si l'id existait déjà (renvoi depuis le téléphone). */
  @Post('inventory/transfers')
  @RequireModule('inventory')
  @RequirePermission('inventory:write')
  async transfer(
    @CurrentTenant() t: TenantContext,
    @CurrentUser() user: AuthUser,
    @Body() body: unknown,
    @Res({ passthrough: true }) res: Response,
  ) {
    const { created, transfer } = await this.locations.transfer(t, user.id, parse(Transfer, body));
    res.status(created ? 201 : 200);
    return transfer;
  }

  @Get('inventory/transfers')
  @RequireModule('inventory')
  @RequirePermission('inventory:read')
  transfers(@CurrentTenant() t: TenantContext, @Query() query: unknown) {
    return this.locations.transfers(t.businessId, { ...parse(ListTransfers, query), locationId: t.locationFilter });
  }
}
