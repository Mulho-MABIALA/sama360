import {
  Body,
  Controller,
  Delete,
  Get,
  Header,
  HttpCode,
  Param,
  ParseUUIDPipe,
  Post,
  Put,
  Query,
  Res,
  UploadedFile,
  UseInterceptors,
} from '@nestjs/common';
import { FileInterceptor } from '@nestjs/platform-express';
import { Throttle } from '@nestjs/throttler';
import type { Response } from 'express';
import { z } from 'zod';
import { AuthUser, TenantContext } from '../../shared/auth/auth.types';
import {
  CurrentTenant,
  CurrentUser,
  Public,
  RequireModule,
  RequirePermission,
  RequirePro,
} from '../../shared/auth/decorators';
import { env } from '../../shared/config/env';
import { AppError } from '../../shared/http/app-error';
import { parse } from '../../shared/http/zod';
import { storefrontPage } from './storefront.page';
import { ShopService } from './shop.service';

const SLUG = /^[a-z0-9](?:[a-z0-9-]{0,78}[a-z0-9])?$/;
const slugOf = (s: string) => {
  const v = (s ?? '').toLowerCase();
  if (!SLUG.test(v)) throw AppError.notFound('Boutique');
  return v;
};

const money = z.coerce.number().int().min(0).max(1_000_000_000);
const Settings = z.object({
  enabled: z.boolean().optional(),
  title: z.string().trim().max(120).nullish(),
  tagline: z.string().trim().max(120).nullish(),
  description: z.string().trim().max(1000).nullish(),
  whatsapp: z.string().trim().max(25).nullish(),
  pickup: z.boolean().optional(),
  delivery: z.boolean().optional(),
  deliveryFee: money.optional(),
  deliveryZone: z.string().trim().max(200).nullish(),
  minOrder: money.optional(),
});
const Publish = z.object({
  productIds: z.array(z.string().uuid()).min(1).max(500).optional(),
  published: z.boolean(),
});
const PlaceOrder = z.object({
  id: z.string().uuid(),
  customerName: z.string().trim().min(2).max(120),
  customerPhone: z.string().trim().min(6).max(25),
  mode: z.enum(['pickup', 'delivery']),
  address: z.string().trim().max(500).nullish(),
  note: z.string().trim().max(500).nullish(),
  items: z
    .array(z.object({ productId: z.string().uuid(), quantity: z.coerce.number().int().min(1).max(999) }))
    .min(1)
    .max(50),
});
const ListOrders = z.object({
  filter: z.enum(['new', 'open', 'done', 'all']).default('open'),
  limit: z.coerce.number().int().min(1).max(100).default(50),
  offset: z.coerce.number().int().min(0).max(100_000).default(0),
});
const SetStatus = z.object({
  status: z.enum(['confirmed', 'ready', 'delivering', 'completed', 'cancelled']),
  reason: z.string().trim().max(300).nullish(),
  payment: z
    .object({
      method: z.enum(['cash', 'wave', 'orange_money', 'free_money', 'mtn_momo', 'moov_money', 'airtel_money', 'card']),
      amount: money,
    })
    .nullish(),
});

/** Boutique en ligne : page publique et API publique (sans compte), commandes vues par le commerçant. */
@Controller()
export class ShopController {
  constructor(private readonly shop: ShopService) {}

  // ------------------------------------------------------------ page web publique

  @Public()
  @Get(['s/:slug', 's/:slug/c/:orderId'])
  @Header('Content-Type', 'text/html; charset=utf-8')
  @Header('Cache-Control', 'no-cache')
  page(@Param('slug') slug: string) {
    return storefrontPage(slugOf(slug));
  }

  // ------------------------------------------------------------ API publique

  @Public()
  @Get('v1/public/shops/:slug')
  storefront(@Param('slug') slug: string) {
    return this.shop.storefront(slugOf(slug));
  }

  /** 201 si créée, 200 si la même commande a déjà été reçue (renvoi). */
  @Public()
  @Throttle({ default: { limit: 10, ttl: 60_000 } })
  @Post('v1/public/shops/:slug/orders')
  async place(@Param('slug') slug: string, @Body() body: unknown, @Res({ passthrough: true }) res: Response) {
    const { created, order } = await this.shop.place(slugOf(slug), parse(PlaceOrder, body));
    res.status(created ? 201 : 200);
    return order;
  }

  @Public()
  @Get('v1/public/shops/:slug/orders/:id')
  track(@Param('slug') slug: string, @Param('id', ParseUUIDPipe) id: string) {
    return this.shop.track(slugOf(slug), id);
  }

  // ------------------------------------------------------------ commerçant

  @Get('v1/shop')
  @RequireModule('shop')
  @RequirePermission('sales:read')
  overview(@CurrentTenant() t: TenantContext) {
    return this.shop.overview(t.businessId);
  }

  @Put('v1/shop/settings')
  @RequirePro('shop')
  @RequireModule('shop')
  @RequirePermission('catalog:write')
  settings(@CurrentTenant() t: TenantContext, @Body() body: unknown) {
    return this.shop.saveSettings(t.businessId, parse(Settings, body));
  }

  /** Couverture de la vitrine (JPEG, PNG ou WebP). */
  @Post('v1/shop/cover')
  @RequirePro('shop')
  @RequireModule('shop')
  @RequirePermission('catalog:write')
  @UseInterceptors(FileInterceptor('file', { limits: { fileSize: 20 * 1024 * 1024, files: 1 } }))
  setCover(
    @CurrentTenant() t: TenantContext,
    @CurrentUser() user: AuthUser,
    @UploadedFile() file?: { buffer: Buffer; size: number },
  ) {
    if (!file?.buffer?.length) throw new AppError('VALIDATION_FAILED', 'Ajoutez une image (champ « file »)', 422);
    const maxMb = env().MAX_UPLOAD_MB;
    if (file.size > maxMb * 1024 * 1024) {
      throw new AppError('PAYLOAD_TOO_LARGE', `Image trop lourde (maximum ${maxMb} Mo)`, 413);
    }
    return this.shop.setCover(t.businessId, user.id, file.buffer);
  }

  @Delete('v1/shop/cover')
  @RequireModule('shop')
  @RequirePermission('catalog:write')
  removeCover(@CurrentTenant() t: TenantContext) {
    return this.shop.removeCover(t.businessId);
  }

  @Post('v1/shop/publish')
  @RequirePro('shop')
  @HttpCode(200)
  @RequireModule('shop')
  @RequirePermission('catalog:write')
  publish(@CurrentTenant() t: TenantContext, @Body() body: unknown) {
    return this.shop.publish(t.businessId, parse(Publish, body));
  }

  @Get('v1/shop/orders')
  @RequireModule('shop')
  @RequirePermission('sales:read')
  orders(@CurrentTenant() t: TenantContext, @Query() query: unknown) {
    return this.shop.orders(t.businessId, parse(ListOrders, query));
  }

  @Get('v1/shop/orders/:id')
  @RequireModule('shop')
  @RequirePermission('sales:read')
  order(@CurrentTenant() t: TenantContext, @Param('id', ParseUUIDPipe) id: string) {
    return this.shop.order(t.businessId, id);
  }

  @Post('v1/shop/orders/:id/status')
  @RequirePro('shop')
  @HttpCode(200)
  @RequireModule('shop')
  @RequirePermission('sales:create')
  setStatus(
    @CurrentTenant() t: TenantContext,
    @CurrentUser() user: AuthUser,
    @Param('id', ParseUUIDPipe) id: string,
    @Body() body: unknown,
  ) {
    return this.shop.setStatus(t.businessId, user.id, id, parse(SetStatus, body));
  }
}
