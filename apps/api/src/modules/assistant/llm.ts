/** Client du modèle de langage (API Messages d'Anthropic) et faux client pour les tests. */

export type ContentBlock =
  | { type: 'text'; text: string }
  | { type: 'tool_use'; id: string; name: string; input: Record<string, unknown> }
  | { type: 'tool_result'; tool_use_id: string; content: string; is_error?: boolean };

export type LlmMessage = { role: 'user' | 'assistant'; content: string | ContentBlock[] };

export interface LlmRequest {
  system: string;
  messages: LlmMessage[];
  tools: { name: string; description: string; input_schema: object }[];
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
    const timer = setTimeout(() => ctrl.abort(), this.timeoutMs);
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
          model: this.model,
          max_tokens: 1024,
          system: req.system,
          messages: req.messages,
          tools: req.tools,
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
