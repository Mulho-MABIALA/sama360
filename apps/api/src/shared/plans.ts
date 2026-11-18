/**
 * Sama360 Pro : ce qui est payant, combien, et l'état effectif d'un abonnement.
 * Gratuit : vendre, caisse, stock, clients, dépenses, factures, rapports simples.
 */
export const PRO_FEATURES = [
  'team', // vendeurs et gérants
  'shop', // boutique en ligne et statuts WhatsApp
  'delivery', // livraisons et livreurs
  'booking_online', // réservation en ligne
  'insights', // statistiques avancées et rapport WhatsApp de la semaine
  'assistant', // assistant IA
  'documents', // coffre de documents
  'invoice_scan', // facture fournisseur en photo → achat et stock
] as const;
export type ProFeature = (typeof PRO_FEATURES)[number];

export const PRO_FEATURE_LABELS: Record<ProFeature, string> = {
  team: 'Vendeurs et gérants',
  shop: 'Boutique en ligne et statuts WhatsApp',
  delivery: 'Livraisons et livreurs',
  booking_online: 'Réservation en ligne',
  insights: 'Statistiques avancées et rapport de la semaine',
  assistant: 'Assistant IA',
  documents: 'Coffre de documents',
  invoice_scan: 'Facture fournisseur en photo',
};

/** Prix en francs CFA (XOF et XAF ont la même valeur). L'année = 10 mois. */
export const PRO_PRICES = { monthly: 5000, yearly: 50000 } as const;
export type Cycle = keyof typeof PRO_PRICES;
export const CYCLE_DAYS: Record<Cycle, number> = { monthly: 30, yearly: 365 };

export const TRIAL_DAYS = 30;
/** Mois offert au parrain et au filleul quand le filleul paie pour la première fois. */
export const REFERRAL_BONUS_DAYS = 30;

export interface SubscriptionRow {
  plan: string;
  status: string;
  currentPeriodEnd: Date | string | null;
}

export interface EffectivePlan {
  pro: boolean;
  /** trial : essai ; active : payé ; expired : Pro terminé ; free : jamais Pro */
  state: 'trial' | 'active' | 'expired' | 'free';
  endsAt: string | null;
  daysLeft: number;
}

const DAY = 86_400_000;

export function effectivePlan(sub: SubscriptionRow | null | undefined, now = new Date()): EffectivePlan {
  if (!sub || sub.plan !== 'pro' || !sub.currentPeriodEnd) {
    return { pro: false, state: 'free', endsAt: null, daysLeft: 0 };
  }
  const end = new Date(sub.currentPeriodEnd);
  const left = end.getTime() - now.getTime();
  if (left <= 0) return { pro: false, state: 'expired', endsAt: end.toISOString(), daysLeft: 0 };
  return {
    pro: true,
    state: sub.status === 'trialing' ? 'trial' : 'active',
    endsAt: end.toISOString(),
    daysLeft: Math.ceil(left / DAY),
  };
}

/** Nouvelle fin d'abonnement : on ajoute les jours à partir d'aujourd'hui, ou de la fin en cours si elle est plus tard. */
export function extendFrom(currentEnd: Date | string | null | undefined, days: number, now = new Date()): Date {
  const start = currentEnd && new Date(currentEnd) > now ? new Date(currentEnd) : now;
  return new Date(start.getTime() + days * DAY);
}

const CODE_CHARS = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; // sans 0/O, 1/I/L

/** Code de parrainage lisible : 3 lettres du nom + 3 caractères, ex. « AWA7K2 ». */
export function referralCode(name: string, rand: () => number = Math.random): string {
  const letters = name
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toUpperCase()
    .replace(/[^A-Z]/g, '')
    .slice(0, 3)
    .padEnd(3, 'X');
  let tail = '';
  for (let i = 0; i < 3; i++) tail += CODE_CHARS[Math.floor(rand() * CODE_CHARS.length)];
  return letters + tail;
}
