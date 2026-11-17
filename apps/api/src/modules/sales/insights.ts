/** Analyses : calculs purs (testés sans base) et texte du rapport de la semaine. */
import { DAY_MS, dayStart, toDay } from './reports';

export const INSIGHT_DAYS = [7, 14, 30, 60, 90] as const;
export const DEFAULT_INSIGHT_DAYS = 30;
/** En dessous de ce taux, une marge est jugée faible. */
export const LOW_MARGIN_RATE = 15;

export const WEEKDAYS = ['lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi', 'dimanche'] as const;

export type HourStat = { hour: number; salesCount: number; revenue: number };
export type WeekdayStat = { weekday: number; salesCount: number; revenue: number };

/** Taux de marge en % (une décimale), null si rien vendu. */
export function marginRate(revenue: number, cost: number): number | null {
  if (revenue <= 0) return null;
  return Math.round(((revenue - cost) / revenue) * 1000) / 10;
}

/** Complète les 24 heures (les heures sans vente valent 0). */
export function fillHours(rows: HourStat[]): HourStat[] {
  const by = new Map(rows.map((r) => [r.hour, r]));
  return Array.from({ length: 24 }, (_, h) => by.get(h) ?? { hour: h, salesCount: 0, revenue: 0 });
}

/** Complète les 7 jours, lundi = 1 … dimanche = 7. */
export function fillWeekdays(rows: WeekdayStat[]): WeekdayStat[] {
  const by = new Map(rows.map((r) => [r.weekday, r]));
  return Array.from({ length: 7 }, (_, i) => by.get(i + 1) ?? { weekday: i + 1, salesCount: 0, revenue: 0 });
}

/**
 * Créneau le plus chargé : les deux heures consécutives qui font le plus de ventes
 * (plus parlant qu'une heure seule : « 18 h – 20 h »). null s'il n'y a aucune vente.
 */
export function peakWindow(hours: HourStat[]): { from: number; to: number; share: number } | null {
  const all = fillHours(hours);
  const total = all.reduce((s, h) => s + h.salesCount, 0);
  if (total === 0) return null;
  let best = 0;
  let bestCount = -1;
  for (let h = 0; h < 23; h++) {
    const c = all[h].salesCount + all[h + 1].salesCount;
    if (c > bestCount) {
      bestCount = c;
      best = h;
    }
  }
  // Si une des deux heures est vide, le créneau se réduit à l'heure qui vend
  let from = best;
  let to = best + 2;
  if (all[best].salesCount === 0) from = best + 1;
  else if (all[best + 1].salesCount === 0) to = best + 1;
  return { from, to, share: Math.round((bestCount / total) * 100) };
}

/** Jour de la semaine qui rapporte le plus (null sans vente). */
export function bestWeekday(days: WeekdayStat[]): WeekdayStat | null {
  const withSales = days.filter((d) => d.revenue > 0);
  if (withSales.length === 0) return null;
  return withSales.reduce((a, b) => (b.revenue > a.revenue ? b : a));
}

/** Semaine complète précédente (lundi → dimanche) ; ou celle qui contient `day` si donné. */
export function weekOf(day?: string, now = new Date()): { from: string; to: string } {
  const ref = day
    ? dayStart(day)
    : new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()) - 7 * DAY_MS);
  const dow = ref.getUTCDay() || 7;
  const monday = new Date(ref.getTime() - (dow - 1) * DAY_MS);
  return { from: toDay(monday), to: toDay(new Date(monday.getTime() + 6 * DAY_MS)) };
}

/** « 86 500 F » (espaces simples : lisible partout, WhatsApp compris). */
export function fcfa(n: number): string {
  const sign = n < 0 ? '−' : '';
  return `${sign}${Math.abs(Math.round(n))
    .toString()
    .replace(/\B(?=(\d{3})+(?!\d))/g, ' ')} F`;
}

const MONTHS = ['janv.', 'févr.', 'mars', 'avr.', 'mai', 'juin', 'juil.', 'août', 'sept.', 'oct.', 'nov.', 'déc.'];
const shortDay = (d: string) => {
  const t = dayStart(d);
  return `${t.getUTCDate()} ${MONTHS[t.getUTCMonth()]}`;
};
const hourLabel = (h: number) => `${h} h`;

export type WeeklyReport = {
  businessName: string;
  from: string;
  to: string;
  salesCount: number;
  revenue: number;
  netProfit: number;
  revenueChange: number | null;
  bestDay: { weekday: number; revenue: number } | null;
  peak: { from: number; to: number; share: number } | null;
  topProducts: { name: string; quantity: number; revenue: number }[];
  dormant: { count: number; stockValue: number; names: string[] };
  lowMargin: { name: string; marginRate: number | null }[];
  customersOwe: number;
};

/** Texte prêt à envoyer sur WhatsApp (gras avec *…*, une idée par ligne). */
export function weeklyReportText(r: WeeklyReport): string {
  const lines: string[] = [];
  lines.push(`📊 *${r.businessName} — semaine du ${shortDay(r.from)} au ${shortDay(r.to)}*`);
  lines.push('');
  if (r.salesCount === 0) {
    lines.push('Aucune vente enregistrée cette semaine.');
  } else {
    const change =
      r.revenueChange === null
        ? ''
        : r.revenueChange >= 0
          ? ` (+${String(r.revenueChange).replace('.', ',')} % ↗)`
          : ` (${String(r.revenueChange).replace('.', ',').replace('-', '−')} % ↘)`;
    lines.push(`💰 Chiffre d'affaires : *${fcfa(r.revenue)}*${change}`);
    lines.push(`🧾 ${r.salesCount} vente${r.salesCount > 1 ? 's' : ''}`);
    lines.push(`📈 Bénéfice net : *${fcfa(r.netProfit)}*`);
    if (r.bestDay) lines.push(`📅 Meilleur jour : ${WEEKDAYS[r.bestDay.weekday - 1]} (${fcfa(r.bestDay.revenue)})`);
    if (r.peak)
      lines.push(
        `⏰ Heure de pointe : ${hourLabel(r.peak.from)} – ${hourLabel(r.peak.to)} (${r.peak.share} % des ventes)`,
      );
  }
  if (r.topProducts.length > 0) {
    lines.push('');
    lines.push('🏆 *Les plus vendus*');
    r.topProducts.slice(0, 3).forEach((p, i) => lines.push(`${i + 1}. ${p.name} — ${fmtQty(p.quantity)} vendus`));
  }
  if (r.dormant.count > 0) {
    lines.push('');
    lines.push(
      `😴 *${r.dormant.count} produit${r.dormant.count > 1 ? 's' : ''} sans vente depuis 30 jours* (${fcfa(r.dormant.stockValue)} de stock qui dort)`,
    );
    const names = r.dormant.names.slice(0, 3).join(', ');
    lines.push(`${names}${r.dormant.count > 3 ? '…' : ''} : pensez à une promo.`);
  }
  if (r.lowMargin.length > 0) {
    lines.push('');
    lines.push('⚠️ *Marge faible*');
    for (const p of r.lowMargin.slice(0, 3)) {
      lines.push(`• ${p.name} : ${p.marginRate === null ? '—' : `${String(p.marginRate).replace('.', ',')} %`}`);
    }
  }
  if (r.customersOwe > 0) {
    lines.push('');
    lines.push(`📒 Vos clients vous doivent ${fcfa(r.customersOwe)}.`);
  }
  lines.push('');
  lines.push('_Envoyé depuis Sama360_');
  return lines.join('\n');
}

const fmtQty = (q: number) => (Number.isInteger(q) ? String(q) : String(Math.round(q * 100) / 100).replace('.', ','));
