import { Injectable } from '@nestjs/common';
import type { BusinessCreated } from '@sama360/contracts';
import type { Tx } from '../../shared/db/db.service';
import { categories } from '../../shared/db/schema';
import { OnDomainEvent } from '../../shared/events/on-domain-event.decorator';
import { newId } from '../../shared/ids';

/** Catégories créées automatiquement selon le type d'activité. */
export const DEFAULT_CATEGORIES: Record<string, string[]> = {
  boutique: ['Général', 'Nouveautés'],
  restaurant: ['Plats', 'Boissons', 'Desserts'],
  prestataire: ['Prestations', 'Fournitures'],
  salon: ['Prestations', 'Produits'],
  quincaillerie: ['Plomberie', 'Électricité', 'Peinture', 'Outillage', 'Matériaux'],
  mode: ['Femme', 'Homme', 'Enfant', 'Chaussures', 'Accessoires'],
  alimentation: ['Boissons', 'Épicerie', 'Produits frais', 'Hygiène'],
};

@Injectable()
export class CatalogEventHandlers {
  @OnDomainEvent('business.created')
  async createDefaultCategories(event: BusinessCreated, tx: Tx): Promise<void> {
    const key = (event.payload.category ?? '').toLowerCase();
    const names = DEFAULT_CATEGORIES[key] ?? ['Général'];
    await tx
      .insert(categories)
      .values(names.map((name, position) => ({ id: newId(), businessId: event.businessId, name, position })))
      .onConflictDoNothing();
  }
}
