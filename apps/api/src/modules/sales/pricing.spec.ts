import { priceSale, PricingError } from './pricing';

const line = (over: Partial<Parameters<typeof priceSale>[0][number]> = {}) => ({
  productId: 'p',
  name: 'Beurre de karité',
  quantity: 2,
  unitPrice: 3500,
  unitCost: 2000,
  discount: 0,
  trackStock: true,
  ...over,
});

describe('priceSale', () => {
  it('calcule lignes, sous-total, remise, total et coût', () => {
    const r = priceSale([line(), line({ name: 'Huile de coco', quantity: 1, unitPrice: 4000, unitCost: 2600, discount: 500 })], 1000);
    expect(r.lines.map((l) => l.total)).toEqual([7000, 3500]);
    expect(r).toMatchObject({ subtotal: 10500, discount: 1000, total: 9500, costTotal: 6600 });
  });

  it('arrondit les quantités décimales au franc', () => {
    const r = priceSale([line({ quantity: 1.25, unitPrice: 999, unitCost: 333 })]);
    expect(r.total).toBe(1249); // 1248,75 → 1249
    expect(r.costTotal).toBe(416); // 416,25 → 416
  });

  it('refuse une vente vide et les remises excessives', () => {
    expect(() => priceSale([])).toThrow(PricingError);
    expect(() => priceSale([line({ discount: 8000 })])).toThrow(/Remise/);
    expect(() => priceSale([line()], 7001)).toThrow(/Remise/);
  });
});
