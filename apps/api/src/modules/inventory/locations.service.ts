import { HttpStatus, Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import type { TenantContext } from '../../shared/auth/auth.types';
import { DbService, Tx } from '../../shared/db/db.service';
import { AppError } from '../../shared/http/app-error';
import { newId } from '../../shared/ids';
import { PRO_FEATURE_LABELS } from '../../shared/plans';
import { InventoryService } from './inventory.service';

type Row = Record<string, unknown>;

export interface LocationInput {
  name: string;
  address?: string | null;
  phone?: string | null;
}
export interface TransferInput {
  id?: string;
  fromId: string;
  toId: string;
  lines: { productId: string; quantity: number }[];
  note?: string | null;
}

/**
 * Points de vente (boutiques) d'un commerce : chacun a son stock, sa caisse et ses ventes.
 * Techniquement des « entrepôts » (inventory.warehouses), déjà présents sur ventes, achats et stock.
 */
@Injectable()
export class LocationsService {
  constructor(
    private readonly dbs: DbService,
    private readonly inventory: InventoryService,
  ) {}

  /** Points de vente ouverts, avec les ventes du jour, la valeur du stock et le nombre de vendeurs rattachés. */
  list(businessId: string) {
    return this.dbs.withTenant(businessId, async (tx) => {
      await this.inventory.defaultWarehouse(tx, businessId);
      const rows = (
        await tx.execute(sql`
          SELECT w.id, w.name, w.address, w.phone, w.is_default,
                 (SELECT count(*) FROM core.memberships m WHERE m.warehouse_id = w.id AND m.status <> 'suspended')::int
                   AS members,
                 (SELECT coalesce(sum(s.total), 0) FROM sales.sales s
                   WHERE s.warehouse_id = w.id AND s.status = 'completed' AND s.sold_at >= date_trunc('day', now()))::bigint
                   AS today_revenue,
                 (SELECT coalesce(sum(greatest(sl.on_hand, 0) * p.cost), 0) FROM inventory.stock_levels sl
                   JOIN catalog.products p ON p.id = sl.product_id AND p.deleted_at IS NULL
                   WHERE sl.warehouse_id = w.id)::bigint AS stock_value
          FROM inventory.warehouses w
          WHERE w.archived_at IS NULL
          ORDER BY w.is_default DESC, w.name`)
      ).rows as Row[];
      return rows.map(toLocation);
    });
  }

  create(t: TenantContext, input: LocationInput) {
    return this.dbs.withTenant(t.businessId, async (tx) => {
      await this.inventory.defaultWarehouse(tx, t.businessId);
      const count = Number(
        (
          (await tx.execute(sql`SELECT count(*) AS n FROM inventory.warehouses WHERE archived_at IS NULL`))
            .rows[0] as Row
        ).n,
      );
      if (count >= 1 && !t.pro) {
        throw new AppError(
          'PRO_REQUIRED',
          `${PRO_FEATURE_LABELS.multi_shop} : fonction Sama360 Pro`,
          HttpStatus.PAYMENT_REQUIRED,
          { feature: 'multi_shop' },
        );
      }
      if (count >= 20) throw new AppError('VALIDATION_FAILED', '20 points de vente au maximum', 422);
      await this.assertUniqueName(tx, input.name);
      const id = newId();
      await tx.execute(sql`
        INSERT INTO inventory.warehouses (id, business_id, name, address, phone, is_default)
        VALUES (${id}, ${t.businessId}, ${input.name}, ${input.address ?? null}, ${input.phone ?? null}, false)`);
      return this.one(tx, id);
    });
  }

  update(businessId: string, id: string, input: Partial<LocationInput> & { makeDefault?: boolean }) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const w = await this.lock(tx, id);
      if (input.name && input.name !== w.name) await this.assertUniqueName(tx, input.name, id);
      if (input.makeDefault && !w.is_default) {
        await tx.execute(sql`UPDATE inventory.warehouses SET is_default = false WHERE is_default`);
        await tx.execute(sql`UPDATE inventory.warehouses SET is_default = true WHERE id = ${id}`);
      }
      await tx.execute(sql`
        UPDATE inventory.warehouses SET
          name = ${input.name ?? w.name},
          address = ${input.address === undefined ? w.address : input.address},
          phone = ${input.phone === undefined ? w.phone : input.phone}
        WHERE id = ${id}`);
      return this.one(tx, id);
    });
  }

  /** Fermer un point de vente : jamais le principal, et seulement une fois son stock vide et sa caisse fermée. */
  archive(businessId: string, id: string) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const w = await this.lock(tx, id);
      if (w.is_default) {
        throw new AppError('VALIDATION_FAILED', 'Le point de vente principal ne peut pas être fermé', 422);
      }
      const stock = (
        await tx.execute(
          sql`SELECT count(*) AS n FROM inventory.stock_levels WHERE warehouse_id = ${id} AND on_hand <> 0`,
        )
      ).rows[0] as Row;
      if (Number(stock.n) > 0) {
        throw new AppError(
          'LOCATION_NOT_EMPTY',
          `Il reste du stock dans ${w.name as string} : transférez-le d’abord vers un autre point de vente`,
          409,
          { products: Number(stock.n) },
        );
      }
      const cash = (
        await tx.execute(
          sql`SELECT count(*) AS n FROM sales.cash_sessions WHERE warehouse_id = ${id} AND status = 'open'`,
        )
      ).rows[0] as Row;
      if (Number(cash.n) > 0) {
        throw new AppError('LOCATION_NOT_EMPTY', `Une caisse est encore ouverte dans ${w.name as string}`, 409);
      }
      await tx.execute(sql`UPDATE core.memberships SET warehouse_id = NULL WHERE warehouse_id = ${id}`);
      await tx.execute(sql`UPDATE inventory.warehouses SET archived_at = now() WHERE id = ${id}`);
      return { id, archived: true };
    });
  }

  // ------------------------------------------------------------------ transferts

  /** Envoie de la marchandise d'un point de vente à un autre (sortie puis entrée, même transaction). */
  transfer(t: TenantContext, userId: string, input: TransferInput) {
    if (input.fromId === input.toId) {
      throw new AppError('VALIDATION_FAILED', 'Choisissez deux points de vente différents', 422);
    }
    if (t.locationLocked && input.fromId !== t.warehouseId && input.toId !== t.warehouseId) {
      throw AppError.forbidden('Vous ne pouvez transférer que depuis ou vers votre point de vente');
    }
    const ids = input.lines.map((l) => l.productId);
    if (new Set(ids).size !== ids.length)
      throw new AppError('VALIDATION_FAILED', 'Un produit apparaît plusieurs fois', 422);
    return this.dbs.withTenant(t.businessId, async (tx) => {
      if (input.id) {
        const existing = await this.findTransfer(tx, input.id);
        if (existing) return { created: false, transfer: existing };
      }
      const from = await this.lock(tx, input.fromId);
      const to = await this.lock(tx, input.toId);
      const lines: { productId: string; name: string; quantity: number }[] = [];
      for (const l of input.lines) {
        const p = await this.inventory.trackedProduct(tx, l.productId);
        const available = await this.inventory.onHand(tx, p.id, input.fromId);
        if (l.quantity > available) {
          throw new AppError(
            'INSUFFICIENT_STOCK',
            `${p.name} : ${available} disponible(s) à ${from.name as string}`,
            422,
            { productId: p.id, available },
          );
        }
        lines.push({ productId: p.id, name: p.name, quantity: l.quantity });
      }
      const id = input.id ?? newId();
      const year = new Date().getUTCFullYear();
      const seq = await tx.execute(sql`
        INSERT INTO sales.sequences (business_id, key, year, last_value) VALUES (${t.businessId}, 'transfer', ${year}, 1)
        ON CONFLICT (business_id, key, year) DO UPDATE SET last_value = sales.sequences.last_value + 1
        RETURNING last_value`);
      const number = `TR-${year}-${String((seq.rows[0] as { last_value: number }).last_value).padStart(4, '0')}`;
      await tx.execute(sql`
        INSERT INTO inventory.transfers (id, business_id, number, from_warehouse_id, to_warehouse_id, lines, note, created_by)
        VALUES (${id}, ${t.businessId}, ${number}, ${input.fromId}, ${input.toId}, ${JSON.stringify(lines)}::jsonb,
                ${input.note ?? null}, ${userId})`);
      for (const l of lines) {
        const product = await this.inventory.trackedProduct(tx, l.productId);
        for (const [warehouseId, qty, other] of [
          [input.fromId, -l.quantity, to.name],
          [input.toId, l.quantity, from.name],
        ] as const) {
          await this.inventory.applyMovement(tx, {
            businessId: t.businessId,
            productId: l.productId,
            warehouseId,
            type: 'transfer',
            quantity: qty,
            unitCost: product.cost,
            refType: 'transfer',
            refId: id,
            note: `${number} ${qty < 0 ? 'vers' : 'depuis'} ${other as string}`,
            createdBy: userId,
          });
        }
      }
      return { created: true, transfer: (await this.findTransfer(tx, id))! };
    });
  }

  transfers(businessId: string, q: { limit: number; locationId?: string | null }) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const rows = (
        await tx.execute(sql`
          SELECT t.*, f.name AS from_name, d.name AS to_name, coalesce(u.full_name, u.phone) AS by_name
          FROM inventory.transfers t
          JOIN inventory.warehouses f ON f.id = t.from_warehouse_id
          JOIN inventory.warehouses d ON d.id = t.to_warehouse_id
          LEFT JOIN core.users u ON u.id = t.created_by
          WHERE ${q.locationId ?? null}::uuid IS NULL
             OR t.from_warehouse_id = ${q.locationId ?? null} OR t.to_warehouse_id = ${q.locationId ?? null}
          ORDER BY t.created_at DESC LIMIT ${q.limit}`)
      ).rows as Row[];
      return rows.map(toTransfer);
    });
  }

  // ------------------------------------------------------------------ interne

  private async one(tx: Tx, id: string) {
    const [r] = (
      await tx.execute(sql`
        SELECT id, name, address, phone, is_default, 0 AS members, 0 AS today_revenue, 0 AS stock_value
        FROM inventory.warehouses WHERE id = ${id}`)
    ).rows as Row[];
    return toLocation(r);
  }

  private async lock(tx: Tx, id: string): Promise<Row> {
    const [w] = (
      await tx.execute(sql`SELECT * FROM inventory.warehouses WHERE id = ${id} AND archived_at IS NULL FOR UPDATE`)
    ).rows as Row[];
    if (!w) throw AppError.notFound('Point de vente');
    return w;
  }

  private async assertUniqueName(tx: Tx, name: string, except?: string) {
    const r = await tx.execute(sql`
      SELECT 1 FROM inventory.warehouses
      WHERE archived_at IS NULL AND lower(name) = lower(${name}) AND id <> coalesce(${except ?? null}::uuid, gen_random_uuid())`);
    if (r.rows.length) throw AppError.conflict(`Un point de vente s’appelle déjà « ${name} »`);
  }

  private async findTransfer(tx: Tx, id: string) {
    const [r] = (
      await tx.execute(sql`
        SELECT t.*, f.name AS from_name, d.name AS to_name, coalesce(u.full_name, u.phone) AS by_name
        FROM inventory.transfers t
        JOIN inventory.warehouses f ON f.id = t.from_warehouse_id
        JOIN inventory.warehouses d ON d.id = t.to_warehouse_id
        LEFT JOIN core.users u ON u.id = t.created_by
        WHERE t.id = ${id}`)
    ).rows as Row[];
    return r ? toTransfer(r) : null;
  }
}

function toLocation(r: Row) {
  return {
    id: r.id as string,
    name: r.name as string,
    address: (r.address as string) ?? null,
    phone: (r.phone as string) ?? null,
    isDefault: Boolean(r.is_default),
    members: Number(r.members ?? 0),
    todayRevenue: Number(r.today_revenue ?? 0),
    stockValue: Number(r.stock_value ?? 0),
  };
}

function toTransfer(r: Row) {
  return {
    id: r.id as string,
    number: r.number as string,
    from: { id: r.from_warehouse_id as string, name: r.from_name as string },
    to: { id: r.to_warehouse_id as string, name: r.to_name as string },
    lines: r.lines as { productId: string; name: string; quantity: number }[],
    note: (r.note as string) ?? null,
    createdByName: (r.by_name as string) ?? null,
    createdAt: r.created_at as Date,
  };
}
