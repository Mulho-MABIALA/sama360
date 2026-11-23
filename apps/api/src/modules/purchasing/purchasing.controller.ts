import {
  Body,
  Controller,
  Get,
  HttpCode,
  Param,
  ParseUUIDPipe,
  Patch,
  Post,
  Query,
  Res,
  UploadedFile,
  UseInterceptors,
} from '@nestjs/common';
import { FileInterceptor } from '@nestjs/platform-express';
import { Throttle } from '@nestjs/throttler';
import type { Response } from 'express';
import { z } from 'zod';
import { AuthUser, TenantContext, locationFor } from '../../shared/auth/auth.types';
import { CurrentTenant, CurrentUser, RequireModule, RequirePermission, RequirePro } from '../../shared/auth/decorators';
import { AppError } from '../../shared/http/app-error';
import { parse } from '../../shared/http/zod';
import { InvoiceScanService } from './invoice-scan.service';
import { PurchasingService } from './purchasing.service';

const money = z.coerce.number().int().min(0).max(1_000_000_000_000);
const positive = z.coerce.number().int().min(1).max(1_000_000_000_000);
const quantity = z.coerce.number().positive().max(1_000_000);
const day = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'format AAAA-MM-JJ');
const method = z.enum([
  'cash',
  'wave',
  'orange_money',
  'free_money',
  'mtn_momo',
  'moov_money',
  'airtel_money',
  'card',
  'transfer',
  'cheque',
]);
const Payment = z.object({
  id: z.string().uuid().optional(),
  amount: positive,
  method,
  reference: z.string().trim().max(80).nullish(),
});
const Line = z.object({
  productId: z.string().uuid(),
  quantity,
  unitCost: money.optional(),
  scanLabel: z.string().trim().max(160).nullish(),
});
const CreatePurchase = z.object({
  id: z.string().uuid().optional(),
  supplierId: z.string().uuid(),
  lines: z.array(Line).min(1).max(200),
  orderDate: day.optional(),
  expectedDate: day.nullish(),
  note: z.string().trim().max(1000).nullish(),
  draft: z.boolean().optional(),
  receive: z.boolean().optional(),
  payment: Payment.nullish(),
  /** Point de vente qui reçoit la marchandise (par défaut : celui choisi dans l'app). */
  locationId: z.string().uuid().nullish(),
});
const UpdatePurchase = CreatePurchase.omit({ id: true, receive: true, payment: true, locationId: true }).partial();
const Receive = z.object({
  lines: z
    .array(
      z.object({
        lineId: z.string().uuid(),
        quantity: z.coerce.number().min(0).max(1_000_000),
        unitCost: money.optional(),
      }),
    )
    .min(1)
    .max(200)
    .optional(),
  note: z.string().trim().max(500).nullish(),
  payment: Payment.nullish(),
});
const ListPurchases = z.object({
  filter: z.enum(['open', 'received', 'unpaid', 'all']).default('all'),
  supplierId: z.string().uuid().optional(),
  limit: z.coerce.number().int().min(1).max(100).default(50),
  offset: z.coerce.number().int().min(0).max(100_000).default(0),
});
const ListSuppliers = z.object({ search: z.string().trim().max(80).optional() });

/** Achats : bons de commande, réceptions (entrée en stock), paiements fournisseurs. */
@Controller('v1')
@RequireModule('inventory')
export class PurchasingController {
  constructor(
    private readonly purchasing: PurchasingService,
    private readonly scanner: InvoiceScanService,
  ) {}

  /**
   * Facture fournisseur en photo (multipart, champ « file ») → proposition d'achat à vérifier.
   * Rien n'est enregistré : l'achat est créé ensuite par POST /purchases (avec scanLabel par ligne).
   */
  @Post('purchases/scan')
  @HttpCode(200)
  @RequirePermission('purchasing:write')
  @RequirePro('invoice_scan')
  @Throttle({ default: { limit: 6, ttl: 60_000 } })
  @UseInterceptors(FileInterceptor('file', { limits: { fileSize: 20 * 1024 * 1024, files: 1 } }))
  scan(@CurrentTenant() t: TenantContext, @UploadedFile() file?: { buffer: Buffer }) {
    if (!file?.buffer?.length)
      throw new AppError('VALIDATION_FAILED', 'Ajoutez la photo de la facture (champ « file »)', 422);
    return this.scanner.scan(t, file.buffer);
  }

  @Get('purchases')
  @RequirePermission('purchasing:read')
  list(@CurrentTenant() t: TenantContext, @Query() query: unknown) {
    return this.purchasing.list(t.businessId, parse(ListPurchases, query));
  }

  /** 201 si créé, 200 si l'id existait déjà (renvoi depuis le téléphone). */
  @Post('purchases')
  @RequirePermission('purchasing:write')
  async create(
    @CurrentTenant() t: TenantContext,
    @CurrentUser() user: AuthUser,
    @Body() body: unknown,
    @Res({ passthrough: true }) res: Response,
  ) {
    const input = parse(CreatePurchase, body);
    const { created, order } = await this.purchasing.create(t.businessId, user.id, {
      ...input,
      locationId: locationFor(t, input.locationId),
    });
    res.status(created ? 201 : 200);
    return order;
  }

  @Get('purchases/:id')
  @RequirePermission('purchasing:read')
  get(@CurrentTenant() t: TenantContext, @Param('id', ParseUUIDPipe) id: string) {
    return this.purchasing.get(t.businessId, id);
  }

  @Patch('purchases/:id')
  @RequirePermission('purchasing:write')
  update(@CurrentTenant() t: TenantContext, @Param('id', ParseUUIDPipe) id: string, @Body() body: unknown) {
    return this.purchasing.update(t.businessId, id, parse(UpdatePurchase, body));
  }

  @Post('purchases/:id/confirm')
  @HttpCode(200)
  @RequirePermission('purchasing:write')
  confirm(@CurrentTenant() t: TenantContext, @Param('id', ParseUUIDPipe) id: string) {
    return this.purchasing.confirm(t.businessId, id);
  }

  @Post('purchases/:id/cancel')
  @HttpCode(200)
  @RequirePermission('purchasing:write')
  cancel(@CurrentTenant() t: TenantContext, @Param('id', ParseUUIDPipe) id: string) {
    return this.purchasing.cancel(t.businessId, id);
  }

  /** Réception : la marchandise entre en stock et le coût moyen d'achat est recalculé. */
  @Post('purchases/:id/receive')
  @RequirePermission('purchasing:write')
  receive(
    @CurrentTenant() t: TenantContext,
    @CurrentUser() user: AuthUser,
    @Param('id', ParseUUIDPipe) id: string,
    @Body() body: unknown,
  ) {
    return this.purchasing.receive(t.businessId, user.id, id, parse(Receive, body ?? {}));
  }

  @Post('purchases/:id/payments')
  @RequirePermission('purchasing:write')
  pay(
    @CurrentTenant() t: TenantContext,
    @CurrentUser() user: AuthUser,
    @Param('id', ParseUUIDPipe) id: string,
    @Body() body: unknown,
  ) {
    return this.purchasing.pay(t.businessId, user.id, id, parse(Payment, body));
  }

  @Get('suppliers')
  @RequirePermission('purchasing:read')
  suppliers(@CurrentTenant() t: TenantContext, @Query() query: unknown) {
    return this.purchasing.suppliers(t.businessId, parse(ListSuppliers, query));
  }

  @Get('suppliers/:id')
  @RequirePermission('purchasing:read')
  supplier(@CurrentTenant() t: TenantContext, @Param('id', ParseUUIDPipe) id: string) {
    return this.purchasing.supplier(t.businessId, id);
  }

  /** Paiement global : réparti sur les bons impayés, du plus ancien au plus récent. */
  @Post('suppliers/:id/payments')
  @RequirePermission('purchasing:write')
  paySupplier(
    @CurrentTenant() t: TenantContext,
    @CurrentUser() user: AuthUser,
    @Param('id', ParseUUIDPipe) id: string,
    @Body() body: unknown,
  ) {
    return this.purchasing.paySupplier(t.businessId, user.id, id, parse(Payment.omit({ id: true }), body));
  }
}
