/** Réservation : calculs purs (testés sans base). */
export const APPOINTMENT_STATUSES = ['booked', 'done', 'no_show', 'cancelled'] as const;
export type AppointmentStatus = (typeof APPOINTMENT_STATUSES)[number];

type Slot = { id: string; startsAt: Date; durationMinutes: number; status: string };

/** Rendez-vous actifs qui se chevauchent (pour avertir, sans bloquer : plusieurs coiffeuses possibles). */
export function overlappingIds(slots: Slot[]): Set<string> {
  const active = slots
    .filter((s) => s.status === 'booked' || s.status === 'done')
    .sort((a, b) => a.startsAt.getTime() - b.startsAt.getTime());
  const out = new Set<string>();
  for (let i = 0; i < active.length; i++) {
    const endI = active[i].startsAt.getTime() + active[i].durationMinutes * 60_000;
    for (let j = i + 1; j < active.length && active[j].startsAt.getTime() < endI; j++) {
      out.add(active[i].id);
      out.add(active[j].id);
    }
  }
  return out;
}

/** « 10 h », « 10 h 30 » (heure de Dakar = UTC). */
export function hourLabel(d: Date): string {
  const h = d.getUTCHours();
  const m = d.getUTCMinutes();
  return m === 0 ? `${h} h` : `${h} h ${String(m).padStart(2, '0')}`;
}
