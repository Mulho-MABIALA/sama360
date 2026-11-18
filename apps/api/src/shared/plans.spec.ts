import { effectivePlan, extendFrom, referralCode } from './plans';

const now = new Date('2026-11-18T10:00:00Z');

describe('effectivePlan', () => {
  it('essai en cours', () => {
    expect(effectivePlan({ plan: 'pro', status: 'trialing', currentPeriodEnd: '2026-12-01T10:00:00Z' }, now)).toEqual({
      pro: true,
      state: 'trial',
      endsAt: '2026-12-01T10:00:00.000Z',
      daysLeft: 13,
    });
  });
  it('payé', () => {
    expect(effectivePlan({ plan: 'pro', status: 'active', currentPeriodEnd: '2026-11-18T11:00:00Z' }, now)).toMatchObject({
      pro: true,
      state: 'active',
      daysLeft: 1,
    });
  });
  it('terminé ou gratuit', () => {
    expect(effectivePlan({ plan: 'pro', status: 'active', currentPeriodEnd: '2026-11-01T00:00:00Z' }, now)).toMatchObject({
      pro: false,
      state: 'expired',
    });
    expect(effectivePlan({ plan: 'free', status: 'active', currentPeriodEnd: null }, now).state).toBe('free');
    expect(effectivePlan(null, now).pro).toBe(false);
  });
});

describe('extendFrom', () => {
  it('ajoute à la fin en cours si elle est à venir, sinon à aujourd’hui', () => {
    expect(extendFrom('2026-12-01T00:00:00Z', 30, now).toISOString()).toBe('2026-12-31T00:00:00.000Z');
    expect(extendFrom('2026-10-01T00:00:00Z', 30, now).toISOString()).toBe('2026-12-18T10:00:00.000Z');
    expect(extendFrom(null, 365, now).toISOString()).toBe('2027-11-18T10:00:00.000Z');
  });
});

describe('referralCode', () => {
  it('3 lettres du nom + 3 caractères sans ambiguïté', () => {
    const code = referralCode('Awa Beauté', () => 0);
    expect(code).toBe('AWAAAA');
    expect(referralCode('Ô 2', () => 0.99)).toMatch(/^OXX[A-Z2-9]{3}$/);
    expect(referralCode('Épicerie Ndèye')).toMatch(/^EPI[ABCDEFGHJKMNPQRSTUVWXYZ2-9]{3}$/);
  });
});
