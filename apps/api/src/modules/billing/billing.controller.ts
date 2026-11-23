import { Body, Controller, Get, Headers, HttpCode, Param, ParseUUIDPipe, Post, Query, Req } from '@nestjs/common';
import type { RawBodyRequest } from '@nestjs/common';
import type { Request } from 'express';
import { z } from 'zod';
import type { AuthUser, TenantContext } from '../../shared/auth/auth.types';
import { CurrentTenant, CurrentUser, Public, RequirePermission } from '../../shared/auth/decorators';
import { parse } from '../../shared/http/zod';
import { BillingService, PAY_METHODS } from './billing.service';

const PaymentRequest = z.object({
  cycle: z.enum(['monthly', 'yearly']),
  method: z.enum(PAY_METHODS),
  // Référence de la transaction (SMS de Wave / Orange Money / MoMo)
  reference: z.string().trim().min(4).max(60),
  payerPhone: z.string().trim().max(20).nullish(),
});

const Checkout = z.object({
  cycle: z.enum(['monthly', 'yearly']),
  // Pour le reçu Chariow
  email: z.string().trim().toLowerCase().email().max(160),
});

const Reject = z.object({ note: z.string().trim().max(300).nullish() });

@Controller('v1')
export class BillingController {
  constructor(private readonly billing: BillingService) {}

  /** Abonnement Sama360 Pro : état, prix, comment payer. */
  @Get('subscription')
  @RequirePermission('business:read')
  overview(@CurrentTenant() t: TenantContext) {
    return this.billing.overview(t.businessId);
  }

  /** « J'ai payé » : demande de validation du paiement. */
  @Post('subscription/requests')
  @RequirePermission('business:update')
  request(@CurrentTenant() t: TenantContext, @CurrentUser() user: AuthUser, @Body() body: unknown) {
    return this.billing.requestPayment(t.businessId, user.id, parse(PaymentRequest, body));
  }

  /** Payer Pro en ligne (Chariow : Wave, Orange Money, MoMo, carte…) : renvoie l'adresse de la page de paiement. */
  @Post('subscription/checkout')
  @RequirePermission('business:update')
  checkout(
    @CurrentTenant() t: TenantContext,
    @CurrentUser() user: AuthUser,
    @Body() body: unknown,
    @Req() req: Request,
  ) {
    return this.billing.startCheckout(t.businessId, user.id, parse(Checkout, body), {
      origin: `${req.protocol}://${req.get('host')}`,
      ip: req.ip,
    });
  }

  /** État d'un paiement en ligne (au retour de la page de paiement). */
  @Get('subscription/online/:id')
  @RequirePermission('business:read')
  online(@CurrentTenant() t: TenantContext, @Param('id', ParseUUIDPipe) id: string) {
    return this.billing.onlinePayment(t.businessId, id);
  }

  /** Pulse Chariow (webhook signé) : vente réussie → Pro activé. */
  @Public()
  @Post('webhooks/chariow')
  @HttpCode(200)
  pulse(
    @Req() req: RawBodyRequest<Request>,
    @Headers('x-chariow-signature') signature?: string,
    @Headers('x-pulse-delivery-id') deliveryId?: string,
  ) {
    return this.billing.handlePulse(req.rawBody, signature, deliveryId);
  }

  /** Mon code de parrainage et mes filleuls. */
  @Get('referrals')
  @RequirePermission('business:read')
  referrals(@CurrentTenant() t: TenantContext) {
    return this.billing.referrals(t.businessId);
  }

  // ───────────── équipe Sama360 (numéros dans ADMIN_PHONES)

  @Get('admin/me')
  async adminMe(@CurrentUser() user: AuthUser) {
    return { admin: await this.billing.isAdmin(user.id) };
  }

  @Get('admin/subscription-requests')
  async adminList(@CurrentUser() user: AuthUser, @Query('status') status?: string) {
    await this.billing.assertAdmin(user.id);
    const s = status === 'approved' || status === 'rejected' ? status : 'pending';
    return this.billing.adminList(s);
  }

  @Post('admin/subscription-requests/:id/approve')
  async approve(@CurrentUser() user: AuthUser, @Param('id', ParseUUIDPipe) id: string) {
    await this.billing.assertAdmin(user.id);
    return this.billing.approve(id, user.id);
  }

  @Post('admin/subscription-requests/:id/reject')
  async reject(@CurrentUser() user: AuthUser, @Param('id', ParseUUIDPipe) id: string, @Body() body: unknown) {
    await this.billing.assertAdmin(user.id);
    return this.billing.reject(id, user.id, parse(Reject, body).note ?? null);
  }
}
