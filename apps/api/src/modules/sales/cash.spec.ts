import { differences, expectedByMethod } from './cash.service';

describe('caisse', () => {
  const flows = {
    sales: { cash: 6000, wave: 4000 },
    repayments: { orange_money: 1500, cash: 500 },
    invoices: { transfer: 20000 },
    expenses: { cash: 2000 },
    suppliers: { wave: 1000 },
    movementsIn: 500,
    movementsOut: 3000,
  };

  it('attendu par moyen : fond + encaissements − décaissements ; mouvements en espèces seulement', () => {
    const lines = expectedByMethod(10000, flows);
    expect(lines.map((l) => [l.method, l.expected])).toEqual([
      ['cash', 10000 + 6000 + 500 + 500 - 2000 - 3000],
      ['wave', 3000],
      ['orange_money', 1500],
      ['transfer', 20000],
    ]);
  });

  it('les espèces apparaissent même sans mouvement', () => {
    const lines = expectedByMethod(0, { sales: {}, repayments: {}, invoices: {}, expenses: {}, suppliers: {}, movementsIn: 0, movementsOut: 0 });
    expect(lines).toEqual([expect.objectContaining({ method: 'cash', expected: 0 })]);
  });

  it('écarts : un moyen non compté ne crée pas d’écart', () => {
    const lines = expectedByMethod(10000, flows);
    const d = differences(lines, { cash: 11500, wave: 3000 });
    expect(d.byMethod.find((m) => m.method === 'cash')).toMatchObject({ expected: 12000, counted: 11500, difference: -500 });
    expect(d.byMethod.find((m) => m.method === 'orange_money')).toMatchObject({ counted: 1500, difference: 0 });
    expect(d.total).toBe(-500);
  });
});
