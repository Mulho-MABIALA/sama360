import { normalizePhone } from './phone';

describe('normalizePhone', () => {
  it.each([
    ['77 123 45 67', '+221771234567'],
    ['771234567', '+221771234567'],
    ['+221 77 123 45 67', '+221771234567'],
    ['00221771234567', '+221771234567'],
    ['338201234', '+221338201234'],
    ['+242 06 612 3456', '+242066123456'],
    ['221771234567', '+221771234567'],
  ])('%s → %s', (input, expected) => {
    expect(normalizePhone(input)).toBe(expected);
  });

  it.each(['', 'abc', '12345', '12345678', '+22177123', '991234567', '0612345678'])('rejette %p', (input) => {
    expect(normalizePhone(input)).toBeNull();
  });
});

describe('normalizePhone par pays', () => {
  it.each([
    ['07 07 12 34 56', 'CI', '+2250707123456'],
    ['0102030405', 'CI', '+2250102030405'],
    ['27 22 44 55 66', 'CI', '+2252722445566'],
    ['06 612 34 56', 'CG', '+242066123456'],
    ['05 553 00 50', 'CG', '+242055530050'],
    ['+221 77 123 45 67', 'CI', '+221771234567'],
    ['77 123 45 67', 'SN', '+221771234567'],
  ] as const)('%s (%s) → %s', (input, country, expected) => {
    expect(normalizePhone(input, country)).toBe(expected);
  });

  it.each([
    ['77 123 45 67', 'CI'], // numéro sénégalais sans indicatif en Côte d'Ivoire : ambigu
    ['0907123456', 'CI'],
    ['07 12 34 56', 'CI'], // ancien format à 8 chiffres
    ['+225 77 123 45 67', 'SN'],
    ['09 612 34 56', 'CG'],
  ] as const)('rejette %s (%s)', (input, country) => {
    expect(normalizePhone(input, country)).toBeNull();
  });
});
