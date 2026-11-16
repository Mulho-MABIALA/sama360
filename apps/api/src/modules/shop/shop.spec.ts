import { canMove } from './shop.service';
import { storefrontPage } from './storefront.page';

describe('boutique en ligne', () => {
  it('étapes autorisées', () => {
    expect(canMove('new', 'confirmed', 'pickup')).toBe(true);
    expect(canMove('new', 'completed', 'pickup')).toBe(false); // confirmer d'abord
    expect(canMove('confirmed', 'delivering', 'pickup')).toBe(false); // retrait : pas de livraison
    expect(canMove('ready', 'delivering', 'delivery')).toBe(true);
    expect(canMove('delivering', 'completed', 'delivery')).toBe(true);
    expect(canMove('completed', 'cancelled', 'delivery')).toBe(false);
    expect(canMove('cancelled', 'confirmed', 'pickup')).toBe(false);
  });

  it('page publique : le slug est injecté en JSON', () => {
    const html = storefrontPage('awa-beaute');
    expect(html.startsWith('<!DOCTYPE html>')).toBe(true);
    expect(html).toContain('var SLUG = "awa-beaute";');
    expect(html).toContain("/v1/public/shops/' + SLUG");
    expect(html).not.toContain('${');
  });
});
