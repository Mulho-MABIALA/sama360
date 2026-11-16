import { dayKey, francs, isoWeek, visibleAudiences } from './notifications.service';

describe('notifications', () => {
  it('semaine ISO pour le rappel hebdomadaire des crédits', () => {
    expect(isoWeek(new Date('2026-11-16T10:00:00Z'))).toBe('2026-W47');
    expect(isoWeek(new Date('2026-01-01T10:00:00Z'))).toBe('2026-W01');
    expect(isoWeek(new Date('2027-01-01T10:00:00Z'))).toBe('2026-W53');
  });

  it('montants et jours', () => {
    expect(francs(125000)).toBe('125 000 F');
    expect(dayKey(new Date('2026-11-16T23:59:00Z'))).toBe('2026-11-16');
  });

  it('chaque rôle voit ce qui le concerne', () => {
    expect(visibleAudiences(['*'])).toHaveLength(6);
    const cashier = ['contacts:read', 'sales:read', 'sales:create', 'inventory:read', 'invoicing:read'];
    expect(visibleAudiences(cashier)).not.toContain('sales:void');
    expect(visibleAudiences(['sales:*', 'inventory:*'])).toEqual(
      expect.arrayContaining(['sales:read', 'sales:create', 'sales:void', 'inventory:read']),
    );
  });
});
