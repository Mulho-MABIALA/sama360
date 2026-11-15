import { quantitiesByProduct } from './inventory.events';

describe('quantitiesByProduct', () => {
  it('regroupe les lignes du même produit et ignore les articles non suivis', () => {
    const map = quantitiesByProduct([
      { productId: 'a', quantity: 2, unitCost: 100, trackStock: true },
      { productId: 'a', quantity: 1.5, unitCost: 100, trackStock: true },
      { productId: 'b', quantity: 3, unitCost: 50, trackStock: false },
      { productId: null, quantity: 1, unitCost: 0, trackStock: false },
    ]);
    expect([...map.entries()]).toEqual([['a', { quantity: 3.5, unitCost: 100 }]]);
  });
});
