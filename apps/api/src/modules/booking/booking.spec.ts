import { hourLabel, overlappingIds } from './booking';

describe('réservation', () => {
  const at = (h: number, m = 0) => new Date(Date.UTC(2026, 10, 17, h, m));

  it('chevauchements : seulement les rendez-vous actifs qui se croisent', () => {
    const ids = overlappingIds([
      { id: 'a', startsAt: at(9), durationMinutes: 60, status: 'booked' },
      { id: 'b', startsAt: at(9, 30), durationMinutes: 30, status: 'booked' },
      { id: 'c', startsAt: at(10), durationMinutes: 30, status: 'booked' }, // commence à la fin de « a »
      { id: 'd', startsAt: at(10, 15), durationMinutes: 30, status: 'cancelled' },
    ]);
    expect([...ids].sort()).toEqual(['a', 'b']);
  });

  it('heure lisible', () => {
    expect(hourLabel(at(9))).toBe('9 h');
    expect(hourLabel(at(14, 5))).toBe('14 h 05');
  });
});
