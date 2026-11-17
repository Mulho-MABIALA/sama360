import { byPriority, daysBetween, isDue, ReminderItem } from './reminders.service';

const now = new Date('2026-11-17T10:00:00Z');
const item = (over: Partial<ReminderItem>): ReminderItem => ({
  kind: 'credit',
  id: 'x',
  customerId: 'x',
  name: 'X',
  phone: null,
  amount: 1000,
  since: null,
  daysLate: 10,
  invoiceNumber: null,
  lastRemindedAt: null,
  due: true,
  ...over,
});

describe('relances', () => {
  it('jours entre deux dates (jours civils)', () => {
    expect(daysBetween(new Date('2026-11-16T23:59:00Z'), now)).toBe(1);
    expect(daysBetween(new Date('2026-11-17T00:01:00Z'), now)).toBe(0);
    expect(daysBetween(new Date('2026-11-20T00:00:00Z'), now)).toBe(-3);
  });

  it('crédit à relancer après une semaine, facture dès le lendemain de l’échéance', () => {
    expect(isDue({ kind: 'credit', daysLate: 6, lastRemindedAt: null }, now)).toBe(false);
    expect(isDue({ kind: 'credit', daysLate: 7, lastRemindedAt: null }, now)).toBe(true);
    expect(isDue({ kind: 'invoice', daysLate: 0, lastRemindedAt: null }, now)).toBe(false);
    expect(isDue({ kind: 'invoice', daysLate: 1, lastRemindedAt: null }, now)).toBe(true);
  });

  it('pas plus d’un rappel par semaine', () => {
    expect(
      isDue(
        {
          kind: 'invoice',
          daysLate: 20,
          lastRemindedAt: '2026-11-12T09:00:00Z',
        },
        now,
      ),
    ).toBe(false);
    expect(
      isDue(
        {
          kind: 'invoice',
          daysLate: 20,
          lastRemindedAt: '2026-11-10T09:00:00Z',
        },
        now,
      ),
    ).toBe(true);
  });

  it('ordre : à relancer, puis plus en retard, puis plus gros montant', () => {
    const list = [
      item({ id: 'a', due: false, daysLate: 90 }),
      item({ id: 'b', daysLate: 10, amount: 500 }),
      item({ id: 'c', daysLate: 30 }),
      item({ id: 'd', daysLate: 10, amount: 9000 }),
    ].sort(byPriority);
    expect(list.map((i) => i.id)).toEqual(['c', 'd', 'b', 'a']);
  });
});
