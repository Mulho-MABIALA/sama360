import { daysUntilBirthday, DEFAULT_LOYALTY, pointsFor, pointsToNextReward, rewardsAvailable } from './loyalty.service';

const on = { ...DEFAULT_LOYALTY, enabled: true }; // 1 pt / 1 000 F ; 100 pts = 2 000 F

describe('fidélité', () => {
  it('points gagnés : arrondi à l’inférieur, rien si désactivé', () => {
    expect(pointsFor(31_600, on)).toBe(31);
    expect(pointsFor(999, on)).toBe(0);
    expect(pointsFor(31_600, DEFAULT_LOYALTY)).toBe(0);
  });

  it('récompenses disponibles et points manquants', () => {
    expect(rewardsAvailable(250, on)).toBe(2);
    expect(rewardsAvailable(99, on)).toBe(0);
    expect(pointsToNextReward(250, on)).toBe(50);
    expect(pointsToNextReward(0, on)).toBe(100);
  });

  it('jours avant l’anniversaire', () => {
    const now = new Date('2026-11-17T10:00:00Z');
    expect(daysUntilBirthday(17, 11, now)).toBe(0);
    expect(daysUntilBirthday(18, 11, now)).toBe(1);
    expect(daysUntilBirthday(16, 11, now)).toBe(364);
    expect(daysUntilBirthday(1, 1, now)).toBe(45);
    // 29 février fêté le 28 en 2027 (année non bissextile)
    expect(daysUntilBirthday(29, 2, now)).toBe(daysUntilBirthday(28, 2, now));
  });
});
