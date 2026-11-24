import { Injectable } from '@nestjs/common';
import { and, eq, isNull, sql } from 'drizzle-orm';
import type { Tx } from '../../shared/db/db.service';
import { MovementType, products, warehouses } from '../../shared/db/schema';
import { OutboxService } from '../../shared/events/outbox.service';
import { AppError, variantRequired } from '../../shared/http/app-error';
import { newId } from '../../shared/ids';

export interface MovementInput {
  businessId: string;
  productId: string;
  warehouseId: string;
  type: MovementType;
  quantity: number; // + entrée, − sortie
  unitCost?: number | null;
  refType?: string | null;
  refId?: string | null;
  note?: string | null;
  createdBy?: string | null;
  occurredAt?: Date;
}

export interface MovementResult {
  applied: boolean; // false si déjà appliqué (même référence)
  before: number;
  after: number;
}

/**
 * Seul point d'écriture du stock. Toutes les méthodes reçoivent une transaction
 * déjà placée dans le contexte de l'entreprise (RLS).
 */
@Injectable()
export class InventoryService {
  constructor(private readonly outbox: OutboxService) {}

  /** Entrepôt par défaut ; créé à la volée pour les entreprises plus anciennes que ce module. */
  async defaultWarehouse(tx: Tx, businessId: string): Promise<string> {
    const [found] = await tx
      .select({ id: warehouses.id })
      .from(warehouses)
      .where(eq(warehouses.isDefault, true))
      .limit(1);
    if (found) return found.id;
    await tx
      .insert(warehouses)
      .values({ id: newId(), businessId, name: 'Boutique principale', isDefault: true })
      .onConflictDoNothing();
    const [created] = await tx
      .select({ id: warehouses.id })
      .from(warehouses)
      .where(eq(warehouses.isDefault, true))
      .limit(1);
    return created.id;
  }

  /** Point de vente actif (non archivé) de l'entreprise ; le principal si [id] est absent. */
  async location(tx: Tx, businessId: string, id?: string | null): Promise<string> {
    if (!id) return this.defaultWarehouse(tx, businessId);
    const r = await tx.execute(sql`SELECT 1 FROM inventory.warehouses WHERE id = ${id} AND archived_at IS NULL`);
    if (!r.rows.length) throw new AppError('NOT_FOUND', 'Point de vente introuvable ou fermé', 404);
    return id;
  }

  /** Produit suivi en stock, sinon erreur explicite. */
  async trackedProduct(tx: Tx, productId: string) {
    const [p] = await tx
      .select({
        id: products.id,
        name: products.name,
        trackStock: products.trackStock,
        threshold: products.lowStockThreshold,
        cost: products.cost,
        variantAxes: products.variantAxes,
      })
      .from(products)
      .where(and(eq(products.id, productId), isNull(products.deletedAt)))
      .limit(1);
    if (!p) throw AppError.notFound('Produit');
    if (p.variantAxes?.length) throw variantRequired(p.name);
    if (!p.trackStock) throw new AppError('PRODUCT_NOT_TRACKED', `« ${p.name} » n'est pas suivi en stock`, 422);
    return p;
  }

  async onHand(tx: Tx, productId: string, warehouseId: string): Promise<number> {
    const res = await tx.execute(sql`
      SELECT on_hand FROM inventory.stock_levels
      WHERE product_id = ${productId} AND warehouse_id = ${warehouseId}`);
    const row = res.rows[0] as { on_hand: string } | undefined;
    return row ? Number(row.on_hand) : 0;
  }

  /**
   * Enregistre un mouvement et met à jour le niveau dans la même transaction.
   * Un mouvement portant une référence (ex. une vente) n'est appliqué qu'une fois.
   * Émet stock.low quand le produit franchit son seuil d'alerte vers le bas.
   */
  async applyMovement(tx: Tx, m: MovementInput): Promise<MovementResult> {
    const id = newId();
    const inserted = await tx.execute(sql`
      INSERT INTO inventory.stock_movements
        (id, business_id, product_id, warehouse_id, type, quantity, unit_cost, ref_type, ref_id, note, created_by, occurred_at)
      VALUES
        (${id}, ${m.businessId}, ${m.productId}, ${m.warehouseId}, ${m.type}, ${m.quantity}, ${m.unitCost ?? null},
         ${m.refType ?? null}, ${m.refId ?? null}, ${m.note ?? null}, ${m.createdBy ?? null}, ${m.occurredAt ?? new Date()})
      ON CONFLICT (ref_type, ref_id, product_id, type, warehouse_id) WHERE ref_id IS NOT NULL DO NOTHING
      RETURNING id`);
    if (inserted.rows.length === 0) {
      const current = await this.onHand(tx, m.productId, m.warehouseId);
      return { applied: false, before: current, after: current };
    }

    const level = await tx.execute(sql`
      INSERT INTO inventory.stock_levels (business_id, product_id, warehouse_id, on_hand)
      VALUES (${m.businessId}, ${m.productId}, ${m.warehouseId}, ${m.quantity})
      ON CONFLICT (business_id, product_id, warehouse_id)
      DO UPDATE SET on_hand = inventory.stock_levels.on_hand + EXCLUDED.on_hand, updated_at = now()
      RETURNING on_hand`);
    const after = Number((level.rows[0] as { on_hand: string }).on_hand);
    const before = after - m.quantity;

    if (m.quantity < 0) {
      const [p] = await tx
        .select({ name: products.name, threshold: products.lowStockThreshold })
        .from(products)
        .where(eq(products.id, m.productId))
        .limit(1);
      if (p && before > p.threshold && after <= p.threshold) {
        await this.outbox.record(tx, {
          type: 'stock.low',
          businessId: m.businessId,
          aggregateId: m.productId,
          actorId: m.createdBy ?? null,
          payload: {
            productId: m.productId,
            warehouseId: m.warehouseId,
            name: p.name,
            onHand: after,
            threshold: p.threshold,
          },
        });
      }
    }
    return { applied: true, before, after };
  }
}
