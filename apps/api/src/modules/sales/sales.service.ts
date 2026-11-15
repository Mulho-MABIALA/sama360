import { HttpStatus, Injectable } from '@nestjs/common';
import { and, eq, inArray, isNull, sql } from 'drizzle-orm';
import { DbService, Tx } from '../../shared/db/db.service';
import {
  contacts,
  customerLedger,
  expenses,
  PaymentMethod,
  products,
  saleItems,
  salePayments,
  sales,
} from '../../shared/db/schema';
import { OutboxService } from '../../shared/events/outbox.service';
import { AppError } from '../../shared/http/app-error';
import { newId } from '../../shared/ids';
import { InventoryService } from '../inventory/inventory.service';
import { LineInput, priceSale, PricingError } from './pricing';

export interface CreateSaleInput {
  id?: string; // id généré par le mobile : rend la création idempotente (hors ligne)
  customerId?: string | null;
  items: { productId?: string | null; name?: string; quantity: number; unitPrice?: number; discount?: number }[];
  discount?: number;
  payments: { method: PaymentMethod; amount: number; reference?: string | null }[];
  soldAt?: Date;
  note?: string | null;
}

@Injectable()
export class SalesService {
  constructor(
    private readonly dbs: DbService,
    private readonly outbox: OutboxService,
    private readonly inventory: InventoryService,
  ) {}

  /**
   * Enregistre une vente : lignes, paiements, dette éventuelle au carnet de crédit,
   * puis émet sale.completed (le stock est décrémenté par le module inventory).
   * Renvoie { created: false } si une vente avec le même id existe déjà.
   */
  async create(businessId: string, cashierId: string, input: CreateSaleInput) {
    return this.dbs.withTenant(businessId, async (tx) => {
      if (input.id) {
        const existing = await this.findFull(tx, input.id);
        if (existing) return { created: false, sale: existing };
      }

      if (input.customerId) await this.assertCustomer(tx, input.customerId);

      // Produits du catalogue (socle) : nom, prix et coût de référence
      const ids = [...new Set(input.items.map((i) => i.productId).filter((x): x is string => !!x))];
      const catalog = ids.length
        ? await tx
            .select({
              id: products.id,
              name: products.name,
              price: products.price,
              cost: products.cost,
              trackStock: products.trackStock,
            })
            .from(products)
            .where(and(inArray(products.id, ids), isNull(products.deletedAt)))
        : [];
      const byId = new Map(catalog.map((p) => [p.id, p]));

      const lines: LineInput[] = input.items.map((it, i) => {
        if (it.productId) {
          const p = byId.get(it.productId);
          if (!p) throw new AppError('NOT_FOUND', `Produit introuvable (ligne ${i + 1})`, HttpStatus.NOT_FOUND);
          return {
            productId: p.id,
            name: p.name,
            quantity: it.quantity,
            unitPrice: it.unitPrice ?? p.price,
            unitCost: p.cost,
            discount: it.discount ?? 0,
            trackStock: p.trackStock,
          };
        }
        if (!it.name || it.unitPrice === undefined) {
          throw new AppError('VALIDATION_FAILED', `Ligne ${i + 1} : nom et prix requis pour un article libre`, 422);
        }
        return {
          productId: null,
          name: it.name,
          quantity: it.quantity,
          unitPrice: it.unitPrice,
          unitCost: 0,
          discount: it.discount ?? 0,
          trackStock: false,
        };
      });

      let totals;
      try {
        totals = priceSale(lines, input.discount ?? 0);
      } catch (e) {
        if (e instanceof PricingError) throw new AppError('VALIDATION_FAILED', e.message, 422);
        throw e;
      }

      const paid = input.payments.reduce((s, p) => s + p.amount, 0);
      if (paid > totals.total) {
        throw new AppError('OVERPAYMENT', 'Le montant payé dépasse le total (rendez la monnaie à part)', 422, {
          total: totals.total,
          paid,
        });
      }
      const due = totals.total - paid;
      if (due > 0 && !input.customerId) {
        throw new AppError('CREDIT_REQUIRES_CUSTOMER', 'Choisissez un client pour une vente à crédit', 422, { due });
      }

      const id = input.id ?? newId();
      const soldAt = input.soldAt ?? new Date();
      const warehouseId = await this.inventory.defaultWarehouse(tx, businessId);
      const number = await this.nextNumber(tx, businessId, 'sale', 'VEN', soldAt.getUTCFullYear());

      await tx.insert(sales).values({
        id,
        businessId,
        number,
        customerId: input.customerId ?? null,
        cashierId,
        warehouseId,
        subtotal: totals.subtotal,
        discount: totals.discount,
        total: totals.total,
        paid,
        costTotal: totals.costTotal,
        note: input.note ?? null,
        soldAt,
      });
      await tx.insert(saleItems).values(
        totals.lines.map((l) => ({
          id: newId(),
          businessId,
          saleId: id,
          productId: l.productId,
          name: l.name,
          quantity: l.quantity,
          unitPrice: l.unitPrice,
          unitCost: l.unitCost,
          discount: l.discount,
          total: l.total,
          trackStock: l.trackStock,
        })),
      );
      if (input.payments.length) {
        await tx.insert(salePayments).values(
          input.payments.map((p) => ({
            id: newId(),
            businessId,
            saleId: id,
            method: p.method,
            amount: p.amount,
            reference: p.reference ?? null,
            paidAt: soldAt,
          })),
        );
      }
      if (due > 0) {
        await tx.insert(customerLedger).values({
          id: newId(),
          businessId,
          customerId: input.customerId!,
          entryType: 'debt',
          amount: due,
          refType: 'sale',
          refId: id,
          note: number,
          occurredAt: soldAt,
          createdBy: cashierId,
        });
      }

      await this.outbox.record(tx, {
        type: 'sale.completed',
        businessId,
        aggregateId: id,
        actorId: cashierId,
        payload: {
          saleId: id,
          number,
          customerId: input.customerId ?? null,
          warehouseId,
          items: totals.lines.map((l) => ({
            productId: l.productId,
            quantity: l.quantity,
            unitCost: l.unitCost,
            trackStock: l.trackStock,
          })),
          total: totals.total,
          paid,
          due,
        },
      });

      return { created: true, sale: (await this.findFull(tx, id))! };
    });
  }

  /** Annule une vente : stock remis (via sale.voided) et dette annulée au carnet de crédit. */
  async void(businessId: string, actorId: string, saleId: string, reason: string) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const [sale] = await tx.select().from(sales).where(eq(sales.id, saleId)).limit(1).for('update');
      if (!sale) throw AppError.notFound('Vente');
      if (sale.status === 'voided') throw new AppError('SALE_ALREADY_VOIDED', 'Cette vente est déjà annulée', 409);

      await tx
        .update(sales)
        .set({ status: 'voided', voidedAt: new Date(), voidReason: reason })
        .where(eq(sales.id, saleId));

      const due = sale.total - sale.paid;
      if (due > 0 && sale.customerId) {
        await tx.insert(customerLedger).values({
          id: newId(),
          businessId,
          customerId: sale.customerId,
          entryType: 'adjustment',
          amount: -due,
          refType: 'sale_void',
          refId: sale.id,
          note: `Annulation ${sale.number}`,
          occurredAt: new Date(),
          createdBy: actorId,
        });
      }

      const items = await tx.select().from(saleItems).where(eq(saleItems.saleId, saleId));
      await this.outbox.record(tx, {
        type: 'sale.voided',
        businessId,
        aggregateId: sale.id,
        actorId,
        payload: {
          saleId: sale.id,
          number: sale.number,
          customerId: sale.customerId,
          warehouseId: sale.warehouseId,
          items: items.map((i) => ({
            productId: i.productId,
            quantity: i.quantity,
            unitCost: i.unitCost,
            trackStock: i.trackStock,
          })),
          due,
        },
      });
      return (await this.findFull(tx, saleId))!;
    });
  }

  /** Remboursement d'une dette client (tout ou partie). */
  async recordRepayment(
    businessId: string,
    actorId: string,
    customerId: string,
    input: { amount: number; method: PaymentMethod; note?: string | null },
  ) {
    return this.dbs.withTenant(businessId, async (tx) => {
      await this.assertCustomer(tx, customerId, true);
      // Verrou sur le client : deux remboursements simultanés ne peuvent pas dépasser la dette
      await tx.execute(sql`SELECT id FROM contacts.contacts WHERE id = ${customerId} FOR UPDATE`);
      const balance = await this.balance(tx, customerId);
      if (input.amount > balance) {
        throw new AppError('REPAYMENT_EXCEEDS_BALANCE', 'Le montant dépasse la dette du client', 422, { balance });
      }
      const entryId = newId();
      await tx.insert(customerLedger).values({
        id: entryId,
        businessId,
        customerId,
        entryType: 'repayment',
        amount: -input.amount,
        method: input.method,
        note: input.note ?? null,
        occurredAt: new Date(),
        createdBy: actorId,
      });
      await this.outbox.record(tx, {
        type: 'customer.repayment_recorded',
        businessId,
        aggregateId: customerId,
        actorId,
        payload: { entryId, customerId, amount: input.amount, method: input.method },
      });
      return { entryId, balance: balance - input.amount };
    });
  }

  async recordExpense(
    businessId: string,
    actorId: string,
    input: { category: string; amount: number; method?: string | null; note?: string | null; spentAt: string },
  ) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const id = newId();
      const [expense] = await tx
        .insert(expenses)
        .values({ id, businessId, createdBy: actorId, ...input, method: input.method ?? null, note: input.note ?? null })
        .returning();
      await this.outbox.record(tx, {
        type: 'expense.recorded',
        businessId,
        aggregateId: id,
        actorId,
        payload: { expenseId: id, amount: input.amount, category: input.category },
      });
      return expense;
    });
  }

  /** Solde dû par un client = somme de son carnet de crédit (source de vérité). */
  async balance(tx: Tx, customerId: string): Promise<number> {
    const res = await tx.execute(
      sql`SELECT coalesce(sum(amount), 0)::bigint AS b FROM sales.customer_ledger WHERE customer_id = ${customerId}`,
    );
    return Number((res.rows[0] as { b: string }).b);
  }

  async findFull(tx: Tx, saleId: string) {
    const [sale] = await tx.select().from(sales).where(eq(sales.id, saleId)).limit(1);
    if (!sale) return null;
    const [items, payments] = await Promise.all([
      tx.select().from(saleItems).where(eq(saleItems.saleId, saleId)),
      tx.select().from(salePayments).where(eq(salePayments.saleId, saleId)),
    ]);
    return {
      ...sale,
      due: sale.total - sale.paid,
      items: items.map(({ businessId: _b, saleId: _s, ...i }) => i),
      payments: payments.map(({ businessId: _b, saleId: _s, ...p }) => p),
    };
  }

  private async assertCustomer(tx: Tx, customerId: string, allowDeleted = false) {
    const [c] = await tx
      .select({ id: contacts.id, type: contacts.type, deletedAt: contacts.deletedAt })
      .from(contacts)
      .where(eq(contacts.id, customerId))
      .limit(1);
    if (!c || (!allowDeleted && c.deletedAt)) throw AppError.notFound('Client');
    if (c.type === 'supplier') throw new AppError('VALIDATION_FAILED', 'Ce contact est un fournisseur', 422);
  }

  /** Numéro continu par entreprise, type et année. Verrouillé par la ligne de séquence. */
  private async nextNumber(tx: Tx, businessId: string, key: string, prefix: string, year: number): Promise<string> {
    const res = await tx.execute(sql`
      INSERT INTO sales.sequences (business_id, key, year, last_value) VALUES (${businessId}, ${key}, ${year}, 1)
      ON CONFLICT (business_id, key, year) DO UPDATE SET last_value = sales.sequences.last_value + 1
      RETURNING last_value`);
    const n = (res.rows[0] as { last_value: number }).last_value;
    return `${prefix}-${year}-${String(n).padStart(4, '0')}`;
  }
}
