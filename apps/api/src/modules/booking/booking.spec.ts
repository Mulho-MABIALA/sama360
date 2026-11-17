import { bookableDays, DEFAULT_BOOKING, freeSlots, hourLabel, isoWeekday, overlappingIds } from './booking';

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

describe('créneaux en ligne', () => {
  const s = {
    ...DEFAULT_BOOKING,
    onlineEnabled: true,
    openTime: '09:00',
    closeTime: '12:00',
    slotMinutes: 30 as const,
  };
  const now = new Date('2026-11-17T07:00:00Z'); // mardi, 7 h

  it('jours réservables : jours ouverts, jusqu’à la limite', () => {
    const days = bookableDays({ ...s, maxDaysAhead: 7 }, now);
    expect(days).toEqual([
      '2026-11-17',
      '2026-11-18',
      '2026-11-19',
      '2026-11-20',
      '2026-11-21',
      '2026-11-23',
      '2026-11-24',
    ]);
    expect(isoWeekday('2026-11-22')).toBe(7);
  });

  it('horaires, préavis, durée et capacité', () => {
    // Journée vide : de 9 h à 11 h (une prestation d'1 h finit au plus tard à 12 h)
    expect(freeSlots({ day: '2026-11-18', settings: s, duration: 60, existing: [], now })).toEqual([
      '09:00',
      '09:30',
      '10:00',
      '10:30',
      '11:00',
    ]);
    // Préavis d'1 h : aujourd'hui à 9 h 30 au plus tôt si on est à 8 h 30
    expect(
      freeSlots({ day: '2026-11-17', settings: s, duration: 30, existing: [], now: new Date('2026-11-17T08:30:00Z') }),
    ).toEqual(['09:30', '10:00', '10:30', '11:00', '11:30']);
    // Un rendez-vous de 10 h à 11 h, capacité 1 : 9 h 30 (1 h) et 10 h 30 bloqués
    const existing = [{ startsAt: new Date('2026-11-18T10:00:00Z'), durationMinutes: 60 }];
    expect(freeSlots({ day: '2026-11-18', settings: s, duration: 60, existing, now })).toEqual(['09:00', '11:00']);
    // Capacité 2 : tout reste libre
    expect(freeSlots({ day: '2026-11-18', settings: { ...s, capacity: 2 }, duration: 60, existing, now })).toHaveLength(
      5,
    );
    // Jour fermé (dimanche)
    expect(freeSlots({ day: '2026-11-22', settings: s, duration: 30, existing: [], now })).toEqual([]);
  });
});
