import { periodRange, suggestionsFor, systemPrompt, toolResultText, toolsFor } from './assistant';
import { FakeLlmClient } from './llm';

describe('assistant', () => {
  const now = new Date('2026-11-17T10:00:00Z'); // mardi

  it('périodes', () => {
    expect(periodRange('today', now)).toMatchObject({ from: '2026-11-17', to: '2026-11-17' });
    expect(periodRange('yesterday', now)).toMatchObject({ from: '2026-11-16', to: '2026-11-16' });
    expect(periodRange('this_week', now)).toMatchObject({ from: '2026-11-16', to: '2026-11-17' });
    expect(periodRange('last_week', now)).toMatchObject({ from: '2026-11-09', to: '2026-11-15' });
    expect(periodRange('this_month', now)).toMatchObject({ from: '2026-11-01', to: '2026-11-17' });
    expect(periodRange('last_month', now)).toMatchObject({ from: '2026-10-01', to: '2026-10-31' });
    expect(periodRange('last_30_days', now)).toMatchObject({ from: '2026-10-19', to: '2026-11-17' });
    expect(periodRange('last_month', new Date('2026-01-10T00:00:00Z'))).toMatchObject({
      from: '2025-12-01',
      to: '2025-12-31',
    });
  });

  it('outils selon les droits : le vendeur ne voit ni bénéfices ni analyses', () => {
    const cashier = ['business:read', 'contacts:read', 'catalog:read', 'sales:read', 'sales:create', 'inventory:read'];
    expect(toolsFor(cashier).map((t) => t.name)).toEqual([
      'my_sales_today',
      'customers_owing',
      'stock_lookup',
      'low_stock',
    ]);
    expect(toolsFor(['*'])).toHaveLength(8);
    expect(suggestionsFor(cashier)).not.toContain('Quel est mon bénéfice ce mois-ci ?');
  });

  it('instructions : boutique, date, règles', () => {
    const p = systemPrompt({ businessName: 'Awa Beauté', userName: 'Awa', role: 'owner', now });
    expect(p).toContain('« Awa Beauté »');
    expect(p).toContain('mardi 2026-11-17');
    expect(p).toContain("N'invente jamais un chiffre");
  });

  it('résultat d’outil borné', () => {
    expect(toolResultText({ a: 'x'.repeat(10) }, 8)).toBe('{"a":"xx… (tronqué)');
  });

  it('faux modèle : choisit l’outil puis résume', async () => {
    const llm = new FakeLlmClient();
    const tools = toolsFor(['*']);
    const first = await llm.complete({
      system: '',
      tools,
      messages: [{ role: 'user', content: 'Qui me doit le plus ?' }],
    });
    expect(first.stopReason).toBe('tool_use');
    expect(first.content[0]).toMatchObject({ type: 'tool_use', name: 'customers_owing' });
  });
});
