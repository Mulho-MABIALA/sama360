/** Client du modèle de langage (API Messages d'Anthropic) et faux client pour les tests. */

export type ContentBlock =
  | { type: 'text'; text: string }
  | { type: 'tool_use'; id: string; name: string; input: Record<string, unknown> }
  | { type: 'tool_result'; tool_use_id: string; content: string; is_error?: boolean }
  | { type: 'image'; source: { type: 'base64'; media_type: 'image/jpeg' | 'image/png' | 'image/webp'; data: string } };

export type LlmMessage = { role: 'user' | 'assistant'; content: string | ContentBlock[] };

export interface LlmRequest {
  system: string;
  messages: LlmMessage[];
  tools: { name: string; description: string; input_schema: object }[];
  /** Oblige le modèle à répondre avec cet outil (sortie structurée). */
  toolChoice?: { type: 'tool'; name: string };
  maxTokens?: number;
  /** Autre modèle que celui par défaut (ex. lecture de factures). */
  model?: string;
  timeoutMs?: number;
}

export interface LlmResponse {
  content: ContentBlock[];
  stopReason: 'end_turn' | 'tool_use' | 'max_tokens' | string;
}

export abstract class LlmClient {
  abstract complete(req: LlmRequest): Promise<LlmResponse>;
}

export class LlmUnavailableError extends Error {}

export class AnthropicClient extends LlmClient {
  constructor(
    private readonly apiKey: string,
    private readonly model: string,
    private readonly timeoutMs = 45_000,
  ) {
    super();
  }

  async complete(req: LlmRequest): Promise<LlmResponse> {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), req.timeoutMs ?? this.timeoutMs);
    try {
      const res = await fetch('https://api.anthropic.com/v1/messages', {
        method: 'POST',
        signal: ctrl.signal,
        headers: {
          'content-type': 'application/json',
          'x-api-key': this.apiKey,
          'anthropic-version': '2023-06-01',
        },
        body: JSON.stringify({
          model: req.model ?? this.model,
          max_tokens: req.maxTokens ?? 1024,
          system: req.system,
          messages: req.messages,
          tools: req.tools,
          ...(req.toolChoice ? { tool_choice: req.toolChoice } : {}),
        }),
      });
      if (!res.ok) {
        // Le détail (clé refusée, quota…) reste dans les journaux du serveur, jamais renvoyé au téléphone
        throw new LlmUnavailableError(`Anthropic ${res.status}: ${(await res.text()).slice(0, 300)}`);
      }
      const body = (await res.json()) as { content: ContentBlock[]; stop_reason: string };
      return { content: body.content, stopReason: body.stop_reason };
    } catch (e) {
      if (e instanceof LlmUnavailableError) throw e;
      throw new LlmUnavailableError(`Anthropic injoignable : ${(e as Error).message}`);
    } finally {
      clearTimeout(timer);
    }
  }
}

/**
 * Faux modèle (tests, démonstration hors ligne) : choisit un outil d'après des mots-clés,
 * puis résume le résultat. Permet de tester toute la chaîne sans appeler d'API payante.
 */
export class FakeLlmClient extends LlmClient {
  async complete(req: LlmRequest): Promise<LlmResponse> {
    if (req.toolChoice?.name === 'record_invoice') {
      // Facture de démonstration : toujours la même, pour tester toute la chaîne sans API payante
      return {
        content: [{ type: 'tool_use', id: 't_invoice', name: 'record_invoice', input: FAKE_INVOICE }],
        stopReason: 'tool_use',
      };
    }
    const last = req.messages[req.messages.length - 1];
    if (Array.isArray(last.content) && last.content.some((b) => b.type === 'tool_result')) {
      const results = last.content.filter((b) => b.type === 'tool_result') as { content: string }[];
      return {
        content: [{ type: 'text', text: `Voici ce que j'ai trouvé : ${results.map((r) => r.content).join(' ')}` }],
        stopReason: 'end_turn',
      };
    }
    const q = (typeof last.content === 'string' ? last.content : '').toLowerCase();
    const has = (name: string) => req.tools.some((t) => t.name === name);
    const pick = (name: string, input: Record<string, unknown>): LlmResponse => ({
      content: [{ type: 'tool_use', id: `t_${name}`, name, input }],
      stopReason: 'tool_use',
    });
    if (/(bénéfice|benefice|vendu|ventes|chiffre)/.test(q)) {
      if (has('sales_summary')) return pick('sales_summary', { period: q.includes('mois') ? 'this_month' : 'today' });
      if (has('my_sales_today')) return pick('my_sales_today', {});
    }
    if (/(doit|dette|crédit|credit)/.test(q) && has('customers_owing')) return pick('customers_owing', { limit: 5 });
    if (/(épuis|epuis|rupture|stock)/.test(q) && has('low_stock')) return pick('low_stock', {});
    if (/(ne se vend|dorm)/.test(q) && has('dormant_products')) return pick('dormant_products', {});
    if (/(heure|pointe)/.test(q) && has('peak_hours')) return pick('peak_hours', {});
    if (/(prix|combien coûte|combien coute)/.test(q) && has('stock_lookup')) {
      return pick('stock_lookup', {
        search: q
          .replace(/.*(prix|coûte|coute)( du| de la| de l'| des| de)?/, '')
          .replace('?', '')
          .trim(),
      });
    }
    return {
      content: [{ type: 'text', text: 'Cette information est réservée au propriétaire ou au gérant de la boutique.' }],
      stopReason: 'end_turn',
    };
  }
}

/** Ce que le faux modèle « lit » sur n'importe quelle photo. */
export const FAKE_INVOICE = {
  readable: true,
  supplier_name: 'Sénégal Distribution SARL',
  supplier_phone: '33 820 11 22',
  invoice_number: 'FA-2026-1187',
  invoice_date: '2026-11-17',
  currency: 'FCFA',
  lines: [
    { label: 'RIZ BRISE PARFUME 25KG', quantity: 10, unit_price: 12500, line_total: 125000 },
    { label: 'Huile Dinor 5L', quantity: 6, unit_price: 6500, line_total: 39000 },
    { label: 'Sucre morceaux 1kg', quantity: 20, unit_price: 900, line_total: 18000 },
  ],
  total: 182000,
};
