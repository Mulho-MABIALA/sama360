import { allocatePayment, isoDay, statusAfterReceipt, weightedCost } from './purchasing.service';

describe('achats', () => {
  it('coût moyen pondéré après une réception', () => {
    // 10 en stock à 1 000, on reçoit 30 à 1 400 → (10 000 + 42 000) / 40 = 1 300
    expect(weightedCost(10, 1000, 30, 1400)).toBe(1300);
    // Stock vide ou négatif : le nouveau prix s'impose
    expect(weightedCost(0, 1000, 5, 1200)).toBe(1200);
    expect(weightedCost(-3, 1000, 5, 1200)).toBe(1200);
    // Arrondi au franc
    expect(weightedCost(1, 1000, 2, 1001)).toBe(1001);
  });

  it('statut après réception', () => {
    expect(statusAfterReceipt([{ quantity: 10, receivedQty: 10 }, { quantity: 2, receivedQty: 2 }])).toBe('received');
    expect(statusAfterReceipt([{ quantity: 10, receivedQty: 4 }, { quantity: 2, receivedQty: 2 }])).toBe('partial');
  });

  it('paiement global réparti du plus ancien bon au plus récent', () => {
    const orders = [
      { id: 'a', due: 30000 },
      { id: 'b', due: 0 },
      { id: 'c', due: 50000 },
    ];
    expect(allocatePayment(orders, 45000)).toEqual([
      { orderId: 'a', amount: 30000 },
      { orderId: 'c', amount: 15000 },
    ]);
    expect(allocatePayment(orders, 80000)).toHaveLength(2);
    expect(() => allocatePayment(orders, 80001)).toThrow('dépasse');
  });

  it('dates SQL', () => {
    expect(isoDay(new Date(2026, 10, 16))).toBe('2026-11-16');
    expect(isoDay('2026-11-16')).toBe('2026-11-16');
    expect(isoDay(null)).toBeNull();
  });
});
