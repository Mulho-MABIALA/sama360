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

import { saleDate } from './sales.service';

describe('saleDate (ventes hors ligne)', () => {
  const now = new Date('2026-11-16T10:00:00Z');
  it('garde la date du téléphone', () => {
    const d = new Date('2026-11-15T18:30:00Z');
    expect(saleDate(d, now)).toEqual(d);
  });
  it('ramène une horloge en avance à maintenant', () => {
    expect(saleDate(new Date('2026-11-17T10:00:00Z'), now)).toEqual(now);
  });
  it('sans date : maintenant', () => {
    expect(saleDate(undefined, now)).toEqual(now);
  });
  it('refuse une vente de plus de 90 jours', () => {
    expect(() => saleDate(new Date('2026-07-01T10:00:00Z'), now)).toThrow('trop ancienne');
  });
});

import { catalogUnitPrice } from './pricing';

describe('prix de gros', () => {
  const sac = { price: 1000, wholesalePrice: 850, wholesaleMinQty: 10 };
  it('prix normal sous le seuil, prix de gros à partir du seuil', () => {
    expect(catalogUnitPrice(sac, 9)).toBe(1000);
    expect(catalogUnitPrice(sac, 10)).toBe(850);
    expect(catalogUnitPrice(sac, 25)).toBe(850);
  });
  it('le prix saisi en caisse l’emporte ; sans prix de gros, prix normal', () => {
    expect(catalogUnitPrice(sac, 50, 900)).toBe(900);
    expect(catalogUnitPrice({ price: 500 }, 100)).toBe(500);
    expect(catalogUnitPrice({ price: 500, wholesalePrice: null, wholesaleMinQty: null }, 100)).toBe(500);
  });
});
