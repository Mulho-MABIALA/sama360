import { Injectable } from '@nestjs/common';
import { hasPermission } from '@sama360/contracts';
import { sql } from 'drizzle-orm';
import { DbService, Tx } from '../../shared/db/db.service';
import { AppError } from '../../shared/http/app-error';
import { newId } from '../../shared/ids';
import { oldestUnpaidDebt } from './customers.service';

/** On ne relance pas la même personne plus d'une fois par semaine. */
export const REMIND_EVERY_DAYS = 7;
/** Un crédit récent (moins d'une semaine) n'est pas encore à relancer. */
export const CREDIT_GRACE_DAYS = 7;
/** Une facture sans échéance est à relancer 15 jours après son émission. */
export const INVOICE_DEFAULT_TERM_DAYS = 15;

export type ReminderChannel = 'whatsapp' | 'sms' | 'call';

export interface ReminderItem {
  kind: 'credit' | 'invoice';
  /** Client (crédit) ou facture. */
  id: string;
  customerId: string;
  name: string;
  phone: string | null;
  amount: number;
  /** Crédit : date de la plus ancienne dette non remboursée. Facture : échéance (ou émission + 15 j). */
  since: string | null;
  /** Jours de retard (négatif : pas encore échu). */
  daysLate: number;
  invoiceNumber: string | null;
  lastRemindedAt: string | null;
  /** À relancer aujourd'hui. */
  due: boolean;
}

const DAY = 86_400_000;
const startOfDay = (d: Date) => Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate());
export const daysBetween = (from: Date, to: Date) => Math.round((startOfDay(to) - startOfDay(from)) / DAY);

/** Faut-il relancer aujourd'hui ? En retard (au-delà du délai de grâce) et pas relancé depuis une semaine. */
export function isDue(item: Pick<ReminderItem, 'kind' | 'daysLate' | 'lastRemindedAt'>, now: Date): boolean {
  const late = item.kind === 'credit' ? item.daysLate >= CREDIT_GRACE_DAYS : item.daysLate > 0;
  if (!late) return false;
  if (!item.lastRemindedAt) return true;
  return daysBetween(new Date(item.lastRemindedAt), now) >= REMIND_EVERY_DAYS;
}

/** Ordre de la liste : à relancer d'abord, puis les plus en retard, puis les plus gros montants. */
export function byPriority(a: ReminderItem, b: ReminderItem): number {
  if (a.due !== b.due) return a.due ? -1 : 1;
  if (a.daysLate !== b.daysLate) return b.daysLate - a.daysLate;
  return b.amount - a.amount;
}

const iso = (v: unknown) => (v === null || v === undefined ? null : new Date(v as string).toISOString());

@Injectable()
export class RemindersService {
  constructor(private readonly dbs: DbService) {}

  /** File des relances : crédits clients et factures impayées, avec l'historique récent. */
  queue(businessId: string, permissions: readonly string[], now = new Date()) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const items: ReminderItem[] = [];
      if (hasPermission(permissions, 'contacts:read')) items.push(...(await this.credits(tx, now)));
      if (hasPermission(permissions, 'invoicing:read') && (await this.moduleOn(tx, 'invoicing'))) {
        items.push(...(await this.invoices(tx, now)));
      }
      items.sort(byPriority);
      const due = items.filter((i) => i.due);
      const history = (
        await tx.execute(sql`
          SELECT r.id, r.channel, r.amount, r.created_at, r.customer_id, r.invoice_id,
                 c.name AS customer_name, d.number AS invoice_number, u.full_name AS by_name
          FROM sales.reminders r
          JOIN contacts.contacts c ON c.id = r.customer_id
          LEFT JOIN invoicing.documents d ON d.id = r.invoice_id
          LEFT JOIN core.users u ON u.id = r.created_by
          ORDER BY r.created_at DESC
          LIMIT 30`)
      ).rows as Record<string, unknown>[];
      return {
        items,
        summary: {
          dueCount: due.length,
          dueAmount: due.reduce((s, i) => s + i.amount, 0),
          totalCount: items.length,
          totalAmount: items.reduce((s, i) => s + i.amount, 0),
          remindedThisWeek: history.filter((h) => daysBetween(new Date(h.created_at as string), now) < 7).length,
        },
        history: history.map((h) => ({
          id: h.id as string,
          channel: h.channel as ReminderChannel,
          amount: Number(h.amount),
          at: iso(h.created_at)!,
          customerId: h.customer_id as string,
          customerName: h.customer_name as string,
          invoiceId: (h.invoice_id as string) ?? null,
          invoiceNumber: (h.invoice_number as string) ?? null,
          byName: (h.by_name as string) ?? null,
        })),
      };
    });
  }

  /** Note qu'un client (son crédit) ou une facture vient d'être relancé. */
  record(
    businessId: string,
    userId: string,
    permissions: readonly string[],
    input: { kind: 'credit' | 'invoice'; id: string; channel: ReminderChannel },
  ) {
    return this.dbs.withTenant(businessId, async (tx) => {
      let customerId: string;
      let invoiceId: string | null = null;
      let amount: number;
      if (input.kind === 'credit') {
        if (!hasPermission(permissions, 'contacts:write')) throw AppError.forbidden();
        const r = (
          await tx.execute(sql`
            UPDATE contacts.contacts SET last_reminded_at = now()
            WHERE id = ${input.id} AND deleted_at IS NULL AND type <> 'supplier'
            RETURNING id, balance`)
        ).rows[0] as { id: string; balance: string } | undefined;
        if (!r) throw AppError.notFound('Client');
        customerId = r.id;
        amount = Math.max(0, Number(r.balance));
      } else {
        if (!hasPermission(permissions, 'invoicing:read')) throw AppError.forbidden();
        const r = (
          await tx.execute(sql`
            UPDATE invoicing.documents SET last_reminded_at = now()
            WHERE id = ${input.id} AND kind = 'invoice'
            RETURNING id, customer_id, status, total, paid`)
        ).rows[0] as { id: string; customer_id: string; status: string; total: string; paid: string } | undefined;
        if (!r) throw AppError.notFound('Facture');
        if (!['unpaid', 'partial'].includes(r.status)) {
          throw AppError.conflict('Cette facture n’a plus rien à payer');
        }
        customerId = r.customer_id;
        invoiceId = r.id;
        amount = Number(r.total) - Number(r.paid);
      }
      const id = newId();
      await tx.execute(sql`
        INSERT INTO sales.reminders (id, business_id, customer_id, invoice_id, channel, amount, created_by)
        VALUES (${id}, ${businessId}, ${customerId}, ${invoiceId}, ${input.channel}, ${amount}, ${userId})`);
      return { id, lastRemindedAt: new Date().toISOString(), amount };
    });
  }

  private async moduleOn(tx: Tx, module: string) {
    const r = await tx.execute(sql`
      SELECT 1 FROM core.module_activations WHERE module = ${module} AND enabled LIMIT 1`);
    return r.rows.length > 0;
  }

  private async credits(tx: Tx, now: Date): Promise<ReminderItem[]> {
    const rows = (
      await tx.execute(sql`
        SELECT c.id, c.name, c.phone, c.balance, c.last_reminded_at
        FROM contacts.contacts c
        WHERE c.deleted_at IS NULL AND c.type <> 'supplier' AND c.balance > 0`)
    ).rows as Record<string, unknown>[];
    if (rows.length === 0) return [];
    const ledger = (
      await tx.execute(sql`
        SELECT customer_id, amount, occurred_at FROM sales.customer_ledger
        WHERE customer_id IN (${sql.join(
          rows.map((r) => sql`${r.id as string}`),
          sql`, `,
        )})
        ORDER BY customer_id, occurred_at, id`)
    ).rows as Record<string, unknown>[];
    const byCustomer = new Map<string, { amount: number; occurredAt: Date }[]>();
    for (const l of ledger) {
      const list = byCustomer.get(l.customer_id as string) ?? [];
      list.push({ amount: Number(l.amount), occurredAt: new Date(l.occurred_at as string) });
      byCustomer.set(l.customer_id as string, list);
    }
    return rows.map((r) => {
      const since = oldestUnpaidDebt(byCustomer.get(r.id as string) ?? []);
      const item: ReminderItem = {
        kind: 'credit',
        id: r.id as string,
        customerId: r.id as string,
        name: r.name as string,
        phone: (r.phone as string) ?? null,
        amount: Number(r.balance),
        since: since?.toISOString() ?? null,
        daysLate: since ? daysBetween(since, now) : 0,
        invoiceNumber: null,
        lastRemindedAt: iso(r.last_reminded_at),
        due: false,
      };
      item.due = isDue(item, now);
      return item;
    });
  }

  private async invoices(tx: Tx, now: Date): Promise<ReminderItem[]> {
    const rows = (
      await tx.execute(sql`
        SELECT d.id, d.number, d.customer_id, d.total, d.paid, d.due_date, d.issue_date, d.created_at,
               d.last_reminded_at, c.name, c.phone
        FROM invoicing.documents d
        JOIN contacts.contacts c ON c.id = d.customer_id
        WHERE d.kind = 'invoice' AND d.status IN ('unpaid', 'partial')`)
    ).rows as Record<string, unknown>[];
    return rows.map((r) => {
      const issued = new Date((r.issue_date ?? r.created_at) as string);
      const dueDate = r.due_date
        ? new Date(r.due_date as string)
        : new Date(startOfDay(issued) + INVOICE_DEFAULT_TERM_DAYS * DAY);
      const item: ReminderItem = {
        kind: 'invoice',
        id: r.id as string,
        customerId: r.customer_id as string,
        name: r.name as string,
        phone: (r.phone as string) ?? null,
        amount: Number(r.total) - Number(r.paid),
        since: dueDate.toISOString(),
        daysLate: daysBetween(dueDate, now),
        invoiceNumber: r.number as string,
        lastRemindedAt: iso(r.last_reminded_at),
        due: false,
      };
      item.due = isDue(item, now);
      return item;
    });
  }
}
