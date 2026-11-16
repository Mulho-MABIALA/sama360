import { Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { DbService, Tx } from '../../shared/db/db.service';
import { AppError } from '../../shared/http/app-error';
import { newId } from '../../shared/ids';
import { fcfa } from './sales.service';

export const CASH_METHODS = ['cash', 'wave', 'orange_money', 'free_money', 'card', 'transfer', 'cheque'] as const;
export type CashMethod = (typeof CASH_METHODS)[number];

/** Montants d'une session pour un moyen de paiement. */
export interface MethodLine {
  method: CashMethod;
  opening: number;
  sales: number;
  repayments: number;
  invoices: number;
  expenses: number;
  suppliers: number;
  movementsIn: number;
  movementsOut: number;
  expected: number;
}

export interface CashFlows {
  sales: Partial<Record<string, number>>;
  repayments: Partial<Record<string, number>>;
  invoices: Partial<Record<string, number>>;
  expenses: Partial<Record<string, number>>;
  suppliers: Partial<Record<string, number>>;
  movementsIn: number;
  movementsOut: number;
}

/**
 * Attendu par moyen de paiement : fond de caisse (espèces) + encaissements − décaissements.
 * Les espèces apparaissent toujours ; les autres moyens seulement s'il y a eu du mouvement.
 */
export function expectedByMethod(openingFloat: number, f: CashFlows): MethodLine[] {
  const v = (m: Partial<Record<string, number>>, k: string) => m[k] ?? 0;
  return CASH_METHODS.map((method) => {
    const cash = method === 'cash';
    const line: MethodLine = {
      method,
      opening: cash ? openingFloat : 0,
      sales: v(f.sales, method),
      repayments: v(f.repayments, method),
      invoices: v(f.invoices, method),
      expenses: v(f.expenses, method),
      suppliers: v(f.suppliers, method),
      movementsIn: cash ? f.movementsIn : 0,
      movementsOut: cash ? f.movementsOut : 0,
      expected: 0,
    };
    line.expected =
      line.opening + line.sales + line.repayments + line.invoices + line.movementsIn -
      line.expenses - line.suppliers - line.movementsOut;
    return line;
  }).filter(
    (l) =>
      l.method === 'cash' ||
      l.sales || l.repayments || l.invoices || l.expenses || l.suppliers,
  );
}

/** Écarts compté − attendu, par moyen et au total. Un moyen non compté vaut son attendu (pas d'écart). */
export function differences(lines: MethodLine[], counted: Partial<Record<string, number>>) {
  const byMethod = lines.map((l) => {
    const c = counted[l.method] ?? l.expected;
    return { method: l.method, expected: l.expected, counted: c, difference: c - l.expected };
  });
  return { byMethod, total: byMethod.reduce((s, m) => s + m.difference, 0) };
}

type Row = Record<string, unknown>;
const sumBy = (rows: Row[]) =>
  Object.fromEntries(rows.map((r) => [r.method as string, Number(r.amount)])) as Record<string, number>;

/** Caisse : une session par vendeur, de l'ouverture (fond de caisse) à la clôture (comptage, rapport Z). */
@Injectable()
export class CashService {
  constructor(private readonly dbs: DbService) {}

  open(businessId: string, userId: string, input: { openingFloat: number; note?: string | null }) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const existing = await this.openFor(tx, userId);
      if (existing) {
        throw new AppError('CONFLICT', `Votre caisse est déjà ouverte depuis ${existing.number}`, 409, {
          sessionId: existing.id,
        });
      }
      const id = newId();
      const year = new Date().getUTCFullYear();
      const seq = await tx.execute(sql`
        INSERT INTO sales.sequences (business_id, key, year, last_value) VALUES (${businessId}, 'cash', ${year}, 1)
        ON CONFLICT (business_id, key, year) DO UPDATE SET last_value = sales.sequences.last_value + 1
        RETURNING last_value`);
      const n = (seq.rows[0] as { last_value: number }).last_value;
      await tx.execute(sql`
        INSERT INTO sales.cash_sessions (id, business_id, number, user_id, opening_float, opening_note)
        VALUES (${id}, ${businessId}, ${`Z-${year}-${String(n).padStart(4, '0')}`}, ${userId}, ${input.openingFloat},
                ${input.note?.trim() || null})`);
      return this.detail(tx, id);
    });
  }

  /** Ma caisse ouverte, avec l'attendu en direct (null si fermée). */
  current(businessId: string, userId: string) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const s = await this.openFor(tx, userId);
      return s ? this.detail(tx, s.id as string) : null;
    });
  }

  addMovement(
    businessId: string,
    userId: string,
    input: { direction: 'in' | 'out'; amount: number; reason: string },
  ) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const s = await this.openFor(tx, userId);
      if (!s) throw new AppError('CONFLICT', 'Ouvrez d’abord votre caisse', 409);
      if (input.direction === 'out') {
        const report = await this.report(tx, s);
        const cash = report.methods.find((m) => m.method === 'cash')!.expected;
        if (input.amount > cash) {
          throw new AppError('VALIDATION_FAILED', `Il n’y a que ${fcfa(Math.max(0, cash))} en espèces dans la caisse`, 422, {
            cash,
          });
        }
      }
      await tx.execute(sql`
        INSERT INTO sales.cash_movements (id, business_id, session_id, direction, amount, reason, created_by)
        VALUES (${newId()}, ${businessId}, ${s.id}, ${input.direction}, ${input.amount}, ${input.reason.trim()}, ${userId})`);
      return this.detail(tx, s.id as string);
    });
  }

  /**
   * Clôture : fige l'attendu, le compté et les écarts. Ma caisse, ou celle d'un vendeur
   * (gérant) si [sessionId] est donné.
   */
  close(
    businessId: string,
    userId: string,
    input: { sessionId?: string; counted: Partial<Record<CashMethod, number>>; note?: string | null },
    canManage: boolean,
  ) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const s = input.sessionId ? await this.lock(tx, input.sessionId) : await this.openFor(tx, userId, true);
      if (!s) throw new AppError('CONFLICT', 'Aucune caisse ouverte', 409);
      if (s.user_id !== userId && !canManage) throw AppError.forbidden('Seul le gérant peut clôturer la caisse d’un vendeur');
      if (s.status !== 'open') throw new AppError('DOCUMENT_LOCKED', 'Cette caisse est déjà clôturée', 409);

      const closedAt = new Date();
      const report = await this.report(tx, s, closedAt);
      const diff = differences(report.methods, input.counted);
      const expected = Object.fromEntries(report.methods.map((m) => [m.method, m.expected]));
      const counted = Object.fromEntries(diff.byMethod.map((m) => [m.method, m.counted]));
      await tx.execute(sql`
        UPDATE sales.cash_sessions SET status = 'closed', closed_at = ${closedAt}, closed_by = ${userId},
          expected = ${JSON.stringify(expected)}::jsonb, counted = ${JSON.stringify(counted)}::jsonb,
          difference = ${diff.total}, summary = ${JSON.stringify(report)}::jsonb, closing_note = ${input.note?.trim() || null}
        WHERE id = ${s.id}`);
      return this.detail(tx, s.id as string);
    });
  }

  list(businessId: string, userId: string, q: { userId?: string; limit: number; offset: number }, canManage: boolean) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const who = canManage ? q.userId : userId;
      const rows = (
        await tx.execute(sql`
          SELECT s.id, s.number, s.status, s.user_id, u.full_name, s.opening_float, s.opened_at, s.closed_at,
                 s.difference, s.summary->>'salesTotal' AS sales_total, s.summary->>'salesCount' AS sales_count,
                 (SELECT sum((v)::bigint) FROM jsonb_each_text(s.counted) AS e(k, v)) AS counted_total
          FROM sales.cash_sessions s LEFT JOIN core.users u ON u.id = s.user_id
          WHERE true ${who ? sql`AND s.user_id = ${who}` : sql``}
          ORDER BY s.opened_at DESC, s.id DESC LIMIT ${q.limit + 1} OFFSET ${q.offset}`)
      ).rows as Row[];
      return {
        data: rows.slice(0, q.limit).map((r) => ({
          id: r.id,
          number: r.number,
          status: r.status,
          userId: r.user_id,
          userName: r.full_name ?? null,
          openingFloat: Number(r.opening_float),
          openedAt: r.opened_at,
          closedAt: r.closed_at ?? null,
          salesTotal: r.sales_total === null ? null : Number(r.sales_total),
          salesCount: r.sales_count === null ? null : Number(r.sales_count),
          countedTotal: r.counted_total === null ? null : Number(r.counted_total),
          difference: r.difference === null ? null : Number(r.difference),
        })),
        nextOffset: rows.length > q.limit ? q.offset + q.limit : null,
      };
    });
  }

  get(businessId: string, userId: string, id: string, canManage: boolean) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const d = await this.detail(tx, id);
      if (d.userId !== userId && !canManage) throw AppError.forbidden('Vous ne voyez que vos propres caisses');
      return d;
    });
  }

  // ------------------------------------------------------------------ interne

  private async openFor(tx: Tx, userId: string, lock = false): Promise<Row | null> {
    const [s] = (
      await tx.execute(sql`
        SELECT * FROM sales.cash_sessions WHERE user_id = ${userId} AND status = 'open'
        ${lock ? sql`FOR UPDATE` : sql``}`)
    ).rows as Row[];
    return s ?? null;
  }

  private async lock(tx: Tx, id: string): Promise<Row> {
    const [s] = (await tx.execute(sql`SELECT * FROM sales.cash_sessions WHERE id = ${id} FOR UPDATE`)).rows as Row[];
    if (!s) throw AppError.notFound('Caisse');
    return s;
  }

  /** Rapport Z : flux du vendeur entre l'ouverture et [until] (maintenant par défaut). */
  private async report(tx: Tx, s: Row, until: Date = new Date()) {
    const u = s.user_id as string;
    const from = s.opened_at as Date;
    const salesRows = (
      await tx.execute(sql`
        SELECT p.method, sum(p.amount)::bigint AS amount
        FROM sales.sale_payments p JOIN sales.sales s ON s.id = p.sale_id
        WHERE s.cashier_id = ${u} AND s.status = 'completed' AND s.sold_at >= ${from} AND s.sold_at <= ${until}
        GROUP BY p.method`)
    ).rows as Row[];
    const [stats] = (
      await tx.execute(sql`
        SELECT count(*) FILTER (WHERE status = 'completed')::int AS sales_count,
               coalesce(sum(total) FILTER (WHERE status = 'completed'), 0)::bigint AS sales_total,
               coalesce(sum(total - paid) FILTER (WHERE status = 'completed'), 0)::bigint AS credit_total,
               coalesce(sum(discount) FILTER (WHERE status = 'completed'), 0)::bigint AS discount_total,
               count(*) FILTER (WHERE status = 'voided')::int AS voided_count,
               coalesce(sum(total) FILTER (WHERE status = 'voided'), 0)::bigint AS voided_total
        FROM sales.sales WHERE cashier_id = ${u} AND sold_at >= ${from} AND sold_at <= ${until}`)
    ).rows as Row[];
    const repayments = (
      await tx.execute(sql`
        SELECT coalesce(method, 'cash') AS method, sum(-amount)::bigint AS amount FROM sales.customer_ledger
        WHERE entry_type = 'repayment' AND created_by = ${u} AND occurred_at >= ${from} AND occurred_at <= ${until}
        GROUP BY 1`)
    ).rows as Row[];
    const invoices = (
      await tx.execute(sql`
        SELECT method, sum(amount)::bigint AS amount FROM invoicing.payments
        WHERE created_by = ${u} AND paid_at >= ${from} AND paid_at <= ${until} GROUP BY method`)
    ).rows as Row[];
    const expenses = (
      await tx.execute(sql`
        SELECT coalesce(method, 'cash') AS method, sum(amount)::bigint AS amount FROM sales.expenses
        WHERE created_by = ${u} AND created_at >= ${from} AND created_at <= ${until} GROUP BY 1`)
    ).rows as Row[];
    const suppliers = (
      await tx.execute(sql`
        SELECT method, sum(amount)::bigint AS amount FROM purchasing.payments
        WHERE created_by = ${u} AND paid_at >= ${from} AND paid_at <= ${until} GROUP BY method`)
    ).rows as Row[];
    const [mv] = (
      await tx.execute(sql`
        SELECT coalesce(sum(amount) FILTER (WHERE direction = 'in'), 0)::bigint AS ins,
               coalesce(sum(amount) FILTER (WHERE direction = 'out'), 0)::bigint AS outs
        FROM sales.cash_movements WHERE session_id = ${s.id}`)
    ).rows as Row[];

    const methods = expectedByMethod(Number(s.opening_float), {
      sales: sumBy(salesRows),
      repayments: sumBy(repayments),
      invoices: sumBy(invoices),
      expenses: sumBy(expenses),
      suppliers: sumBy(suppliers),
      movementsIn: Number(mv.ins),
      movementsOut: Number(mv.outs),
    });
    return {
      until: until.toISOString(),
      salesCount: Number(stats.sales_count),
      salesTotal: Number(stats.sales_total),
      creditTotal: Number(stats.credit_total),
      discountTotal: Number(stats.discount_total),
      voidedCount: Number(stats.voided_count),
      voidedTotal: Number(stats.voided_total),
      methods,
      expectedTotal: methods.reduce((t, m) => t + m.expected, 0),
    };
  }

  private async detail(tx: Tx, id: string) {
    const [s] = (
      await tx.execute(sql`
        SELECT s.*, u.full_name AS user_name, c.full_name AS closed_by_name
        FROM sales.cash_sessions s
        LEFT JOIN core.users u ON u.id = s.user_id LEFT JOIN core.users c ON c.id = s.closed_by
        WHERE s.id = ${id}`)
    ).rows as Row[];
    if (!s) throw AppError.notFound('Caisse');
    const movements = (
      await tx.execute(sql`
        SELECT m.id, m.direction, m.amount, m.reason, m.created_at, u.full_name
        FROM sales.cash_movements m LEFT JOIN core.users u ON u.id = m.created_by
        WHERE m.session_id = ${id} ORDER BY m.created_at, m.id`)
    ).rows as Row[];
    const closed = s.status === 'closed';
    // Clôturée : le rapport figé ; ouverte : calcul en direct
    const report = closed ? (s.summary as Awaited<ReturnType<CashService['report']>>) : await this.report(tx, s);
    const counted = (s.counted as Record<string, number> | null) ?? null;
    return {
      id: s.id as string,
      number: s.number as string,
      status: s.status as 'open' | 'closed',
      userId: s.user_id as string,
      userName: (s.user_name as string) ?? null,
      openingFloat: Number(s.opening_float),
      openingNote: (s.opening_note as string) ?? null,
      openedAt: s.opened_at as Date,
      closedAt: (s.closed_at as Date) ?? null,
      closedByName: (s.closed_by_name as string) ?? null,
      closingNote: (s.closing_note as string) ?? null,
      report,
      counted,
      difference: s.difference === null ? null : Number(s.difference),
      lines: closed && counted ? differences(report.methods, counted).byMethod : null,
      movements: movements.map((m) => ({
        id: m.id,
        direction: m.direction,
        amount: Number(m.amount),
        reason: m.reason,
        createdAt: m.created_at,
        createdByName: m.full_name ?? null,
      })),
    };
  }
}
