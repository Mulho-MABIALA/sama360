import {
  Body,
  Controller,
  Delete,
  Get,
  HttpCode,
  Param,
  ParseUUIDPipe,
  Patch,
  Post,
  Query,
  UploadedFile,
  UseInterceptors,
} from '@nestjs/common';
import { FileInterceptor } from '@nestjs/platform-express';
import { and, asc, desc, eq, ilike, isNull, lt, or, SQL, sql } from 'drizzle-orm';
import { z } from 'zod';
import { AuthUser, TenantContext } from '../../shared/auth/auth.types';
import { CurrentTenant, CurrentUser, RequirePermission } from '../../shared/auth/decorators';
import { DbService } from '../../shared/db/db.service';
import { categories, products } from '../../shared/db/schema';
import { OutboxService } from '../../shared/events/outbox.service';
import { AppError } from '../../shared/http/app-error';
import { PageQuery, parse } from '../../shared/http/zod';
import { newId } from '../../shared/ids';
import { env } from '../../shared/config/env';
import { FilesService } from '../files/files.service';

const amount = z.coerce.number().int().min(0).max(1_000_000_000_000);

const ProductInput = z.object({
  type: z.enum(['product', 'service']).default('product'),
  name: z.string().trim().min(1).max(160),
  categoryId: z.string().uuid().nullish(),
  sku: z.string().trim().max(60).nullish(),
  barcode: z.string().trim().max(60).nullish(),
  price: amount,
  cost: amount.default(0),
  unit: z.string().trim().max(20).default('pièce'),
  trackStock: z.boolean().default(true),
  lowStockThreshold: z.number().int().min(0).max(1_000_000).default(5),
  published: z.boolean().default(false),
  wholesalePrice: amount.nullish(),
  wholesaleMinQty: z.coerce.number().positive().max(1_000_000).nullish(),
  durationMinutes: z.number().int().min(5).max(720).nullish(),
});
// Les valeurs par défaut ne doivent pas s'appliquer lors d'une modification partielle.
const ProductPatch = z.object({
  type: z.enum(['product', 'service']).optional(),
  name: z.string().trim().min(1).max(160).optional(),
  categoryId: z.string().uuid().nullish(),
  sku: z.string().trim().max(60).nullish(),
  barcode: z.string().trim().max(60).nullish(),
  price: amount.optional(),
  cost: amount.optional(),
  unit: z.string().trim().max(20).optional(),
  trackStock: z.boolean().optional(),
  lowStockThreshold: z.number().int().min(0).max(1_000_000).optional(),
  published: z.boolean().optional(),
  wholesalePrice: amount.nullish(),
  wholesaleMinQty: z.coerce.number().positive().max(1_000_000).nullish(),
  durationMinutes: z.number().int().min(5).max(720).nullish(),
});
const ListQuery = PageQuery.extend({
  search: z.string().trim().max(80).optional(),
  categoryId: z.string().uuid().optional(),
});
const CategoryInput = z.object({
  name: z.string().trim().min(1).max(80),
  position: z.number().int().min(0).default(0),
});
const CategoryPatch = z.object({
  name: z.string().trim().min(1).max(80).optional(),
  position: z.number().int().min(0).optional(),
});

type Tx = Parameters<Parameters<DbService['withTenant']>[1]>[0];

/** Prix de gros : les deux champs ensemble, et plus bas que le prix normal. */
function checkWholesale(price: number, wholesalePrice?: number | null, minQty?: number | null) {
  const hasPrice = wholesalePrice !== null && wholesalePrice !== undefined;
  const hasQty = minQty !== null && minQty !== undefined;
  if (hasPrice !== hasQty) {
    throw new AppError('VALIDATION_FAILED', 'Prix de gros : indiquez le prix et la quantité minimale', 422);
  }
  if (hasPrice && wholesalePrice! >= price) {
    throw new AppError('VALIDATION_FAILED', 'Le prix de gros doit être inférieur au prix normal', 422);
  }
}

@Controller('v1/catalog')
export class CatalogController {
  constructor(
    private readonly dbs: DbService,
    private readonly outbox: OutboxService,
    private readonly filesService: FilesService,
  ) {}

  // ---------- Catégories ----------

  @Get('categories')
  @RequirePermission('catalog:read')
  listCategories(@CurrentTenant() t: TenantContext) {
    return this.dbs.withTenant(t.businessId, (tx) =>
      tx
        .select({
          id: categories.id,
          name: categories.name,
          position: categories.position,
          createdAt: categories.createdAt,
          // Nom qualifié explicite : dans une sous-requête, la colonne seule serait ambiguë
          productCount: sql<number>`(SELECT count(*)::int FROM catalog.products p
            WHERE p.category_id = "catalog"."categories"."id" AND p.deleted_at IS NULL)`,
        })
        .from(categories)
        .orderBy(asc(categories.position), asc(categories.name)),
    );
  }

  @Patch('categories/:id')
  @RequirePermission('catalog:write')
  updateCategory(@CurrentTenant() t: TenantContext, @Param('id', ParseUUIDPipe) id: string, @Body() body: unknown) {
    const input = parse(CategoryPatch, body);
    return this.dbs.withTenant(t.businessId, async (tx) => {
      if (input.name) await this.assertCategoryNameFree(tx, input.name, id);
      const [category] = await tx.update(categories).set(input).where(eq(categories.id, id)).returning();
      if (!category) throw AppError.notFound('Catégorie');
      return category;
    });
  }

  /** Supprime une catégorie : ses produits restent, sans catégorie. */
  @Delete('categories/:id')
  @HttpCode(204)
  @RequirePermission('catalog:write')
  async deleteCategory(@CurrentTenant() t: TenantContext, @Param('id', ParseUUIDPipe) id: string) {
    await this.dbs.withTenant(t.businessId, async (tx) => {
      const res = await tx.delete(categories).where(eq(categories.id, id)).returning({ id: categories.id });
      if (res.length === 0) throw AppError.notFound('Catégorie');
    });
  }

  @Post('categories')
  @RequirePermission('catalog:write')
  createCategory(@CurrentTenant() t: TenantContext, @Body() body: unknown) {
    const input = parse(CategoryInput, body);
    return this.dbs.withTenant(t.businessId, async (tx) => {
      await this.assertCategoryNameFree(tx, input.name);
      const [category] = await tx
        .insert(categories)
        .values({ ...input, id: newId(), businessId: t.businessId })
        .returning();
      return category;
    });
  }

  // ---------- Produits ----------

  @Get('products')
  @RequirePermission('catalog:read')
  listProducts(@CurrentTenant() t: TenantContext, @Query() query: unknown) {
    const q = parse(ListQuery, query);
    return this.dbs.withTenant(t.businessId, async (tx) => {
      const where: SQL[] = [isNull(products.deletedAt)];
      if (q.categoryId) where.push(eq(products.categoryId, q.categoryId));
      if (q.cursor) where.push(lt(products.id, q.cursor));
      if (q.search) {
        where.push(
          or(
            ilike(products.name, `%${q.search}%`),
            eq(products.sku, q.search),
            eq(products.barcode, q.search),
          )!,
        );
      }
      const rows = await tx
        .select()
        .from(products)
        .where(and(...where))
        .orderBy(desc(products.id))
        .limit(q.limit + 1);
      const hasMore = rows.length > q.limit;
      const data = rows.slice(0, q.limit);
      return { data, nextCursor: hasMore ? data[data.length - 1].id : null };
    });
  }

  @Post('products')
  @RequirePermission('catalog:write')
  createProduct(@CurrentTenant() t: TenantContext, @CurrentUser() user: AuthUser, @Body() body: unknown) {
    const input = parse(ProductInput, body);
    checkWholesale(input.price, input.wholesalePrice, input.wholesaleMinQty);
    return this.dbs.withTenant(t.businessId, async (tx) => {
      await this.assertCategory(tx, input.categoryId);
      await this.assertCodesFree(tx, input.sku, input.barcode);
      const [product] = await tx
        .insert(products)
        .values({ ...input, id: newId(), businessId: t.businessId })
        .returning();
      await this.outbox.record(tx, {
        type: 'product.updated',
        businessId: t.businessId,
        aggregateId: product.id,
        actorId: user.id,
        payload: { productId: product.id, price: product.price, cost: product.cost, published: product.published },
      });
      return product;
    });
  }

  /** Produit par code-barres ou référence (scan en caisse). */
  @Get('products/by-code/:code')
  @RequirePermission('catalog:read')
  byCode(@CurrentTenant() t: TenantContext, @Param('code') code: string) {
    const c = code.trim().slice(0, 60);
    return this.dbs.withTenant(t.businessId, async (tx) => {
      const [product] = await tx
        .select()
        .from(products)
        .where(and(isNull(products.deletedAt), or(eq(products.barcode, c), eq(products.sku, c))))
        .orderBy(sql`${products.barcode} = ${c} DESC`)
        .limit(1);
      if (!product) throw new AppError('NOT_FOUND', `Aucun produit avec le code ${c}`, 404, { code: c });
      return product;
    });
  }

  @Get('products/:id')
  @RequirePermission('catalog:read')
  getProduct(@CurrentTenant() t: TenantContext, @Param('id', ParseUUIDPipe) id: string) {
    return this.dbs.withTenant(t.businessId, async (tx) => {
      const [product] = await tx
        .select()
        .from(products)
        .where(and(eq(products.id, id), isNull(products.deletedAt)))
        .limit(1);
      if (!product) throw AppError.notFound('Produit');
      return product;
    });
  }

  @Patch('products/:id')
  @RequirePermission('catalog:write')
  updateProduct(
    @CurrentTenant() t: TenantContext,
    @CurrentUser() user: AuthUser,
    @Param('id', ParseUUIDPipe) id: string,
    @Body() body: unknown,
  ) {
    const input = parse(ProductPatch, body);
    return this.dbs.withTenant(t.businessId, async (tx) => {
      const [current] = await tx
        .select()
        .from(products)
        .where(and(eq(products.id, id), isNull(products.deletedAt)))
        .limit(1);
      if (!current) throw AppError.notFound('Produit');
      await this.assertCategory(tx, input.categoryId);
      await this.assertCodesFree(tx, input.sku, input.barcode, id);
      checkWholesale(
        input.price ?? current.price,
        input.wholesalePrice === undefined ? current.wholesalePrice : input.wholesalePrice,
        input.wholesaleMinQty === undefined ? current.wholesaleMinQty : input.wholesaleMinQty,
      );

      const [product] = await tx
        .update(products)
        .set({ ...input, version: current.version + 1, updatedAt: new Date() })
        .where(eq(products.id, id))
        .returning();

      const changed =
        product.price !== current.price || product.cost !== current.cost || product.published !== current.published;
      if (changed) {
        await this.outbox.record(tx, {
          type: 'product.updated',
          businessId: t.businessId,
          aggregateId: product.id,
          actorId: user.id,
          payload: { productId: product.id, price: product.price, cost: product.cost, published: product.published },
        });
      }
      return product;
    });
  }

  /**
   * Photo du produit (multipart, champ « file »). Remplace la photo précédente.
   * Le format est vérifié sur les octets réels ; le téléphone compresse avant l'envoi.
   */
  @Post('products/:id/image')
  @HttpCode(200)
  @RequirePermission('catalog:write')
  @UseInterceptors(FileInterceptor('file', { limits: { fileSize: 20 * 1024 * 1024, files: 1 } }))
  setImage(
    @CurrentTenant() t: TenantContext,
    @CurrentUser() user: AuthUser,
    @Param('id', ParseUUIDPipe) id: string,
    @UploadedFile() file?: { buffer: Buffer; size: number },
  ) {
    if (!file?.buffer?.length) throw new AppError('VALIDATION_FAILED', 'Ajoutez une photo (champ « file »)', 422);
    const maxMb = env().MAX_UPLOAD_MB;
    if (file.size > maxMb * 1024 * 1024) {
      throw new AppError('PAYLOAD_TOO_LARGE', `Photo trop lourde (maximum ${maxMb} Mo)`, 413);
    }
    return this.dbs.withTenant(t.businessId, async (tx) => {
      const [current] = await tx
        .select({ id: products.id, imageFileIds: products.imageFileIds, version: products.version })
        .from(products)
        .where(and(eq(products.id, id), isNull(products.deletedAt)))
        .limit(1);
      if (!current) throw AppError.notFound('Produit');
      const saved = await this.filesService.saveImage(tx, {
        businessId: t.businessId,
        kind: 'product_image',
        data: file.buffer,
        createdBy: user.id,
      });
      const [product] = await tx
        .update(products)
        .set({ imageFileIds: [saved.id], version: current.version + 1, updatedAt: new Date() })
        .where(eq(products.id, id))
        .returning();
      for (const old of current.imageFileIds) await this.filesService.remove(tx, old);
      return product;
    });
  }

  @Delete('products/:id/image')
  @RequirePermission('catalog:write')
  removeImage(@CurrentTenant() t: TenantContext, @Param('id', ParseUUIDPipe) id: string) {
    return this.dbs.withTenant(t.businessId, async (tx) => {
      const [current] = await tx
        .select({ imageFileIds: products.imageFileIds, version: products.version })
        .from(products)
        .where(and(eq(products.id, id), isNull(products.deletedAt)))
        .limit(1);
      if (!current) throw AppError.notFound('Produit');
      const [product] = await tx
        .update(products)
        .set({ imageFileIds: [], version: current.version + 1, updatedAt: new Date() })
        .where(eq(products.id, id))
        .returning();
      for (const old of current.imageFileIds) await this.filesService.remove(tx, old);
      return product;
    });
  }

  @Delete('products/:id')
  @HttpCode(204)
  @RequirePermission('catalog:write')
  async deleteProduct(@CurrentTenant() t: TenantContext, @Param('id', ParseUUIDPipe) id: string) {
    await this.dbs.withTenant(t.businessId, async (tx) => {
      const res = await tx
        .update(products)
        .set({ deletedAt: new Date(), updatedAt: new Date(), published: false })
        .where(and(eq(products.id, id), isNull(products.deletedAt)))
        .returning({ id: products.id });
      if (res.length === 0) throw AppError.notFound('Produit');
    });
  }

  /** Code-barres et référence uniques parmi les produits actifs, avec un message clair. */
  private async assertCodesFree(tx: Tx, sku?: string | null, barcode?: string | null, exceptId?: string) {
    for (const [label, column, value] of [
      ['Ce code-barres', products.barcode, barcode],
      ['Cette référence', products.sku, sku],
    ] as const) {
      if (!value) continue;
      const [other] = await tx
        .select({ id: products.id, name: products.name })
        .from(products)
        .where(and(eq(column, value), isNull(products.deletedAt)))
        .limit(1);
      if (other && other.id !== exceptId) {
        throw new AppError('CONFLICT', `${label} est déjà utilisé par « ${other.name} »`, 409, { productId: other.id });
      }
    }
  }

  private async assertCategoryNameFree(tx: Tx, name: string, exceptId?: string) {
    const [other] = await tx
      .select({ id: categories.id })
      .from(categories)
      .where(sql`lower(${categories.name}) = lower(${name})`)
      .limit(1);
    if (other && other.id !== exceptId) throw new AppError('CONFLICT', 'Cette catégorie existe déjà', 409);
  }

  private async assertCategory(tx: Tx, categoryId?: string | null) {
    if (!categoryId) return;
    // La RLS garantit qu'une catégorie d'une autre entreprise est invisible ici.
    const [cat] = await tx.select({ id: categories.id }).from(categories).where(eq(categories.id, categoryId)).limit(1);
    if (!cat) throw AppError.notFound('Catégorie');
  }
}
