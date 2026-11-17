import { contrast, normalizeHex, readableOnWhite } from './color';

describe('couleur de marque', () => {
  it('normalise', () => {
    expect(normalizeHex('0a7e4f')).toBe('#0A7E4F');
    expect(normalizeHex(' #c62828 ')).toBe('#C62828');
    expect(normalizeHex('#fff')).toBeNull();
    expect(normalizeHex('rouge')).toBeNull();
  });

  it('garde une couleur déjà lisible, assombrit une couleur trop claire', () => {
    expect(readableOnWhite('#097E4F')).toBe('#097E4F');
    const yellow = readableOnWhite('#FFD600');
    expect(contrast(yellow, '#FFFFFF')).toBeGreaterThanOrEqual(4.5);
    expect(yellow).not.toBe('#FFD600');
  });
});
