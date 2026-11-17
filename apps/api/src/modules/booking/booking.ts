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

export interface BookingSettings {
  onlineEnabled: boolean;
  openDays: number[]; // 1 = lundi … 7 = dimanche
  openTime: string; // « 09:00 »
  closeTime: string; // « 19:00 »
  slotMinutes: 15 | 30 | 60;
  capacity: number;
  minNoticeMinutes: number;
  maxDaysAhead: number;
}

export const DEFAULT_BOOKING: BookingSettings = {
  onlineEnabled: false,
  openDays: [1, 2, 3, 4, 5, 6],
  openTime: '09:00',
  closeTime: '19:00',
  slotMinutes: 30,
  capacity: 1,
  minNoticeMinutes: 60,
  maxDaysAhead: 30,
};

/** Durée d'une prestation sans durée renseignée. */
export const DEFAULT_SERVICE_MINUTES = 30;

const minutes = (hhmm: string) => {
  const [h, m] = hhmm.split(':').map(Number);
  return h * 60 + m;
};
const hhmm = (min: number) => `${String(Math.floor(min / 60)).padStart(2, '0')}:${String(min % 60).padStart(2, '0')}`;

/** Jour de la semaine ISO (1 = lundi) d'une date « AAAA-MM-JJ ». */
export function isoWeekday(day: string): number {
  return ((new Date(`${day}T00:00:00Z`).getUTCDay() + 6) % 7) + 1;
}

/** Jours ouverts à la réservation, à partir d'aujourd'hui. */
export function bookableDays(s: BookingSettings, now = new Date()): string[] {
  const out: string[] = [];
  const start = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
  for (let i = 0; i <= s.maxDaysAhead; i++) {
    const d = new Date(start + i * 86_400_000).toISOString().slice(0, 10);
    if (s.openDays.includes(isoWeekday(d))) out.push(d);
  }
  return out;
}

/**
 * Créneaux libres d'un jour pour une prestation de [duration] minutes : dans les horaires,
 * assez tôt à l'avance, et sans dépasser la capacité (rendez-vous en même temps).
 * Heure de Dakar = UTC.
 */
export function freeSlots(input: {
  day: string;
  settings: BookingSettings;
  duration: number;
  existing: { startsAt: Date; durationMinutes: number }[];
  now?: Date;
}): string[] {
  const { day, settings: s, duration } = input;
  const now = input.now ?? new Date();
  if (!bookableDays(s, now).includes(day)) return [];
  const dayStart = Date.parse(`${day}T00:00:00Z`);
  const earliest = now.getTime() + s.minNoticeMinutes * 60_000;
  const open = minutes(s.openTime);
  const close = minutes(s.closeTime);
  const busy = input.existing.map((e) => ({
    from: e.startsAt.getTime(),
    to: e.startsAt.getTime() + e.durationMinutes * 60_000,
  }));
  const out: string[] = [];
  for (let m = open; m + duration <= close; m += s.slotMinutes) {
    const from = dayStart + m * 60_000;
    const to = from + duration * 60_000;
    if (from < earliest) continue;
    // Au pire moment du créneau, combien de rendez-vous se croisent ?
    const points = [from, ...busy.filter((b) => b.from > from && b.from < to).map((b) => b.from)];
    const peak = Math.max(...points.map((p) => busy.filter((b) => b.from <= p && b.to > p).length));
    if (peak < s.capacity) out.push(hhmm(m));
  }
  return out;
}
