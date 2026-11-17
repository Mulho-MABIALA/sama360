/** Premiers pas : étapes selon l'activité de la boutique (calcul pur, testé sans base). */
export const FOCUSES = ['products', 'services', 'both'] as const;
export type Focus = (typeof FOCUSES)[number];

export type StepKey =
  | 'add_products'
  | 'add_services'
  | 'first_sale'
  | 'first_appointment'
  | 'logo_phone'
  | 'shop_online'
  | 'booking_online'
  | 'invite_member';

export interface OnboardingFacts {
  products: number;
  services: number;
  sales: number;
  appointments: number;
  hasLogo: boolean;
  hasPhone: boolean;
  shopOnline: boolean;
  bookingOnline: boolean;
  members: number;
}

/** Étapes dans l'ordre conseillé ; la sécurité (empreinte) est ajoutée par le téléphone. */
export function onboardingSteps(focus: Focus | null, f: OnboardingFacts): { key: StepKey; done: boolean }[] {
  const keys: StepKey[] =
    focus === 'services'
      ? ['add_services', 'first_appointment', 'first_sale', 'logo_phone', 'booking_online', 'invite_member']
      : focus === 'both'
        ? ['add_products', 'add_services', 'first_sale', 'logo_phone', 'shop_online', 'booking_online', 'invite_member']
        : ['add_products', 'first_sale', 'logo_phone', 'shop_online', 'invite_member'];
  const done: Record<StepKey, boolean> = {
    add_products: f.products > 0,
    add_services: f.services > 0,
    first_sale: f.sales > 0,
    first_appointment: f.appointments > 0,
    logo_phone: f.hasLogo && f.hasPhone,
    shop_online: f.shopOnline,
    booking_online: f.bookingOnline,
    invite_member: f.members > 1,
  };
  return keys.map((key) => ({ key, done: done[key] }));
}
