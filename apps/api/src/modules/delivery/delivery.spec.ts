import { canMoveDelivery, mapsLink } from './delivery';

describe('livraison', () => {
  it('étapes autorisées', () => {
    expect(canMoveDelivery('pending', 'assigned')).toBe(true);
    expect(canMoveDelivery('assigned', 'picked')).toBe(true);
    expect(canMoveDelivery('picked', 'delivered')).toBe(true);
    expect(canMoveDelivery('failed', 'assigned')).toBe(true); // nouvel essai
    expect(canMoveDelivery('delivered', 'failed')).toBe(false);
    expect(canMoveDelivery('cancelled', 'assigned')).toBe(false);
    expect(canMoveDelivery('pending', 'delivered')).toBe(false); // il faut un livreur
  });

  it('lien Google Maps pour le livreur', () => {
    expect(mapsLink('Sacré-Cœur 3, villa 12', 'Dakar')).toBe(
      'https://www.google.com/maps/search/?api=1&query=Sacr%C3%A9-C%C5%93ur%203%2C%20villa%2012%2C%20Dakar',
    );
  });
});
