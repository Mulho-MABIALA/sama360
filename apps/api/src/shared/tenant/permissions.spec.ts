import { hasPermission } from '@sama360/contracts';

describe('hasPermission', () => {
  it('accepte la permission exacte, le joker de domaine et le joker global', () => {
    expect(hasPermission(['sales:create'], 'sales:create')).toBe(true);
    expect(hasPermission(['invoicing:*'], 'invoicing:write')).toBe(true);
    expect(hasPermission(['*'], 'members:manage')).toBe(true);
  });

  it('refuse le reste', () => {
    expect(hasPermission(['sales:read'], 'sales:create')).toBe(false);
    expect(hasPermission(['sales:*'], 'catalog:write')).toBe(false);
    expect(hasPermission([], 'business:read')).toBe(false);
  });
});
