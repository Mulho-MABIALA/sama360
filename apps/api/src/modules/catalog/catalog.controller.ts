import { Body, Controller, Delete, Get, HttpCode, Param, ParseUUIDPipe, Patch, Post, Query } from '@nestjs/common';
import { and, asc, desc, eq, ilike, isNull, lt, or, SQL } from 'drizzle-orm';
import { z } from 'zod';
import { AuthUser, TenantContext } from '../../shared/auth/auth.types';
import { CurrentTenant, CurrentUser, RequirePermission } from '../../shared/auth/decorators';
import { DbService } from '../../shared/db/db.service';
import { categories, products } from '../../shared/db/schema';
import { OutboxService } from '../../shared/events/outbox.service';
import { AppError } from '../../shared/http/app-error';
import { PageQuery, parse } from '../../shared/http/zod';
import { newId } from '../../shared/ids';

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
});
const ListQuery = PageQuery.extend({
  search: z.string().trim().max(80).optional(),
  categoryId: z.string().uuid().optional(),
});
const CategoryInput = z.object({
  name: z.string().trim().min(1).max(80),
  position: z.number().int().min(0).default(0),
});

@Controller('v1/catalog')
export class CatalogController {
  constructor(
    private readonly dbs: DbService,
    private readonly outbox: OutboxService,
  ) {}

  // ---------- Catégories ----------

  @Get('categories')
  @RequirePermission('catalog:read')
  listCategories(@CurrentTenant() t: TenantContext) {
    return this.dbs.withTenant(t.businessId, (tx) =>
      tx.select().from(categories).orderBy(asc(categories.position), asc(categories.name)),
    );
  }

  @Post('categories')
  @RequirePermission('catalog:write')
  createCategory(@CurrentTenant() t: TenantContext, @Body() body: unknown) {
    const input = parse(CategoryInput, body);
    return this.dbs.withTenant(t.businessId, async (tx) => {
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
    return this.dbs.withTenant(t.businessId, async (tx) => {
      await this.assertCategory(tx, input.categoryId);
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

  private async assertCategory(tx: Parameters<Parameters<DbService['withTenant']>[1]>[0], categoryId?: string | null) {
    if (!categoryId) return;
    // La RLS garantit qu'une catégorie d'une autre entreprise est invisible ici.
    const [cat] = await tx.select({ id: categories.id }).from(categories).where(eq(categories.id, categoryId)).limit(1);
    if (!cat) throw AppError.notFound('Catégorie');
  }
}
