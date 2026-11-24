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
  Put,
  Query,
  UploadedFile,
  UseInterceptors,
} from '@nestjs/common';
import { FileInterceptor } from '@nestjs/platform-express';
import { and, asc, desc, eq, ilike, inArray, isNull, lt, or, SQL, sql } from 'drizzle-orm';
import { z } from 'zod';
import { AuthUser, TenantContext, hideCost } from '../../shared/auth/auth.types';
import { CurrentTenant, CurrentUser, RequirePermission } from '../../shared/auth/decorators';
import { DbService } from '../../shared/db/db.service';
import { categories, products, VariantAxis } from '../../shared/db/schema';
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
  packName: z.string().trim().min(1).max(20).nullish(),
  packSize: z.coerce.number().gt(1).max(100_000).nullish(),
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
  packName: z.string().trim().min(1).max(20).nullish(),
  packSize: z.coerce.number().gt(1).max(100_000).nullish(),
  durationMinutes: z.number().int().min(5).max(720).nullish(),
});
const ListQuery = PageQuery.extend({
  search: z.string().trim().max(80).optional(),
  categoryId: z.string().uuid().optional(),
});
const optionText = z.string().trim().min(1).max(30);
/** Variantes d'un produit : jusqu'à 3 options (taille, couleur…) et leurs combinaisons. */
const VariantsInput = z.object({
  axes: z
    .array(z.object({ name: optionText, values: z.array(optionText).min(1).max(40) }))
    .max(3)
    .refine((a) => new Set(a.map((x) => x.name.toLowerCase())).size === a.length, 'Deux options portent le même nom')
    .refine(
      (a) => a.every((x) => new Set(x.values.map((v) => v.toLowerCase())).size === x.values.length),
      'Une valeur est en double',
    ),
  // Sans liste : toutes les combinaisons, au prix du modèle
  variants: z
    .array(
      z.object({
        options: z.record(z.string(), optionText),
        price: amount.optional(),
        sku: z.string().trim().max(60).nullish(),
        barcode: z.string().trim().max(60).nullish(),
      }),
    )
    .max(200)
    .optional(),
});

/** Nom affiché d'une variante : « T-shirt col V · Noir · M ». */
export function variantName(base: string, axes: VariantAxis[], options: Record<string, string>) {
  return [base, ...axes.map((a) => options[a.name])].join(' · ').slice(0, 160);
}

/** Toutes les combinaisons des options (dans l'ordre des options). */
function combinations(axes: VariantAxis[]): Record<string, string>[] {
  return axes.reduce<Record<string, string>[]>(
    (acc, a) => acc.flatMap((o) => a.values.map((v) => ({ ...o, [a.name]: v }))),
    [{}],
  );
}

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
/** Conditionnement : le nom et la contenance vont ensemble. */
function checkPack(name?: string | null, size?: number | null) {
  if (!!name !== (size !== null && size !== undefined)) {
    throw new AppError(
      'VALIDATION_FAILED',
      'Conditionnement : indiquez le nom (carton, sac…) et ce qu’il contient',
      422,
    );
  }
}

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
            WHERE p.category_id = "catalog"."categories"."id" AND p.deleted_at IS NULL AND p.parent_id IS NULL)`,
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
          or(ilike(products.name, `%${q.search}%`), eq(products.sku, q.search), eq(products.barcode, q.search))!,
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
      return { data: data.map((p) => hideCost(t, p)), nextCursor: hasMore ? data[data.length - 1].id : null };
    });
  }

  @Post('products')
  @RequirePermission('catalog:write')
  createProduct(@CurrentTenant() t: TenantContext, @CurrentUser() user: AuthUser, @Body() body: unknown) {
    const input = parse(ProductInput, body);
    checkWholesale(input.price, input.wholesalePrice, input.wholesaleMinQty);
    checkPack(input.packName, input.packSize);
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
      return hideCost(t, product);
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
      return hideCost(t, product);
    });
  }

  /**
   * Variantes d'un produit (taille, couleur…) : crée, met à jour ou retire les combinaisons.
   * Chaque variante est un produit rattaché au modèle, avec son stock, son prix et son code-barres.
   * Sans option : le produit redevient simple (ses variantes sont retirées).
   */
  @Put('products/:id/variants')
  @RequirePermission('catalog:write')
  setVariants(
    @CurrentTenant() t: TenantContext,
    @CurrentUser() user: AuthUser,
    @Param('id', ParseUUIDPipe) id: string,
    @Body() body: unknown,
  ) {
    const input = parse(VariantsInput, body);
    return this.dbs.withTenant(t.businessId, async (tx) => {
      const [parent] = await tx
        .select()
        .from(products)
        .where(and(eq(products.id, id), isNull(products.deletedAt)))
        .limit(1);
      if (!parent) throw AppError.notFound('Produit');
      if (parent.parentId) {
        throw new AppError('VALIDATION_FAILED', 'Une variante ne peut pas avoir elle-même des variantes', 422);
      }
      const axes: VariantAxis[] = input.axes.map((a) => ({ name: a.name, values: a.values }));
      type Wanted = { options: Record<string, string>; price?: number; sku?: string | null; barcode?: string | null };
      const asked: Wanted[] = input.variants ?? combinations(axes).map((options) => ({ options }));
      const wanted = asked.map((v): Wanted => {
        const options: Record<string, string> = {};
        for (const a of axes) {
          const value = Object.entries(v.options).find(([k]) => k.toLowerCase() === a.name.toLowerCase())?.[1];
          const match = a.values.find((x) => x.toLowerCase() === value?.toLowerCase());
          if (!match) throw new AppError('VALIDATION_FAILED', `Choisissez « ${a.name} » pour chaque variante`, 422);
          options[a.name] = match;
        }
        return { ...v, options };
      });
      const keyOf = (o: Record<string, string> | null) => axes.map((a) => (o?.[a.name] ?? '').toLowerCase()).join('|');
      if (new Set(wanted.map((w) => keyOf(w.options))).size !== wanted.length) {
        throw new AppError('VALIDATION_FAILED', 'Une même combinaison apparaît deux fois', 422);
      }
      if (axes.length && !wanted.length) throw new AppError('VALIDATION_FAILED', 'Gardez au moins une variante', 422);

      // Le stock se compte sur les variantes : le modèle ne doit plus en avoir
      if (axes.length && !parent.variantAxes) {
        const [st] = (
          await tx.execute(sql`SELECT coalesce(sum(on_hand), 0)::float AS q FROM inventory.stock_levels
                               WHERE product_id = ${id}`)
        ).rows as { q: number }[];
        if (Number(st.q) !== 0) {
          throw new AppError(
            'VALIDATION_FAILED',
            `« ${parent.name} » a encore ${Number(st.q)} en stock : remettez-le à zéro, puis indiquez le stock de chaque variante`,
            422,
            { onHand: Number(st.q) },
          );
        }
      }

      const existing = await tx
        .select()
        .from(products)
        .where(and(eq(products.parentId, id), isNull(products.deletedAt)));
      const byKey = new Map(existing.map((c) => [keyOf(c.options), c]));
      const kept = new Set<string>();
      const now = new Date();
      for (const w of wanted) {
        const current = byKey.get(keyOf(w.options));
        await this.assertCodesFree(tx, w.sku, w.barcode, current?.id);
        const shared = {
          name: variantName(parent.name, axes, w.options),
          options: w.options,
          type: parent.type,
          categoryId: parent.categoryId,
          unit: parent.unit,
          trackStock: parent.trackStock,
          lowStockThreshold: parent.lowStockThreshold,
          published: parent.published,
          updatedAt: now,
        };
        if (current) {
          kept.add(current.id);
          await tx
            .update(products)
            .set({
              ...shared,
              ...(w.price !== undefined ? { price: w.price } : {}),
              ...(w.sku !== undefined ? { sku: w.sku } : {}),
              ...(w.barcode !== undefined ? { barcode: w.barcode } : {}),
              version: current.version + 1,
            })
            .where(eq(products.id, current.id));
        } else {
          await tx.insert(products).values({
            ...shared,
            id: newId(),
            businessId: t.businessId,
            parentId: id,
            price: w.price ?? parent.price,
            cost: parent.cost,
            wholesalePrice: parent.wholesalePrice,
            wholesaleMinQty: parent.wholesaleMinQty,
            packName: parent.packName,
            packSize: parent.packSize,
            sku: w.sku ?? null,
            barcode: w.barcode ?? null,
          });
        }
      }
      const removed = existing.filter((c) => !kept.has(c.id)).map((c) => c.id);
      if (removed.length) {
        await tx
          .update(products)
          .set({ deletedAt: now, updatedAt: now, published: false })
          .where(inArray(products.id, removed));
      }
      const [updated] = await tx
        .update(products)
        .set({ variantAxes: axes.length ? axes : null, version: parent.version + 1, updatedAt: now })
        .where(eq(products.id, id))
        .returning();
      await this.outbox.record(tx, {
        type: 'product.updated',
        businessId: t.businessId,
        aggregateId: id,
        actorId: user.id,
        payload: { productId: id, price: updated.price, cost: updated.cost, published: updated.published },
      });
      const variants = await tx
        .select()
        .from(products)
        .where(and(eq(products.parentId, id), isNull(products.deletedAt)))
        .orderBy(asc(products.name));
      return { product: hideCost(t, updated), variants: variants.map((v) => hideCost(t, v)) };
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
      checkPack(
        input.packName === undefined ? current.packName : input.packName,
        input.packSize === undefined ? current.packSize : input.packSize,
      );
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

      // Modèle à variantes : nom, catégorie, unité, mise en ligne… suivent sur chaque variante ;
      // le prix et le coût aussi, pour les variantes restées au prix du modèle.
      if (product.variantAxes?.length) {
        const children = await tx
          .select()
          .from(products)
          .where(and(eq(products.parentId, id), isNull(products.deletedAt)));
        for (const c of children) {
          await tx
            .update(products)
            .set({
              name: variantName(product.name, product.variantAxes, c.options ?? {}),
              type: product.type,
              categoryId: product.categoryId,
              unit: product.unit,
              trackStock: product.trackStock,
              lowStockThreshold: product.lowStockThreshold,
              published: product.published,
              wholesalePrice: product.wholesalePrice,
              wholesaleMinQty: product.wholesaleMinQty,
              packName: product.packName,
              packSize: product.packSize,
              ...(c.price === current.price ? { price: product.price } : {}),
              ...(c.cost === current.cost ? { cost: product.cost } : {}),
              version: c.version + 1,
              updatedAt: new Date(),
            })
            .where(eq(products.id, c.id));
        }
      }

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
      // Ses variantes partent avec lui
      await tx
        .update(products)
        .set({ deletedAt: new Date(), updatedAt: new Date(), published: false })
        .where(and(eq(products.parentId, id), isNull(products.deletedAt)));
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
