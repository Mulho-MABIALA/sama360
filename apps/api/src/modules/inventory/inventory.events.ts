import { Injectable } from '@nestjs/common';
import type { BusinessCreated, SaleCompleted, SaleLine, SaleVoided } from '@sama360/contracts';
import type { Tx } from '../../shared/db/db.service';
import { OnDomainEvent } from '../../shared/events/on-domain-event.decorator';
import { InventoryService } from './inventory.service';

/** Quantité totale par produit suivi (une vente peut contenir deux lignes du même produit). */
export function quantitiesByProduct(items: SaleLine[]): Map<string, { quantity: number; unitCost: number }> {
  const map = new Map<string, { quantity: number; unitCost: number }>();
  for (const it of items) {
    if (!it.productId || !it.trackStock) continue;
    const prev = map.get(it.productId);
    map.set(it.productId, {
      quantity: Math.round(((prev?.quantity ?? 0) + it.quantity) * 1000) / 1000,
      unitCost: it.unitCost,
    });
  }
  return map;
}

@Injectable()
export class InventoryEventHandlers {
  constructor(private readonly inventory: InventoryService) {}

  @OnDomainEvent('business.created')
  async createDefaultWarehouse(event: BusinessCreated, tx: Tx): Promise<void> {
    await this.inventory.defaultWarehouse(tx, event.businessId);
  }

  /** Une vente fait sortir la marchandise du stock. */
  @OnDomainEvent('sale.completed')
  async decrementOnSale(event: SaleCompleted, tx: Tx): Promise<void> {
    for (const [productId, line] of quantitiesByProduct(event.payload.items)) {
      await this.inventory.applyMovement(tx, {
        businessId: event.businessId,
        productId,
        warehouseId: event.payload.warehouseId,
        type: 'sale',
        quantity: -line.quantity,
        unitCost: line.unitCost,
        refType: 'sale',
        refId: event.payload.saleId,
        note: event.payload.number,
        createdBy: event.actorId ?? null,
        occurredAt: new Date(event.occurredAt),
      });
    }
  }

  /** Une vente annulée remet la marchandise en stock. */
  @OnDomainEvent('sale.voided')
  async restockOnVoid(event: SaleVoided, tx: Tx): Promise<void> {
    for (const [productId, line] of quantitiesByProduct(event.payload.items)) {
      await this.inventory.applyMovement(tx, {
        businessId: event.businessId,
        productId,
        warehouseId: event.payload.warehouseId,
        type: 'return',
        quantity: line.quantity,
        unitCost: line.unitCost,
        refType: 'sale_void',
        refId: event.payload.saleId,
        note: `Annulation ${event.payload.number}`,
        createdBy: event.actorId ?? null,
      });
    }
  }
}
