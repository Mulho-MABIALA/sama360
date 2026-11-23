import { Body, Controller, Get, Param, ParseUUIDPipe, Post, Query } from '@nestjs/common';
import { and, asc, desc, eq, lt, sql, SQL } from 'drizzle-orm';
import { z } from 'zod';
import { AuthUser, TenantContext, seesCosts } from '../../shared/auth/auth.types';
import { CurrentTenant, CurrentUser, RequireModule, RequirePermission } from '../../shared/auth/decorators';
import { DbService } from '../../shared/db/db.service';
import { stockMovements, warehouses } from '../../shared/db/schema';
import { AppError } from '../../shared/http/app-error';
import { PageQuery, parse } from '../../shared/http/zod';
import { InventoryService } from './inventory.service';

const quantity = z.coerce.number().refine((n) => Number.isFinite(n) && Math.abs(n) < 1e9, 'quantité invalide');

const MovementBody = z
  .object({
    productId: z.string().uuid(),
    type: z.enum(['purchase', 'return', 'adjustment']),
    quantity: quantity.refine((n) => n !== 0, 'la quantité ne peut pas être nulle'),
    unitCost: z.coerce.number().int().min(0).optional(),
    note: z.string().max(500).optional(),
  })
  .refine((m) => m.type === 'adjustment' || m.quantity > 0, {
    message: 'une entrée de stock doit être positive',
    path: ['quantity'],
  });

const CountBody = z.object({
  items: z
    .array(z.object({ productId: z.string().uuid(), counted: quantity.refine((n) => n >= 0, 'quantité ≥ 0') }))
    .min(1)
    .max(500),
  note: z.string().max(500).optional(),
});

const StockQuery = z.object({
  search: z.string().trim().max(80).optional(),
  lowOnly: z
    .enum(['true', 'false'])
    .optional()
    .transform((v) => v === 'true'),
});

@Controller('v1/inventory')
@RequireModule('inventory')
export class InventoryController {
  constructor(
    private readonly dbs: DbService,
    private readonly inventory: InventoryService,
  ) {}

  @Get('warehouses')
  @RequirePermission('inventory:read')
  listWarehouses(@CurrentTenant() t: TenantContext) {
    return this.dbs.withTenant(t.businessId, async (tx) => {
      await this.inventory.defaultWarehouse(tx, t.businessId);
      return tx.select().from(warehouses).orderBy(desc(warehouses.isDefault), asc(warehouses.name));
    });
  }

  /**
   * État du stock, produits suivis uniquement : du point de vente choisi, ou de tous les
   * points de vente (somme, avec le détail par point de vente dans byLocation).
   */
  @Get('stock')
  @RequirePermission('inventory:read')
  stock(@CurrentTenant() t: TenantContext, @Query() query: unknown) {
    const q = parse(StockQuery, query);
    return this.dbs.withTenant(t.businessId, async (tx) => {
      const warehouseId = t.locationFilter;
      const search = q.search ? `%${q.search}%` : null;
      const res = await tx.execute(sql`
        SELECT p.id, p.name, p.sku, p.price, p.cost, p.low_stock_threshold, p.image_file_ids[1] AS image_file_id,
               coalesce(sum(sl.on_hand) FILTER (WHERE ${warehouseId}::uuid IS NULL OR sl.warehouse_id = ${warehouseId}), 0)
                 AS on_hand,
               coalesce(jsonb_object_agg(sl.warehouse_id, sl.on_hand) FILTER (WHERE sl.warehouse_id IS NOT NULL), '{}')
                 AS by_location
        FROM catalog.products p
        LEFT JOIN inventory.stock_levels sl ON sl.product_id = p.id
          AND sl.warehouse_id IN (SELECT id FROM inventory.warehouses WHERE archived_at IS NULL)
        WHERE p.deleted_at IS NULL AND p.track_stock
          AND (${search}::text IS NULL OR p.name ILIKE ${search})
        GROUP BY p.id
        ORDER BY p.name`);
      type Row = {
        id: string;
        name: string;
        sku: string | null;
        price: string;
        cost: string;
        low_stock_threshold: number;
        image_file_id: string | null;
        on_hand: string;
        by_location: Record<string, string | number>;
      };
      const costs = seesCosts(t);
      const items = (res.rows as Row[])
        .map((r) => {
          const qty = Number(r.on_hand);
          const cost = Number(r.cost);
          return {
            productId: r.id,
            name: r.name,
            sku: r.sku,
            imageFileId: r.image_file_id,
            price: Number(r.price),
            cost: costs ? cost : null,
            threshold: r.low_stock_threshold,
            onHand: qty,
            low: qty <= r.low_stock_threshold,
            value: costs ? Math.round(qty * cost) : null,
            byLocation: Object.fromEntries(Object.entries(r.by_location).map(([k, v]) => [k, Number(v)])),
          };
        })
        .filter((r) => !q.lowOnly || r.low);
      return {
        warehouseId,
        items,
        totals: {
          products: items.length,
          lowStock: items.filter((i) => i.low).length,
          stockValue: costs ? items.reduce((s, i) => s + Math.max(0, i.value ?? 0), 0) : null,
        },
      };
    });
  }

  @Get('products/:productId/movements')
  @RequirePermission('inventory:read')
  movements(
    @CurrentTenant() t: TenantContext,
    @Param('productId', ParseUUIDPipe) productId: string,
    @Query() query: unknown,
  ) {
    const q = parse(PageQuery, query);
    return this.dbs.withTenant(t.businessId, async (tx) => {
      const where: SQL[] = [eq(stockMovements.productId, productId)];
      if (q.cursor) where.push(lt(stockMovements.id, q.cursor));
      const rows = await tx
        .select()
        .from(stockMovements)
        .where(and(...where))
        .orderBy(desc(stockMovements.id))
        .limit(q.limit + 1);
      const hasMore = rows.length > q.limit;
      const data = rows.slice(0, q.limit).map((m) => (seesCosts(t) ? m : { ...m, unitCost: null }));
      return { data, nextCursor: hasMore ? data[data.length - 1].id : null };
    });
  }

  /** Entrée de marchandise, retour client ou correction manuelle. */
  @Post('movements')
  @RequirePermission('inventory:write')
  addMovement(@CurrentTenant() t: TenantContext, @CurrentUser() user: AuthUser, @Body() body: unknown) {
    const input = parse(MovementBody, body);
    return this.dbs.withTenant(t.businessId, async (tx) => {
      const product = await this.inventory.trackedProduct(tx, input.productId);
      const warehouseId = await this.inventory.location(tx, t.businessId, t.warehouseId);
      const res = await this.inventory.applyMovement(tx, {
        businessId: t.businessId,
        productId: product.id,
        warehouseId,
        type: input.type,
        quantity: input.quantity,
        unitCost: input.unitCost ?? (input.type === 'purchase' ? product.cost : null),
        note: input.note ?? null,
        createdBy: user.id,
      });
      return { productId: product.id, name: product.name, before: res.before, onHand: res.after };
    });
  }

  /** Inventaire physique : on saisit les quantités comptées, l'écart devient un mouvement. */
  @Post('counts')
  @RequirePermission('inventory:write')
  count(@CurrentTenant() t: TenantContext, @CurrentUser() user: AuthUser, @Body() body: unknown) {
    const input = parse(CountBody, body);
    const ids = input.items.map((i) => i.productId);
    if (new Set(ids).size !== ids.length) {
      throw new AppError('VALIDATION_FAILED', 'Un produit apparaît plusieurs fois', 422);
    }
    return this.dbs.withTenant(t.businessId, async (tx) => {
      const warehouseId = await this.inventory.location(tx, t.businessId, t.warehouseId);
      const results = [];
      for (const item of input.items) {
        const product = await this.inventory.trackedProduct(tx, item.productId);
        const current = await this.inventory.onHand(tx, product.id, warehouseId);
        const delta = Math.round((item.counted - current) * 1000) / 1000;
        if (delta !== 0) {
          await this.inventory.applyMovement(tx, {
            businessId: t.businessId,
            productId: product.id,
            warehouseId,
            type: 'count',
            quantity: delta,
            note: input.note ?? 'Inventaire',
            createdBy: user.id,
          });
        }
        results.push({ productId: product.id, name: product.name, before: current, counted: item.counted, delta });
      }
      return { items: results, adjusted: results.filter((r) => r.delta !== 0).length };
    });
  }
}
