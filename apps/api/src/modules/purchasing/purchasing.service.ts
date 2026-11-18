import { Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { DbService, Tx } from '../../shared/db/db.service';
import { OutboxService } from '../../shared/events/outbox.service';
import { AppError } from '../../shared/http/app-error';
import { newId } from '../../shared/ids';
import { InventoryService } from '../inventory/inventory.service';
import { fcfa } from '../sales/sales.service';
import { rememberAliases } from './invoice-scan.service';

export type PurchaseStatus = 'draft' | 'ordered' | 'partial' | 'received' | 'cancelled';
export type PurchaseMethod =
  | 'cash'
  | 'wave'
  | 'orange_money'
  | 'free_money'
  | 'mtn_momo'
  | 'moov_money'
  | 'airtel_money'
  | 'card'
  | 'transfer'
  | 'cheque';

export interface PurchaseLineInput {
  productId: string;
  quantity: number;
  unitCost?: number;
  /** Libellé lu sur la facture fournisseur (photo) : retenu pour reconnaître le produit la prochaine fois. */
  scanLabel?: string | null;
}
export interface PaymentInput {
  id?: string;
  amount: number;
  method: PurchaseMethod;
  reference?: string | null;
}
export interface CreatePurchaseInput {
  id?: string;
  supplierId: string;
  lines: PurchaseLineInput[];
  orderDate?: string;
  expectedDate?: string | null;
  note?: string | null;
  draft?: boolean;
  /** Achat direct : la marchandise est déjà là (marché, grossiste au comptant). */
  receive?: boolean;
  payment?: PaymentInput | null;
  /** Point de vente qui reçoit la marchandise (le principal si absent). */
  locationId?: string | null;
}
export interface ReceiveInput {
  lines?: { lineId: string; quantity: number; unitCost?: number }[];
  note?: string | null;
  payment?: PaymentInput | null;
}

/** Colonne `date` lue en SQL brut (Date à minuit local) → « AAAA-MM-JJ ». */
export function isoDay(v: unknown): string | null {
  if (v === null || v === undefined) return null;
  if (v instanceof Date) {
    const p = (n: number) => String(n).padStart(2, '0');
    return `${v.getFullYear()}-${p(v.getMonth() + 1)}-${p(v.getDate())}`;
  }
  return String(v).slice(0, 10);
}

const round3 = (n: number) => Math.round(n * 1000) / 1000;
const today = () => new Date().toISOString().slice(0, 10); // Dakar = UTC+0

/**
 * Coût moyen pondéré après une entrée : l'ancien stock garde son coût, la nouvelle
 * marchandise apporte le sien. Un stock négatif ou nul ne compte pas.
 */
export function weightedCost(onHandBefore: number, oldCost: number, quantity: number, unitCost: number): number {
  const before = Math.max(0, onHandBefore);
  if (before + quantity <= 0) return unitCost;
  return Math.round((before * oldCost + quantity * unitCost) / (before + quantity));
}

/** Statut d'un bon d'après ce qui est reçu. */
export function statusAfterReceipt(lines: { quantity: number; receivedQty: number }[]): 'partial' | 'received' {
  return lines.every((l) => l.receivedQty >= l.quantity) ? 'received' : 'partial';
}

/**
 * Répartit un paiement fournisseur sur ses bons impayés, du plus ancien au plus récent.
 * Renvoie les montants par bon ; erreur si le paiement dépasse la dette totale.
 */
export function allocatePayment(
  orders: { id: string; due: number }[],
  amount: number,
): { orderId: string; amount: number }[] {
  const out: { orderId: string; amount: number }[] = [];
  let rest = amount;
  for (const o of orders) {
    if (rest <= 0) break;
    if (o.due <= 0) continue;
    const part = Math.min(rest, o.due);
    out.push({ orderId: o.id, amount: part });
    rest -= part;
  }
  if (rest > 0) throw new AppError('PAYMENT_EXCEEDS_DUE', 'Le montant dépasse ce que vous devez à ce fournisseur', 422);
  return out;
}

type Row = Record<string, unknown>;

/** Bons de commande, réceptions, paiements fournisseurs. Toutes les requêtes passent par la RLS. */
@Injectable()
export class PurchasingService {
  constructor(
    private readonly dbs: DbService,
    private readonly outbox: OutboxService,
    private readonly inventory: InventoryService,
  ) {}

  // ------------------------------------------------------------------ écriture

  create(businessId: string, userId: string, input: CreatePurchaseInput) {
    return this.dbs.withTenant(businessId, async (tx) => {
      if (input.id) {
        const existing = await this.find(tx, input.id);
        if (existing) return { created: false, order: existing };
      }
      if (input.draft && (input.receive || input.payment)) {
        throw new AppError('VALIDATION_FAILED', 'Un brouillon ne peut pas être reçu ni payé', 422);
      }
      await this.assertSupplier(tx, input.supplierId);
      const lines = await this.priceLines(tx, input.lines);
      const total = lines.reduce((s, l) => s + l.total, 0);
      const orderDate = input.orderDate ?? today();
      const id = input.id ?? newId();
      const number = await this.nextNumber(tx, businessId, Number(orderDate.slice(0, 4)));
      const warehouseId = await this.inventory.location(tx, businessId, input.locationId);

      await tx.execute(sql`
        INSERT INTO purchasing.orders
          (id, business_id, number, status, supplier_id, order_date, expected_date, total, note, warehouse_id, created_by)
        VALUES (${id}, ${businessId}, ${number}, ${input.draft ? 'draft' : 'ordered'}, ${input.supplierId}, ${orderDate},
                ${input.expectedDate ?? null}, ${total}, ${input.note ?? null}, ${warehouseId}, ${userId})`);
      await this.insertLines(tx, businessId, id, lines);
      await rememberAliases(tx, businessId, input.supplierId, input.lines);

      if (input.receive) await this.receiveIn(tx, businessId, userId, id, {});
      if (input.payment) await this.payIn(tx, businessId, userId, id, input.payment);
      return { created: true, order: (await this.find(tx, id))! };
    });
  }

  /** Modifie un bon tant que rien n'a été reçu ni payé. */
  update(businessId: string, id: string, input: Partial<Omit<CreatePurchaseInput, 'id' | 'receive' | 'payment'>>) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const o = await this.lock(tx, id);
      if (!['draft', 'ordered'].includes(o.status as string) || Number(o.received_total) > 0 || Number(o.paid) > 0) {
        throw new AppError('DOCUMENT_LOCKED', 'Ce bon a déjà été reçu ou payé : il n’est plus modifiable', 409);
      }
      if (input.supplierId) await this.assertSupplier(tx, input.supplierId);
      let total = Number(o.total);
      if (input.lines) {
        const lines = await this.priceLines(tx, input.lines);
        total = lines.reduce((s, l) => s + l.total, 0);
        await tx.execute(sql`DELETE FROM purchasing.order_lines WHERE order_id = ${id}`);
        await this.insertLines(tx, businessId, id, lines);
      }
      const status = input.draft === undefined ? o.status : input.draft ? 'draft' : 'ordered';
      await tx.execute(sql`
        UPDATE purchasing.orders SET
          supplier_id = ${input.supplierId ?? o.supplier_id},
          expected_date = ${input.expectedDate === undefined ? isoDay(o.expected_date) : input.expectedDate},
          note = ${input.note === undefined ? o.note : input.note},
          order_date = ${input.orderDate ?? isoDay(o.order_date)},
          status = ${status}, total = ${total}, updated_at = now()
        WHERE id = ${id}`);
      return (await this.find(tx, id))!;
    });
  }

  /** Brouillon → commandé (envoyé au fournisseur). */
  confirm(businessId: string, id: string) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const o = await this.lock(tx, id);
      if (o.status !== 'draft') throw new AppError('DOCUMENT_LOCKED', 'Ce bon est déjà commandé', 409);
      await tx.execute(sql`UPDATE purchasing.orders SET status = 'ordered', updated_at = now() WHERE id = ${id}`);
      return (await this.find(tx, id))!;
    });
  }

  cancel(businessId: string, id: string) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const o = await this.lock(tx, id);
      if (o.status === 'cancelled') throw new AppError('DOCUMENT_LOCKED', 'Ce bon est déjà annulé', 409);
      if (Number(o.received_total) > 0) {
        throw new AppError(
          'DOCUMENT_LOCKED',
          'De la marchandise a déjà été reçue : ce bon ne peut plus être annulé',
          409,
        );
      }
      if (Number(o.paid) > 0) {
        throw new AppError('DOCUMENT_LOCKED', 'Ce bon a déjà des paiements : il ne peut pas être annulé', 409);
      }
      await tx.execute(
        sql`UPDATE purchasing.orders SET status = 'cancelled', cancelled_at = now(), updated_at = now() WHERE id = ${id}`,
      );
      return (await this.find(tx, id))!;
    });
  }

  receive(businessId: string, userId: string, id: string, input: ReceiveInput) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const receiptId = await this.receiveIn(tx, businessId, userId, id, input);
      if (input.payment) await this.payIn(tx, businessId, userId, id, input.payment);
      return { receiptId, order: (await this.find(tx, id))! };
    });
  }

  pay(businessId: string, userId: string, id: string, input: PaymentInput) {
    return this.dbs.withTenant(businessId, async (tx) => {
      await this.payIn(tx, businessId, userId, id, input);
      return (await this.find(tx, id))!;
    });
  }

  /** Paiement global au fournisseur, réparti sur ses bons du plus ancien au plus récent. */
  paySupplier(businessId: string, userId: string, supplierId: string, input: PaymentInput) {
    return this.dbs.withTenant(businessId, async (tx) => {
      await this.assertSupplier(tx, supplierId, true);
      const orders = (
        await tx.execute(sql`
          SELECT id, received_total - paid AS due FROM purchasing.orders
          WHERE supplier_id = ${supplierId} AND status NOT IN ('cancelled', 'draft') AND received_total > paid
          ORDER BY order_date, created_at, id FOR UPDATE`)
      ).rows as { id: string; due: string }[];
      const allocations = allocatePayment(
        orders.map((o) => ({ id: o.id, due: Number(o.due) })),
        input.amount,
      );
      for (const a of allocations) {
        await this.payIn(tx, businessId, userId, a.orderId, { ...input, id: undefined, amount: a.amount });
      }
      return { allocations, due: await this.supplierDue(tx, supplierId) };
    });
  }

  // ------------------------------------------------------------------ lecture

  list(
    businessId: string,
    q: { filter: 'open' | 'received' | 'unpaid' | 'all'; supplierId?: string; limit: number; offset: number },
  ) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const filter =
        q.filter === 'open'
          ? sql`AND o.status IN ('draft', 'ordered', 'partial')`
          : q.filter === 'received'
            ? sql`AND o.status = 'received'`
            : q.filter === 'unpaid'
              ? sql`AND o.status <> 'cancelled' AND o.received_total > o.paid`
              : sql``;
      const rows = (
        await tx.execute(sql`
          SELECT o.id, o.number, o.status, o.supplier_id, c.name AS supplier_name, o.order_date, o.expected_date,
                 o.total, o.received_total, o.paid, o.created_at,
                 (SELECT count(*)::int FROM purchasing.order_lines l WHERE l.order_id = o.id) AS line_count
          FROM purchasing.orders o JOIN contacts.contacts c ON c.id = o.supplier_id
          WHERE true ${filter} ${q.supplierId ? sql`AND o.supplier_id = ${q.supplierId}` : sql``}
          ORDER BY o.order_date DESC, o.created_at DESC, o.id DESC
          LIMIT ${q.limit + 1} OFFSET ${q.offset}`)
      ).rows as Row[];
      const [t] = (
        await tx.execute(sql`
          SELECT count(*) FILTER (WHERE status IN ('draft', 'ordered', 'partial'))::int AS open_orders,
                 coalesce(sum(total - received_total) FILTER (WHERE status IN ('ordered', 'partial')), 0)::bigint AS to_receive,
                 coalesce(sum(received_total - paid) FILTER (WHERE status <> 'cancelled' AND received_total > paid), 0)::bigint AS total_due,
                 count(DISTINCT supplier_id) FILTER (WHERE status <> 'cancelled' AND received_total > paid)::int AS suppliers_owed
          FROM purchasing.orders`)
      ).rows as Row[];
      return {
        data: rows.slice(0, q.limit).map((r) => this.summary(r)),
        nextOffset: rows.length > q.limit ? q.offset + q.limit : null,
        totals: {
          openOrders: Number(t.open_orders),
          toReceive: Math.max(0, Number(t.to_receive)),
          totalDue: Number(t.total_due),
          suppliersOwed: Number(t.suppliers_owed),
        },
      };
    });
  }

  get(businessId: string, id: string) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const o = await this.find(tx, id);
      if (!o) throw AppError.notFound('Bon de commande');
      return o;
    });
  }

  suppliers(businessId: string, q: { search?: string }) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const search = q.search ? `%${q.search}%` : null;
      const rows = (
        await tx.execute(sql`
          SELECT c.id, c.name, c.phone, c.address,
                 coalesce(s.orders_count, 0) AS orders_count, coalesce(s.purchased, 0)::bigint AS purchased,
                 coalesce(s.due, 0)::bigint AS due, s.last_order_at, coalesce(s.open_orders, 0) AS open_orders
          FROM contacts.contacts c
          LEFT JOIN (
            SELECT supplier_id, count(*) FILTER (WHERE status <> 'cancelled')::int AS orders_count,
                   sum(received_total) FILTER (WHERE status <> 'cancelled') AS purchased,
                   sum(greatest(received_total - paid, 0)) FILTER (WHERE status <> 'cancelled') AS due,
                   max(order_date) FILTER (WHERE status <> 'cancelled') AS last_order_at,
                   count(*) FILTER (WHERE status IN ('draft', 'ordered', 'partial'))::int AS open_orders
            FROM purchasing.orders GROUP BY supplier_id
          ) s ON s.supplier_id = c.id
          WHERE c.deleted_at IS NULL AND c.type IN ('supplier', 'both')
            ${search ? sql`AND (c.name ILIKE ${search} OR c.phone ILIKE ${search})` : sql``}
          ORDER BY coalesce(s.due, 0) DESC, lower(c.name)
          LIMIT 200`)
      ).rows as Row[];
      return rows.map((r) => ({
        id: r.id,
        name: r.name,
        phone: r.phone,
        address: r.address,
        ordersCount: Number(r.orders_count),
        purchased: Number(r.purchased),
        due: Number(r.due),
        openOrders: Number(r.open_orders),
        lastOrderAt: isoDay(r.last_order_at),
      }));
    });
  }

  supplier(businessId: string, id: string) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const [c] = (
        await tx.execute(sql`
          SELECT id, type, name, phone, email, address, notes, deleted_at FROM contacts.contacts WHERE id = ${id}`)
      ).rows as Row[];
      if (!c || c.deleted_at || c.type === 'customer') throw AppError.notFound('Fournisseur');
      const [stats] = (
        await tx.execute(sql`
          SELECT count(*) FILTER (WHERE status <> 'cancelled')::int AS orders_count,
                 coalesce(sum(received_total) FILTER (WHERE status <> 'cancelled'), 0)::bigint AS purchased,
                 coalesce(sum(paid), 0)::bigint AS paid,
                 max(order_date) FILTER (WHERE status <> 'cancelled') AS last_order_at,
                 count(*) FILTER (WHERE status IN ('draft', 'ordered', 'partial'))::int AS open_orders
          FROM purchasing.orders WHERE supplier_id = ${id}`)
      ).rows as Row[];
      const orders = (
        await tx.execute(sql`
          SELECT o.id, o.number, o.status, o.supplier_id, c.name AS supplier_name, o.order_date, o.expected_date,
                 o.total, o.received_total, o.paid, o.created_at,
                 (SELECT count(*)::int FROM purchasing.order_lines l WHERE l.order_id = o.id) AS line_count
          FROM purchasing.orders o JOIN contacts.contacts c ON c.id = o.supplier_id
          WHERE o.supplier_id = ${id} ORDER BY o.order_date DESC, o.created_at DESC, o.id DESC LIMIT 30`)
      ).rows as Row[];
      const payments = (
        await tx.execute(sql`
          SELECT p.id, p.order_id, o.number, p.method, p.amount, p.reference, p.paid_at
          FROM purchasing.payments p JOIN purchasing.orders o ON o.id = p.order_id
          WHERE p.supplier_id = ${id} ORDER BY p.paid_at DESC, p.id DESC LIMIT 30`)
      ).rows as Row[];
      const products = (
        await tx.execute(sql`
          SELECT l.product_id, l.name, sum(l.received_qty)::float AS quantity,
                 (array_agg(l.unit_cost ORDER BY o.order_date DESC, o.created_at DESC))[1] AS last_cost
          FROM purchasing.order_lines l JOIN purchasing.orders o ON o.id = l.order_id
          WHERE o.supplier_id = ${id} AND o.status <> 'cancelled'
          GROUP BY l.product_id, l.name ORDER BY sum(l.received_qty * l.unit_cost) DESC LIMIT 8`)
      ).rows as Row[];
      return {
        supplier: {
          id: c.id,
          name: c.name,
          phone: c.phone,
          email: c.email,
          address: c.address,
          notes: c.notes,
        },
        due: await this.supplierDue(tx, id),
        stats: {
          ordersCount: Number(stats.orders_count),
          purchased: Number(stats.purchased),
          paid: Number(stats.paid),
          openOrders: Number(stats.open_orders),
          lastOrderAt: isoDay(stats.last_order_at),
        },
        orders: orders.map((r) => this.summary(r)),
        payments: payments.map((p) => ({
          id: p.id,
          orderId: p.order_id,
          number: p.number,
          method: p.method,
          amount: Number(p.amount),
          reference: p.reference,
          paidAt: p.paid_at,
        })),
        products: products.map((p) => ({
          productId: p.product_id,
          name: p.name,
          quantity: Number(p.quantity),
          lastCost: Number(p.last_cost),
        })),
      };
    });
  }

  // ------------------------------------------------------------------ interne

  private async receiveIn(tx: Tx, businessId: string, userId: string, orderId: string, input: ReceiveInput) {
    const o = await this.lock(tx, orderId);
    if (o.status === 'cancelled') throw new AppError('DOCUMENT_LOCKED', 'Ce bon est annulé', 409);
    if (o.status === 'received')
      throw new AppError('DOCUMENT_LOCKED', 'Toute la marchandise de ce bon est déjà reçue', 409);
    const lines = (
      await tx.execute(sql`
        SELECT id, product_id, name, quantity, received_qty, unit_cost
        FROM purchasing.order_lines WHERE order_id = ${orderId} ORDER BY position`)
    ).rows as Row[];
    const byId = new Map(lines.map((l) => [l.id as string, l]));

    // Sans détail : tout ce qui reste à recevoir, au prix commandé
    const wanted: { lineId: string; quantity: number; unitCost?: number }[] =
      input.lines ??
      lines
        .map((l) => ({ lineId: l.id as string, quantity: round3(Number(l.quantity) - Number(l.received_qty)) }))
        .filter((l) => l.quantity > 0);
    if (wanted.length === 0) throw new AppError('VALIDATION_FAILED', 'Rien à recevoir', 422);
    const seen = new Set<string>();
    for (const w of wanted) {
      const l = byId.get(w.lineId);
      if (!l) throw new AppError('VALIDATION_FAILED', 'Ligne inconnue sur ce bon', 422);
      if (seen.has(w.lineId)) throw new AppError('VALIDATION_FAILED', 'Une ligne apparaît plusieurs fois', 422);
      seen.add(w.lineId);
      const remaining = round3(Number(l.quantity) - Number(l.received_qty));
      if (w.quantity > remaining + 1e-9) {
        throw new AppError(
          'VALIDATION_FAILED',
          `« ${l.name} » : ${w.quantity} reçu(s) pour ${remaining} restant(s) à recevoir`,
          422,
          { lineId: w.lineId, remaining },
        );
      }
    }

    const receiptId = newId();
    const receivedAt = new Date();
    let receiptTotal = 0;
    const receiptLines: { id: string; lineId: string; productId: string; quantity: number; unitCost: number }[] = [];
    for (const w of wanted) {
      if (w.quantity <= 0) continue;
      const l = byId.get(w.lineId)!;
      const unitCost = w.unitCost ?? Number(l.unit_cost);
      receiptTotal += Math.round(w.quantity * unitCost);
      receiptLines.push({
        id: newId(),
        lineId: w.lineId,
        productId: l.product_id as string,
        quantity: w.quantity,
        unitCost,
      });
    }
    if (receiptLines.length === 0) throw new AppError('VALIDATION_FAILED', 'Rien à recevoir', 422);

    await tx.execute(sql`
      INSERT INTO purchasing.receipts (id, business_id, order_id, total, note, received_at, created_by)
      VALUES (${receiptId}, ${businessId}, ${orderId}, ${receiptTotal}, ${input.note ?? null}, ${receivedAt}, ${userId})`);

    for (const r of receiptLines) {
      await tx.execute(sql`
        INSERT INTO purchasing.receipt_lines (id, business_id, receipt_id, line_id, product_id, quantity, unit_cost)
        VALUES (${r.id}, ${businessId}, ${receiptId}, ${r.lineId}, ${r.productId}, ${r.quantity}, ${r.unitCost})`);
      await tx.execute(sql`
        UPDATE purchasing.order_lines SET received_qty = received_qty + ${r.quantity} WHERE id = ${r.lineId}`);

      // Stock et coût d'achat
      const [p] = (
        await tx.execute(sql`SELECT cost, track_stock FROM catalog.products WHERE id = ${r.productId} FOR UPDATE`)
      ).rows as { cost: string; track_stock: boolean }[];
      if (!p) continue;
      let newCost = r.unitCost;
      if (p.track_stock) {
        const before = await this.inventory.onHand(tx, r.productId, o.warehouse_id as string);
        newCost = weightedCost(before, Number(p.cost), r.quantity, r.unitCost);
        await this.inventory.applyMovement(tx, {
          businessId,
          productId: r.productId,
          warehouseId: o.warehouse_id as string,
          type: 'purchase',
          quantity: r.quantity,
          unitCost: r.unitCost,
          refType: 'purchase_receipt',
          refId: receiptId,
          note: o.number as string,
          createdBy: userId,
          occurredAt: receivedAt,
        });
      }
      await tx.execute(sql`
        UPDATE catalog.products SET cost = ${newCost}, updated_at = now(), version = version + 1
        WHERE id = ${r.productId}`);
    }

    const after = (
      await tx.execute(sql`SELECT quantity, received_qty FROM purchasing.order_lines WHERE order_id = ${orderId}`)
    ).rows as { quantity: string; received_qty: string }[];
    const status = statusAfterReceipt(
      after.map((l) => ({ quantity: Number(l.quantity), receivedQty: Number(l.received_qty) })),
    );
    await tx.execute(sql`
      UPDATE purchasing.orders SET
        status = ${status}, received_total = received_total + ${receiptTotal}, updated_at = now(),
        received_at = ${status === 'received' ? receivedAt : null}
      WHERE id = ${orderId}`);

    await this.outbox.record(tx, {
      type: 'purchase.received',
      businessId,
      aggregateId: orderId,
      actorId: userId,
      payload: {
        orderId,
        receiptId,
        number: o.number as string,
        supplierId: o.supplier_id as string,
        total: receiptTotal,
        complete: status === 'received',
      },
    });
    return receiptId;
  }

  private async payIn(tx: Tx, businessId: string, userId: string, orderId: string, input: PaymentInput) {
    if (input.id) {
      const [dup] = (await tx.execute(sql`SELECT id FROM purchasing.payments WHERE id = ${input.id}`)).rows;
      if (dup) return; // renvoi du même paiement (réseau coupé)
    }
    const o = await this.lock(tx, orderId);
    if (o.status === 'cancelled') throw new AppError('DOCUMENT_LOCKED', 'Ce bon est annulé', 409);
    if (o.status === 'draft') throw new AppError('DOCUMENT_LOCKED', 'Confirmez la commande avant de la payer', 409);
    // On peut payer d'avance jusqu'au montant commandé, ou ce qui a été reçu s'il est plus élevé
    const ceiling = Math.max(Number(o.total), Number(o.received_total));
    const left = ceiling - Number(o.paid);
    if (input.amount > left) {
      throw new AppError(
        'PAYMENT_EXCEEDS_DUE',
        left <= 0 ? 'Ce bon est déjà entièrement payé' : `Le montant dépasse le reste à payer (${fcfa(left)})`,
        422,
        { left },
      );
    }
    const paymentId = input.id ?? newId();
    await tx.execute(sql`
      INSERT INTO purchasing.payments (id, business_id, order_id, supplier_id, method, amount, reference, paid_at, created_by)
      VALUES (${paymentId}, ${businessId}, ${orderId}, ${o.supplier_id}, ${input.method}, ${input.amount},
              ${input.reference ?? null}, now(), ${userId})`);
    await tx.execute(
      sql`UPDATE purchasing.orders SET paid = paid + ${input.amount}, updated_at = now() WHERE id = ${orderId}`,
    );
    await this.outbox.record(tx, {
      type: 'supplier.payment_recorded',
      businessId,
      aggregateId: orderId,
      actorId: userId,
      payload: {
        paymentId,
        orderId,
        supplierId: o.supplier_id as string,
        amount: input.amount,
        method: input.method,
      },
    });
  }

  private async priceLines(tx: Tx, input: PurchaseLineInput[]) {
    const ids = [...new Set(input.map((l) => l.productId))];
    if (ids.length !== input.length) {
      throw new AppError('VALIDATION_FAILED', 'Un produit apparaît plusieurs fois sur le bon', 422);
    }
    const found = (
      await tx.execute(sql`
        SELECT id, name, cost FROM catalog.products
        WHERE id IN (${sql.join(
          ids.map((i) => sql`${i}`),
          sql`, `,
        )}) AND deleted_at IS NULL`)
    ).rows as { id: string; name: string; cost: string }[];
    const byId = new Map(found.map((p) => [p.id, p]));
    return input.map((l, i) => {
      const p = byId.get(l.productId);
      if (!p) throw new AppError('NOT_FOUND', `Produit introuvable (ligne ${i + 1})`, 404);
      const unitCost = l.unitCost ?? Number(p.cost);
      return {
        productId: p.id,
        name: p.name,
        quantity: round3(l.quantity),
        unitCost,
        total: Math.round(l.quantity * unitCost),
      };
    });
  }

  private async insertLines(
    tx: Tx,
    businessId: string,
    orderId: string,
    lines: { productId: string; name: string; quantity: number; unitCost: number; total: number }[],
  ) {
    for (const [i, l] of lines.entries()) {
      await tx.execute(sql`
        INSERT INTO purchasing.order_lines (id, business_id, order_id, position, product_id, name, quantity, unit_cost, total)
        VALUES (${newId()}, ${businessId}, ${orderId}, ${i}, ${l.productId}, ${l.name}, ${l.quantity}, ${l.unitCost}, ${l.total})`);
    }
  }

  private async assertSupplier(tx: Tx, supplierId: string, allowDeleted = false) {
    const [c] = (await tx.execute(sql`SELECT type, deleted_at FROM contacts.contacts WHERE id = ${supplierId}`))
      .rows as { type: string; deleted_at: Date | null }[];
    if (!c || (!allowDeleted && c.deleted_at)) throw AppError.notFound('Fournisseur');
    if (c.type === 'customer') {
      // Un client qui nous vend aussi de la marchandise devient « client et fournisseur »
      await tx.execute(sql`UPDATE contacts.contacts SET type = 'both', updated_at = now() WHERE id = ${supplierId}`);
    }
  }

  private async lock(tx: Tx, id: string): Promise<Row> {
    const [o] = (await tx.execute(sql`SELECT * FROM purchasing.orders WHERE id = ${id} FOR UPDATE`)).rows as Row[];
    if (!o) throw AppError.notFound('Bon de commande');
    return o;
  }

  private async supplierDue(tx: Tx, supplierId: string): Promise<number> {
    const [r] = (
      await tx.execute(sql`
        SELECT coalesce(sum(greatest(received_total - paid, 0)), 0)::bigint AS due
        FROM purchasing.orders WHERE supplier_id = ${supplierId} AND status <> 'cancelled'`)
    ).rows as { due: string }[];
    return Number(r.due);
  }

  private async nextNumber(tx: Tx, businessId: string, year: number): Promise<string> {
    const res = await tx.execute(sql`
      INSERT INTO purchasing.sequences (business_id, key, year, last_value) VALUES (${businessId}, 'order', ${year}, 1)
      ON CONFLICT (business_id, key, year) DO UPDATE SET last_value = purchasing.sequences.last_value + 1
      RETURNING last_value`);
    const n = (res.rows[0] as { last_value: number }).last_value;
    return `BC-${year}-${String(n).padStart(4, '0')}`;
  }

  private summary(r: Row) {
    const receivedTotal = Number(r.received_total);
    const paid = Number(r.paid);
    return {
      id: r.id,
      number: r.number,
      status: r.status,
      supplierId: r.supplier_id,
      supplierName: r.supplier_name,
      orderDate: isoDay(r.order_date),
      expectedDate: isoDay(r.expected_date),
      total: Number(r.total),
      receivedTotal,
      paid,
      due: r.status === 'cancelled' ? 0 : Math.max(0, receivedTotal - paid),
      lineCount: Number(r.line_count ?? 0),
    };
  }

  private async find(tx: Tx, id: string) {
    const [o] = (
      await tx.execute(sql`
        SELECT o.*, c.name AS supplier_name, c.phone AS supplier_phone
        FROM purchasing.orders o JOIN contacts.contacts c ON c.id = o.supplier_id WHERE o.id = ${id}`)
    ).rows as Row[];
    if (!o) return null;
    const lines = (
      await tx.execute(sql`
        SELECT l.id, l.product_id, l.name, l.quantity, l.received_qty, l.unit_cost, l.total, p.unit, p.cost AS current_cost
        FROM purchasing.order_lines l LEFT JOIN catalog.products p ON p.id = l.product_id
        WHERE l.order_id = ${id} ORDER BY l.position`)
    ).rows as Row[];
    const receipts = (
      await tx.execute(sql`
        SELECT r.id, r.total, r.note, r.received_at, u.full_name AS received_by
        FROM purchasing.receipts r LEFT JOIN core.users u ON u.id = r.created_by
        WHERE r.order_id = ${id} ORDER BY r.received_at, r.id`)
    ).rows as Row[];
    const payments = (
      await tx.execute(sql`
        SELECT id, method, amount, reference, paid_at FROM purchasing.payments
        WHERE order_id = ${id} ORDER BY paid_at, id`)
    ).rows as Row[];
    const s = this.summary({ ...o, line_count: lines.length });
    return {
      ...s,
      supplier: { id: o.supplier_id, name: o.supplier_name, phone: o.supplier_phone },
      note: o.note,
      createdAt: o.created_at,
      receivedAt: o.received_at ?? null,
      cancelledAt: o.cancelled_at ?? null,
      lines: lines.map((l) => ({
        id: l.id,
        productId: l.product_id,
        name: l.name,
        unit: l.unit ?? 'pièce',
        quantity: Number(l.quantity),
        receivedQty: Number(l.received_qty),
        unitCost: Number(l.unit_cost),
        total: Number(l.total),
      })),
      receipts: receipts.map((r) => ({
        id: r.id,
        total: Number(r.total),
        note: r.note,
        receivedAt: r.received_at,
        receivedBy: r.received_by ?? null,
      })),
      payments: payments.map((p) => ({
        id: p.id,
        method: p.method,
        amount: Number(p.amount),
        reference: p.reference,
        paidAt: p.paid_at,
      })),
    };
  }
}
