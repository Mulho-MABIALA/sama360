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
