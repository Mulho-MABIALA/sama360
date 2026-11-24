import { Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { DbService, Tx } from '../../shared/db/db.service';
import { customerLedger } from '../../shared/db/schema';
import { OutboxService } from '../../shared/events/outbox.service';
import { AppError } from '../../shared/http/app-error';
import { newId } from '../../shared/ids';
import { fcfa, SalesService } from './sales.service';

export type CustomerFilter = 'all' | 'debt' | 'over_limit';
export type CustomerSort = 'name' | 'balance' | 'recent';

export interface LedgerRow {
  id: string;
  entryType: string;
  amount: number;
  method: string | null;
  refType: string | null;
  refId: string | null;
  note: string | null;
  occurredAt: Date;
}

/**
 * Date de la plus ancienne dette encore impayée : les remboursements et remises
 * soldent les dettes dans l'ordre (premier entré, premier soldé).
 * Les entrées doivent être triées de la plus ancienne à la plus récente.
 */
export function oldestUnpaidDebt(entries: { amount: number; occurredAt: Date }[]): Date | null {
  const open: { amount: number; at: Date }[] = [];
  let credit = 0; // avoir à imputer sur les prochaines dettes
  for (const e of entries) {
    if (e.amount > 0) {
      const used = Math.min(credit, e.amount);
      credit -= used;
      if (e.amount - used > 0) open.push({ amount: e.amount - used, at: e.occurredAt });
    } else {
      let pay = -e.amount;
      while (pay > 0 && open.length) {
        const first = open[0];
        const take = Math.min(pay, first.amount);
        first.amount -= take;
        pay -= take;
        if (first.amount === 0) open.shift();
      }
      credit += pay;
    }
  }
  return open.length ? open[0].at : null;
}

/** Fiche client, annuaire et carnet de crédit (lecture). Les écritures du carnet passent par ici ou SalesService. */
@Injectable()
export class CustomersService {
  constructor(
    private readonly dbs: DbService,
    private readonly outbox: OutboxService,
    private readonly salesService: SalesService,
  ) {}

  /** Annuaire des clients avec leur solde réel (carnet) et leurs achats. */
  list(
    businessId: string,
    q: { search?: string; filter: CustomerFilter; sort: CustomerSort; limit: number; offset: number },
  ) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const search = q.search ? `%${q.search}%` : null;
      const filter =
        q.filter === 'debt'
          ? sql`AND coalesce(l.balance, 0) > 0`
          : q.filter === 'over_limit'
            ? sql`AND c.credit_limit IS NOT NULL AND coalesce(l.balance, 0) > c.credit_limit`
            : sql``;
      const order =
        q.sort === 'balance'
          ? sql`coalesce(l.balance, 0) DESC, lower(c.name)`
          : q.sort === 'recent'
            ? sql`s.last_purchase_at DESC NULLS LAST, lower(c.name)`
            : sql`lower(c.name), c.id`;
      const base = sql`
        FROM contacts.contacts c
        LEFT JOIN (
          SELECT customer_id, sum(amount)::bigint AS balance,
                 min(occurred_at) FILTER (WHERE entry_type = 'debt') AS first_debt_at
          FROM sales.customer_ledger GROUP BY customer_id
        ) l ON l.customer_id = c.id
        LEFT JOIN (
          SELECT customer_id, count(*)::int AS sales_count, sum(total)::bigint AS total_spent, max(sold_at) AS last_purchase_at
          FROM sales.sales WHERE status = 'completed' AND customer_id IS NOT NULL GROUP BY customer_id
        ) s ON s.customer_id = c.id
        WHERE c.deleted_at IS NULL AND c.type <> 'supplier'
          ${search ? sql`AND (c.name ILIKE ${search} OR c.phone ILIKE ${search})` : sql``}
          ${filter}`;
      const rows = (
        await tx.execute(sql`
          SELECT c.id, c.name, c.phone, c.credit_limit, c.last_reminded_at,
                 coalesce(l.balance, 0)::bigint AS balance, l.first_debt_at,
                 coalesce(s.sales_count, 0) AS sales_count, coalesce(s.total_spent, 0)::bigint AS total_spent,
                 s.last_purchase_at
          ${base}
          ORDER BY ${order}
          LIMIT ${q.limit + 1} OFFSET ${q.offset}`)
      ).rows as Record<string, unknown>[];
      // Totaux sur tout l'annuaire (hors recherche et filtre) : en-tête de l'écran
      const [totals] = (
        await tx.execute(sql`
          SELECT count(*)::int AS customers,
                 count(*) FILTER (WHERE coalesce(l.balance, 0) > 0)::int AS debtors,
                 coalesce(sum(l.balance) FILTER (WHERE l.balance > 0), 0)::bigint AS total_due,
                 count(*) FILTER (WHERE c.credit_limit IS NOT NULL AND coalesce(l.balance, 0) > c.credit_limit)::int AS over_limit
          FROM contacts.contacts c
          LEFT JOIN (SELECT customer_id, sum(amount)::bigint AS balance FROM sales.customer_ledger GROUP BY customer_id) l
            ON l.customer_id = c.id
          WHERE c.deleted_at IS NULL AND c.type <> 'supplier'`)
      ).rows as Record<string, unknown>[];
      const hasMore = rows.length > q.limit;
      return {
        data: rows.slice(0, q.limit).map((r) => ({
          id: r.id,
          name: r.name,
          phone: r.phone,
          balance: Number(r.balance),
          creditLimit: r.credit_limit === null ? null : Number(r.credit_limit),
          salesCount: Number(r.sales_count),
          totalSpent: Number(r.total_spent),
          lastPurchaseAt: r.last_purchase_at ?? null,
          firstDebtAt: r.first_debt_at ?? null,
          lastRemindedAt: r.last_reminded_at ?? null,
        })),
        nextOffset: hasMore ? q.offset + q.limit : null,
        totals: {
          customers: Number(totals.customers),
          debtors: Number(totals.debtors),
          totalDue: Number(totals.total_due),
          overLimit: Number(totals.over_limit),
        },
      };
    });
  }

  /** Fiche client complète : coordonnées, solde, statistiques d'achat, achats récents, carnet de crédit. */
  overview(businessId: string, customerId: string) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const [c] = (
        await tx.execute(sql`
          SELECT id, type, name, phone, email, address, notes, credit_limit, last_reminded_at, birth_day, birth_month,
                 created_at, deleted_at
          FROM contacts.contacts WHERE id = ${customerId}`)
      ).rows as Record<string, unknown>[];
      if (!c || c.deleted_at) throw AppError.notFound('Client');

      const [stats] = (
        await tx.execute(sql`
          SELECT count(*)::int AS sales_count, coalesce(sum(total), 0)::bigint AS total_spent,
                 coalesce(sum(paid), 0)::bigint AS total_paid,
                 min(sold_at) AS first_purchase_at, max(sold_at) AS last_purchase_at
          FROM sales.sales WHERE customer_id = ${customerId} AND status = 'completed'`)
      ).rows as Record<string, unknown>[];
      const [inv] = (
        await tx.execute(sql`
          SELECT count(*)::int AS open_count, coalesce(sum(total - paid), 0)::bigint AS open_due
          FROM invoicing.documents
          WHERE customer_id = ${customerId} AND kind = 'invoice' AND status IN ('unpaid', 'partial')`)
      ).rows as Record<string, unknown>[];
      const recentSales = (
        await tx.execute(sql`
          SELECT id, number, total, paid, status, sold_at,
                 (SELECT count(*)::int FROM sales.sale_items i WHERE i.sale_id = s.id) AS item_count
          FROM sales.sales s WHERE customer_id = ${customerId}
          ORDER BY sold_at DESC, id DESC LIMIT 20`)
      ).rows as Record<string, unknown>[];
      const topProducts = (
        await tx.execute(sql`
          SELECT i.name, sum(i.quantity)::float AS quantity, sum(i.total)::bigint AS total
          FROM sales.sale_items i JOIN sales.sales s ON s.id = i.sale_id
          WHERE s.customer_id = ${customerId} AND s.status = 'completed'
          GROUP BY i.name ORDER BY sum(i.total) DESC LIMIT 5`)
      ).rows as Record<string, unknown>[];

      const entries = await this.ledgerAsc(tx, customerId);
      let running = 0;
      const withBalance = entries.map((e) => {
        running += e.amount;
        return { ...e, balanceAfter: running };
      });
      const balance = running;
      const salesCount = Number(stats.sales_count);
      const totalSpent = Number(stats.total_spent);
      const creditLimit = c.credit_limit === null ? null : Number(c.credit_limit);

      return {
        customer: {
          id: c.id,
          type: c.type,
          name: c.name,
          phone: c.phone,
          email: c.email,
          address: c.address,
          notes: c.notes,
          creditLimit,
          lastRemindedAt: c.last_reminded_at ?? null,
          birthDay: c.birth_day ?? null,
          birthMonth: c.birth_month ?? null,
          createdAt: c.created_at,
        },
        balance,
        creditLimit,
        availableCredit: creditLimit === null ? null : Math.max(0, creditLimit - balance),
        oldestUnpaidAt: balance > 0 ? oldestUnpaidDebt(entries) : null,
        stats: {
          salesCount,
          totalSpent,
          totalPaid: Number(stats.total_paid),
          averageBasket: salesCount ? Math.round(totalSpent / salesCount) : 0,
          firstPurchaseAt: stats.first_purchase_at ?? null,
          lastPurchaseAt: stats.last_purchase_at ?? null,
          openInvoices: Number(inv.open_count),
          openInvoicesDue: Number(inv.open_due),
        },
        topProducts: topProducts.map((p) => ({ name: p.name, quantity: Number(p.quantity), total: Number(p.total) })),
        recentSales: recentSales.map((s) => ({
          id: s.id,
          number: s.number,
          total: Number(s.total),
          paid: Number(s.paid),
          due: Number(s.total) - Number(s.paid),
          status: s.status,
          soldAt: s.sold_at,
          itemCount: Number(s.item_count),
        })),
        // Du plus récent au plus ancien, avec le solde après chaque mouvement (relevé de compte)
        entries: withBalance.reverse().slice(0, 300),
      };
    });
  }

  /** Ajustement manuel : reprise d'une ancienne dette (montant positif) ou remise de dette (négatif). */
  adjust(
    businessId: string,
    actorId: string,
    customerId: string,
    input: { amount: number; reason: string },
    warehouseId: string | null = null,
  ) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const [c] = (
        await tx.execute(sql`SELECT id, type, deleted_at FROM contacts.contacts WHERE id = ${customerId} FOR UPDATE`)
      ).rows as { id: string; type: string; deleted_at: Date | null }[];
      if (!c || c.deleted_at) throw AppError.notFound('Client');
      if (c.type === 'supplier') throw new AppError('VALIDATION_FAILED', 'Ce contact est un fournisseur', 422);
      const balance = await this.salesService.balance(tx, customerId);
      if (input.amount < 0 && -input.amount > balance) {
        throw new AppError(
          'REPAYMENT_EXCEEDS_BALANCE',
          `Vous effacez plus que la dette du client (${fcfa(Math.max(0, balance))})`,
          422,
          { balance },
        );
      }
      const entryId = newId();
      await tx.insert(customerLedger).values({
        id: entryId,
        businessId,
        customerId,
        entryType: 'adjustment',
        amount: input.amount,
        refType: input.amount > 0 ? 'opening_debt' : 'write_off',
        note: input.reason,
        warehouseId,
        occurredAt: new Date(),
        createdBy: actorId,
      });
      await this.outbox.record(tx, {
        type: 'customer.balance_adjusted',
        businessId,
        aggregateId: customerId,
        actorId,
        payload: { entryId, customerId, amount: input.amount, reason: input.reason },
      });
      return { entryId, balance: balance + input.amount };
    });
  }

  /** Note qu'un rappel de paiement vient d'être envoyé (WhatsApp ou SMS, depuis le téléphone). */
  private async ledgerAsc(tx: Tx, customerId: string): Promise<LedgerRow[]> {
    const rows = (
      await tx.execute(sql`
        SELECT id, entry_type, amount, method, ref_type, ref_id, note, occurred_at
        FROM sales.customer_ledger WHERE customer_id = ${customerId}
        ORDER BY occurred_at, id`)
    ).rows as Record<string, unknown>[];
    return rows.map((r) => ({
      id: r.id as string,
      entryType: r.entry_type as string,
      amount: Number(r.amount),
      method: (r.method as string) ?? null,
      refType: (r.ref_type as string) ?? null,
      refId: (r.ref_id as string) ?? null,
      note: (r.note as string) ?? null,
      occurredAt: new Date(r.occurred_at as string),
    }));
  }
}
