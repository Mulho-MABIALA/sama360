import { addDays, invoiceStatus, isOverdue } from './invoicing.service';

describe('factures : règles', () => {
  it('statut selon le payé', () => {
    expect(invoiceStatus(10000, 0)).toBe('unpaid');
    expect(invoiceStatus(10000, 2500)).toBe('partial');
    expect(invoiceStatus(10000, 10000)).toBe('paid');
    expect(invoiceStatus(0, 0)).toBe('paid');
  });

  it('retard : facture non soldée après l’échéance', () => {
    const d = '2026-11-16';
    expect(isOverdue({ kind: 'invoice', status: 'unpaid', dueDate: '2026-11-15' }, d)).toBe(true);
    expect(isOverdue({ kind: 'invoice', status: 'partial', dueDate: '2026-11-15' }, d)).toBe(true);
    expect(isOverdue({ kind: 'invoice', status: 'unpaid', dueDate: '2026-11-16' }, d)).toBe(false);
    expect(isOverdue({ kind: 'invoice', status: 'paid', dueDate: '2026-01-01' }, d)).toBe(false);
    expect(isOverdue({ kind: 'invoice', status: 'unpaid', dueDate: null }, d)).toBe(false);
    expect(isOverdue({ kind: 'quote', status: 'pending', dueDate: '2026-01-01' }, d)).toBe(false);
  });

  it('ajout de jours (fin de mois, année)', () => {
    expect(addDays('2026-11-16', 30)).toBe('2026-12-16');
    expect(addDays('2026-12-20', 15)).toBe('2027-01-04');
  });
});
