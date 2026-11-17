/** Livraison : étapes d'une course (calcul pur, testé sans base). */
export const DELIVERY_STATUSES = ['pending', 'assigned', 'picked', 'delivered', 'failed', 'cancelled'] as const;
export type DeliveryStatus = (typeof DELIVERY_STATUSES)[number];
export const VEHICLES = ['moto', 'voiture', 'velo', 'pied'] as const;

const NEXT: Record<DeliveryStatus, DeliveryStatus[]> = {
  pending: ['assigned', 'cancelled'],
  assigned: ['assigned', 'picked', 'delivered', 'failed', 'cancelled'],
  picked: ['delivered', 'failed', 'cancelled'],
  delivered: [],
  failed: ['assigned', 'cancelled'], // nouvel essai avec un livreur
  cancelled: [],
};

export function canMoveDelivery(from: DeliveryStatus, to: DeliveryStatus): boolean {
  return NEXT[from].includes(to);
}

export const DELIVERY_LABELS: Record<DeliveryStatus, string> = {
  pending: 'À assigner',
  assigned: 'Assignée',
  picked: 'En route',
  delivered: 'Livrée',
  failed: 'Échec',
  cancelled: 'Annulée',
};

/** Lien Google Maps vers une adresse écrite (« Sacré-Cœur 3, villa 12 »), pour le livreur. */
export function mapsLink(address: string, city?: string | null): string {
  const q = [address, city].filter(Boolean).join(', ');
  return `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(q)}`;
}
