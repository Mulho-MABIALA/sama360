import { onboardingSteps, OnboardingFacts } from './onboarding';

const empty: OnboardingFacts = {
  products: 0,
  services: 0,
  sales: 0,
  appointments: 0,
  hasLogo: false,
  hasPhone: true,
  shopOnline: false,
  bookingOnline: false,
  members: 1,
};

describe('premiers pas', () => {
  it('étapes selon l’activité', () => {
    expect(onboardingSteps('products', empty).map((s) => s.key)).toEqual([
      'add_products',
      'first_sale',
      'logo_phone',
      'shop_online',
      'invite_member',
    ]);
    expect(onboardingSteps('services', empty).map((s) => s.key)[0]).toBe('add_services');
    expect(onboardingSteps('both', empty)).toHaveLength(7);
    expect(onboardingSteps(null, empty)).toHaveLength(5); // pas encore répondu : comme « produits »
  });

  it('cochées d’après les vraies données', () => {
    const s = onboardingSteps('products', { ...empty, products: 3, sales: 1, hasLogo: true, members: 2 });
    expect(s.filter((x) => x.done).map((x) => x.key)).toEqual([
      'add_products',
      'first_sale',
      'logo_phone',
      'invite_member',
    ]);
    // Logo sans téléphone : pas encore fait (les deux apparaissent sur les reçus)
    expect(onboardingSteps('products', { ...empty, hasLogo: true, hasPhone: false })[2].done).toBe(false);
  });
});
