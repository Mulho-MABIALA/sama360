import {
  bestWeekday,
  fcfa,
  fillHours,
  marginRate,
  peakWindow,
  weeklyReportText,
  weekOf,
  WeeklyReport,
} from './insights';

describe('analyses', () => {
  it('taux de marge', () => {
    expect(marginRate(10000, 7500)).toBe(25);
    expect(marginRate(3000, 3200)).toBe(-6.7);
    expect(marginRate(0, 0)).toBeNull();
  });

  it('heures complétées et créneau de pointe sur deux heures', () => {
    expect(fillHours([])).toHaveLength(24);
    const peak = peakWindow([
      { hour: 9, salesCount: 2, revenue: 0 },
      { hour: 18, salesCount: 5, revenue: 0 },
      { hour: 19, salesCount: 3, revenue: 0 },
    ]);
    expect(peak).toEqual({ from: 18, to: 20, share: 80 });
    // Une heure isolée : le créneau ne s'étend pas sur une heure vide
    expect(peakWindow([{ hour: 7, salesCount: 4, revenue: 0 }])).toEqual({ from: 7, to: 8, share: 100 });
    expect(peakWindow([])).toBeNull();
  });

  it('meilleur jour de la semaine', () => {
    expect(
      bestWeekday([
        { weekday: 1, salesCount: 1, revenue: 500 },
        { weekday: 6, salesCount: 3, revenue: 9000 },
      ]),
    ).toMatchObject({ weekday: 6 });
    expect(bestWeekday([{ weekday: 1, salesCount: 0, revenue: 0 }])).toBeNull();
  });

  it('semaine : lundi → dimanche, par défaut la semaine passée', () => {
    expect(weekOf('2026-11-19')).toEqual({ from: '2026-11-16', to: '2026-11-22' });
    expect(weekOf('2026-11-22')).toEqual({ from: '2026-11-16', to: '2026-11-22' });
    // Mardi 17 novembre : la semaine passée est celle du 9 au 15
    expect(weekOf(undefined, new Date('2026-11-17T10:00:00Z'))).toEqual({ from: '2026-11-09', to: '2026-11-15' });
  });

  it('montants lisibles', () => {
    expect(fcfa(86500)).toBe('86 500 F');
    expect(fcfa(1250000)).toBe('1 250 000 F');
    expect(fcfa(-3000)).toBe('−3 000 F');
  });

  it('texte WhatsApp du rapport de la semaine', () => {
    const r: WeeklyReport = {
      businessName: 'Awa Beauté',
      from: '2026-11-09',
      to: '2026-11-15',
      salesCount: 42,
      revenue: 318500,
      netProfit: 96000,
      revenueChange: 12.5,
      bestDay: { weekday: 6, revenue: 82000 },
      peak: { from: 18, to: 20, share: 34 },
      topProducts: [
        { name: 'Beurre de karité 250 g', quantity: 18, revenue: 68400 },
        { name: 'Savon noir', quantity: 12, revenue: 18000 },
      ],
      dormant: { count: 4, stockValue: 52000, names: ['Parfum Oud', 'Henné', 'Crème X'] },
      lowMargin: [{ name: 'Huile de coco 500 ml', marginRate: 8.3 }],
      customersOwe: 27500,
    };
    const t = weeklyReportText(r);
    expect(t).toContain('*Awa Beauté — semaine du 9 nov. au 15 nov.*');
    expect(t).toContain("Chiffre d'affaires : *318 500 F* (+12,5 % ↗)");
    expect(t).toContain('Meilleur jour : samedi (82 000 F)');
    expect(t).toContain('Heure de pointe : 18 h – 20 h (34 % des ventes)');
    expect(t).toContain('1. Beurre de karité 250 g — 18 vendus');
    expect(t).toContain('4 produits sans vente depuis 30 jours* (52 000 F de stock qui dort)');
    expect(t).toContain('Parfum Oud, Henné, Crème X… : pensez à une promo.');
    expect(t).toContain('• Huile de coco 500 ml : 8,3 %');
    expect(t).toContain('Vos clients vous doivent 27 500 F.');

    const empty = weeklyReportText({
      ...r,
      salesCount: 0,
      topProducts: [],
      dormant: { count: 0, stockValue: 0, names: [] },
      lowMargin: [],
      customersOwe: 0,
    });
    expect(empty).toContain('Aucune vente enregistrée cette semaine.');
    expect(empty).not.toContain('Meilleur jour');
  });
});
