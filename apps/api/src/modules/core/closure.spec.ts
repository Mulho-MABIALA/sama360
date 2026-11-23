import { sameName } from './closure.service';

describe('confirmation par le nom de la boutique', () => {
  it('ignore casse, accents et espaces ; refuse un autre nom ou un vide', () => {
    expect(sameName('  ndeye   MODE ', 'Ndèye Mode')).toBe(true);
    expect(sameName('Ndèye', 'Ndèye Mode')).toBe(false);
    expect(sameName('', '')).toBe(false);
  });
});
