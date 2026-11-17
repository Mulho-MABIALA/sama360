import { slugify } from './slug';

describe('slugify', () => {
  it('retire accents et caractères spéciaux', () => {
    expect(slugify('Awa Beauté & Co')).toBe('awa-beaute-co');
    expect(slugify('  Kër Mariama — Salon ')).toBe('ker-mariama-salon');
  });
  it('donne une valeur par défaut si rien ne reste', () => {
    expect(slugify('!!!')).toBe('boutique');
  });
});
