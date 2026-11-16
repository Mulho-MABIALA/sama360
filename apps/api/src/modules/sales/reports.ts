/** Outils de période pour les rapports (Dakar = UTC+0 : les jours sont des jours UTC). */

export const DAY_MS = 86_400_000;
export const MAX_REPORT_DAYS = 400;

export const dayStart = (d: string) => new Date(`${d}T00:00:00Z`);
export const toDay = (d: Date) => d.toISOString().slice(0, 10);

/** Nombre de jours de la période, bornes comprises. */
export function spanDays(from: string, to: string): number {
  return Math.round((dayStart(to).getTime() - dayStart(from).getTime()) / DAY_MS) + 1;
}

/** Période précédente de même durée, juste avant [from, to]. */
export function previousPeriod(from: string, to: string): { from: string; to: string } {
  const n = spanDays(from, to);
  const prevTo = new Date(dayStart(from).getTime() - DAY_MS);
  const prevFrom = new Date(prevTo.getTime() - (n - 1) * DAY_MS);
  return { from: toDay(prevFrom), to: toDay(prevTo) };
}

/** Graphique : un point par jour jusqu'à 62 jours, sinon un point par mois. */
export function granularity(from: string, to: string): 'day' | 'month' {
  return spanDays(from, to) <= 62 ? 'day' : 'month';
}

/** Toutes les étiquettes de la série (jours ou mois sans vente compris), pour un graphique continu. */
export function bucketsOf(from: string, to: string, g: 'day' | 'month'): string[] {
  const out: string[] = [];
  if (g === 'day') {
    for (let t = dayStart(from).getTime(); t <= dayStart(to).getTime(); t += DAY_MS) out.push(toDay(new Date(t)));
    return out;
  }
  const end = to.slice(0, 7);
  let [y, m] = from.slice(0, 7).split('-').map(Number);
  for (;;) {
    const key = `${y}-${String(m).padStart(2, '0')}`;
    out.push(key);
    if (key >= end) break;
    m++;
    if (m > 12) {
      m = 1;
      y++;
    }
  }
  return out;
}

/** Évolution en % (null si la période précédente est à zéro). */
export function changePct(current: number, previous: number): number | null {
  if (previous === 0) return null;
  return Math.round(((current - previous) / previous) * 1000) / 10;
}
