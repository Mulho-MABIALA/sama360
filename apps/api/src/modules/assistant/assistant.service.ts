import { Injectable, Logger } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { TenantContext } from '../../shared/auth/auth.types';
import { env } from '../../shared/config/env';
import { DbService, Tx } from '../../shared/db/db.service';
import { AppError } from '../../shared/http/app-error';
import { fillHours, fillWeekdays, peakWindow, bestWeekday, WEEKDAYS } from '../sales/insights';
import {
  Period,
  periodRange,
  PERIODS,
  suggestionsFor,
  systemPrompt,
  ToolName,
  toolResultText,
  toolsFor,
} from './assistant';
import { ContentBlock, LlmClient, LlmMessage, LlmUnavailableError } from './llm';

type Row = Record<string, unknown>;
const n = (v: unknown) => Number(v ?? 0);
const MAX_ROUNDS = 5;

export interface ChatTurn {
  role: 'user' | 'assistant';
  content: string;
}

@Injectable()
export class AssistantService {
  private readonly logger = new Logger(AssistantService.name);

  constructor(
    private readonly dbs: DbService,
    private readonly llm: LlmClient,
  ) {}

  get enabled() {
    return env().ASSISTANT_PROVIDER !== 'off';
  }

  private async usedToday(tx: Tx): Promise<number> {
    const r = (await tx.execute(sql`SELECT questions FROM core.assistant_usage WHERE day = current_date`)).rows[0] as
      { questions: number } | undefined;
    return n(r?.questions);
  }

  status(t: TenantContext) {
    return this.dbs.withTenant(t.businessId, async (tx) => ({
      enabled: this.enabled,
      remaining: Math.max(0, env().ASSISTANT_DAILY_LIMIT - (await this.usedToday(tx))),
      suggestions: suggestionsFor(t.permissions),
    }));
  }

  async chat(t: TenantContext, userId: string, turns: ChatTurn[]) {
    if (!this.enabled) {
      throw new AppError('ASSISTANT_DISABLED', "L'assistant n'est pas encore activé sur ce serveur", 503);
    }
    const limit = env().ASSISTANT_DAILY_LIMIT;
    // Compte la question avant l'appel (même si le modèle échoue) : plafond fiable
    const { used, businessName, userName } = await this.dbs.withTenant(t.businessId, async (tx) => {
      const r = (
        await tx.execute(sql`
          INSERT INTO core.assistant_usage (business_id, day, questions) VALUES (${t.businessId}, current_date, 1)
          ON CONFLICT (business_id, day) DO UPDATE SET questions = core.assistant_usage.questions + 1
          RETURNING questions`)
      ).rows[0] as { questions: number };
      const b = (await tx.execute(sql`SELECT name FROM core.businesses WHERE id = ${t.businessId}`)).rows[0] as Row;
      const u = (await tx.execute(sql`SELECT full_name FROM core.users WHERE id = ${userId}`)).rows[0] as
        Row | undefined;
      return {
        used: n(r.questions),
        businessName: String(b?.name ?? 'Ma boutique'),
        userName: (u?.full_name as string) ?? null,
      };
    });
    if (used > limit) {
      throw new AppError('ASSISTANT_LIMIT', `Limite de ${limit} questions par jour atteinte. Réessayez demain.`, 429);
    }

    const tools = toolsFor(t.permissions);
    const allowed = new Set(tools.map((x) => x.name));
    const messages: LlmMessage[] = turns.map((m) => ({ role: m.role, content: m.content }));
    const system = systemPrompt({ businessName, userName, role: t.roleKey });
    const used_tools: string[] = [];

    for (let round = 0; round <= MAX_ROUNDS; round++) {
      let res;
      try {
        res = await this.llm.complete({
          system,
          messages,
          tools: tools.map(({ name, description, input_schema }) => ({ name, description, input_schema })),
        });
      } catch (e) {
        this.logger.warn((e as Error).message);
        if (e instanceof LlmUnavailableError) {
          throw new AppError(
            'ASSISTANT_UNAVAILABLE',
            "L'assistant ne répond pas pour le moment. Réessayez dans un instant.",
            503,
          );
        }
        throw e;
      }
      const calls = res.content.filter((b): b is Extract<ContentBlock, { type: 'tool_use' }> => b.type === 'tool_use');
      if (res.stopReason !== 'tool_use' || calls.length === 0 || round === MAX_ROUNDS) {
        const reply = res.content
          .filter((b): b is Extract<ContentBlock, { type: 'text' }> => b.type === 'text')
          .map((b) => b.text)
          .join('\n')
          .trim();
        return {
          reply: reply || "Je n'ai pas trouvé de réponse. Pouvez-vous reformuler ?",
          tools: used_tools,
          remaining: Math.max(0, limit - used),
        };
      }
      messages.push({ role: 'assistant', content: res.content });
      const results: ContentBlock[] = [];
      for (const call of calls) {
        used_tools.push(call.name);
        let content: string;
        let isError = false;
        if (!allowed.has(call.name as ToolName)) {
          content = 'Outil non autorisé pour cette personne.';
          isError = true;
        } else {
          try {
            content = toolResultText(await this.runTool(t, userId, call.name as ToolName, call.input ?? {}));
          } catch (e) {
            this.logger.warn(`Outil ${call.name} : ${(e as Error).message}`);
            content = 'Erreur en lisant les données.';
            isError = true;
          }
        }
        results.push({ type: 'tool_result', tool_use_id: call.id, content, ...(isError ? { is_error: true } : {}) });
      }
      messages.push({ role: 'user', content: results });
    }
    throw new Error('inaccessible');
  }

  /** Outils de lecture seule, exécutés dans la boutique (RLS) et selon les droits de la personne. */
  runTool(t: TenantContext, userId: string, name: ToolName, input: Record<string, unknown>) {
    const period = (PERIODS as readonly string[]).includes(String(input.period)) ? (input.period as Period) : 'today';
    const limit = Math.min(20, Math.max(1, Number(input.limit) || 5));
    return this.dbs.withTenant(t.businessId, async (tx) => {
      switch (name) {
        case 'sales_summary': {
          const r = periodRange(period);
          const s = (
            await tx.execute(sql`
              SELECT count(*)::int AS count, coalesce(sum(total), 0)::bigint AS revenue,
                     coalesce(sum(cost_total), 0)::bigint AS cost,
                     coalesce(sum(total - paid), 0)::bigint AS on_credit
              FROM sales.sales WHERE status = 'completed'
                AND sold_at >= ${r.from}::date AND sold_at < ${r.to}::date + 1`)
          ).rows[0] as Row;
          const e = (
            await tx.execute(sql`SELECT coalesce(sum(amount), 0)::bigint AS total FROM sales.expenses
              WHERE spent_at >= ${r.from}::date AND spent_at <= ${r.to}::date`)
          ).rows[0] as Row;
          const revenue = n(s.revenue);
          const gross = revenue - n(s.cost);
          return {
            period: r,
            salesCount: n(s.count),
            revenue,
            grossProfit: gross,
            expenses: n(e.total),
            netProfit: gross - n(e.total),
            soldOnCredit: n(s.on_credit),
          };
        }
        case 'my_sales_today': {
          const s = (
            await tx.execute(sql`
              SELECT count(*)::int AS count, coalesce(sum(total), 0)::bigint AS revenue FROM sales.sales
              WHERE status = 'completed' AND cashier_id = ${userId} AND sold_at >= current_date`)
          ).rows[0] as Row;
          return { salesCount: n(s.count), revenue: n(s.revenue) };
        }
        case 'top_products': {
          const r = periodRange(period);
          const rows = (
            await tx.execute(sql`
              SELECT i.name, sum(i.quantity) AS quantity, sum(i.total)::bigint AS revenue,
                     sum(i.total - round(i.quantity * i.unit_cost))::bigint AS profit
              FROM sales.sale_items i JOIN sales.sales s ON s.id = i.sale_id
              WHERE s.status = 'completed' AND s.sold_at >= ${r.from}::date AND s.sold_at < ${r.to}::date + 1
              GROUP BY i.name ORDER BY sum(i.total) DESC LIMIT ${limit}`)
          ).rows as Row[];
          return {
            period: r,
            products: rows.map((x) => ({
              name: x.name,
              quantity: n(x.quantity),
              revenue: n(x.revenue),
              profit: n(x.profit),
            })),
          };
        }
        case 'customers_owing': {
          const rows = (
            await tx.execute(sql`
              SELECT name, balance FROM contacts.contacts
              WHERE deleted_at IS NULL AND type IN ('customer', 'both') AND balance > 0
              ORDER BY balance DESC LIMIT ${limit}`)
          ).rows as Row[];
          const total = (
            await tx.execute(sql`SELECT coalesce(sum(balance), 0)::bigint AS due, count(*)::int AS n FROM contacts.contacts
              WHERE deleted_at IS NULL AND type IN ('customer', 'both') AND balance > 0`)
          ).rows[0] as Row;
          return {
            totalDue: n(total.due),
            customersCount: n(total.n),
            customers: rows.map((x) => ({ name: x.name, owes: n(x.balance) })),
          };
        }
        case 'stock_lookup': {
          const q = String(input.search ?? '')
            .trim()
            .slice(0, 60);
          const rows = (
            await tx.execute(sql`
              SELECT p.name, p.price, p.type, p.track_stock, coalesce(sum(st.on_hand), 0) AS on_hand
              FROM catalog.products p LEFT JOIN inventory.stock_levels st ON st.product_id = p.id
              WHERE p.deleted_at IS NULL AND p.name ILIKE ${'%' + q + '%'}
              GROUP BY p.id ORDER BY p.name LIMIT 8`)
          ).rows as Row[];
          return {
            search: q,
            products: rows.map((x) => ({
              name: x.name,
              price: n(x.price),
              inStock: x.track_stock ? n(x.on_hand) : 'non suivi',
            })),
          };
        }
        case 'low_stock': {
          const rows = (
            await tx.execute(sql`
              SELECT p.name, p.low_stock_threshold AS threshold, coalesce(sum(st.on_hand), 0) AS on_hand
              FROM catalog.products p LEFT JOIN inventory.stock_levels st ON st.product_id = p.id
              WHERE p.deleted_at IS NULL AND p.type = 'product' AND p.track_stock
              GROUP BY p.id HAVING coalesce(sum(st.on_hand), 0) <= p.low_stock_threshold
              ORDER BY coalesce(sum(st.on_hand), 0), p.name LIMIT 20`)
          ).rows as Row[];
          return { products: rows.map((x) => ({ name: x.name, inStock: n(x.on_hand), alertBelow: n(x.threshold) })) };
        }
        case 'dormant_products': {
          const rows = (
            await tx.execute(sql`
              WITH stock AS (SELECT product_id, sum(on_hand) AS on_hand FROM inventory.stock_levels GROUP BY product_id),
              last_sale AS (
                SELECT i.product_id, max(s.sold_at) AS last_sold FROM sales.sale_items i
                JOIN sales.sales s ON s.id = i.sale_id WHERE s.status = 'completed' GROUP BY i.product_id)
              SELECT p.name, st.on_hand, round(st.on_hand * p.cost)::bigint AS value, ls.last_sold
              FROM catalog.products p JOIN stock st ON st.product_id = p.id
              LEFT JOIN last_sale ls ON ls.product_id = p.id
              WHERE p.deleted_at IS NULL AND p.track_stock AND st.on_hand > 0
                AND p.created_at < now() - interval '30 days'
                AND (ls.last_sold IS NULL OR ls.last_sold < now() - interval '30 days')
              ORDER BY st.on_hand * p.cost DESC LIMIT 15`)
          ).rows as Row[];
          return {
            moneyTiedUp: rows.reduce((s, x) => s + n(x.value), 0),
            products: rows.map((x) => ({
              name: x.name,
              inStock: n(x.on_hand),
              value: n(x.value),
              lastSold: x.last_sold ? new Date(String(x.last_sold)).toISOString().slice(0, 10) : 'jamais',
            })),
          };
        }
        case 'peak_hours': {
          const local = sql`(sold_at AT TIME ZONE 'Africa/Dakar')`;
          const hours = (
            await tx.execute(sql`SELECT extract(hour FROM ${local})::int AS hour, count(*)::int AS count, coalesce(sum(total),0)::bigint AS revenue
              FROM sales.sales WHERE status = 'completed' AND sold_at >= now() - interval '30 days' GROUP BY 1`)
          ).rows as Row[];
          const days = (
            await tx.execute(sql`SELECT extract(isodow FROM ${local})::int AS weekday, count(*)::int AS count, coalesce(sum(total),0)::bigint AS revenue
              FROM sales.sales WHERE status = 'completed' AND sold_at >= now() - interval '30 days' GROUP BY 1`)
          ).rows as Row[];
          const byHour = fillHours(
            hours.map((h) => ({ hour: n(h.hour), salesCount: n(h.count), revenue: n(h.revenue) })),
          );
          const byDay = fillWeekdays(
            days.map((d) => ({ weekday: n(d.weekday), salesCount: n(d.count), revenue: n(d.revenue) })),
          );
          const best = bestWeekday(byDay);
          return {
            peak: peakWindow(byHour),
            bestDay: best ? { day: WEEKDAYS[best.weekday - 1], revenue: best.revenue } : null,
            salesByDay: byDay.map((d) => ({ day: WEEKDAYS[d.weekday - 1], sales: d.salesCount })),
          };
        }
      }
    });
  }
}
