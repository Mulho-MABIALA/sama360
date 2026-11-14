/**
 * Enveloppe commune de tous les événements de domaine Sama360.
 * Un événement décrit un fait passé ; son payload ne contient que des
 * identifiants et les valeurs nécessaires aux abonnés.
 */
export interface DomainEvent<T extends string = string, P = unknown> {
  id: string; // UUID v7
  type: T; // ex. 'business.created'
  version: number; // version du schéma de payload
  businessId: string; // tenant
  aggregateId: string; // id de l'entité concernée
  actorId?: string | null; // utilisateur à l'origine
  occurredAt: string; // ISO 8601
  payload: P;
}

// ---------- Socle ----------

export type BusinessCreated = DomainEvent<
  'business.created',
  { businessId: string; ownerId: string; name: string; category: string | null }
>;

export type MemberInvited = DomainEvent<
  'member.invited',
  { membershipId: string; userId: string; phone: string; roleKey: string; invitedBy: string }
>;

export type ContactCreated = DomainEvent<
  'contact.created',
  { contactId: string; type: 'customer' | 'supplier' | 'both'; name: string; phone: string | null }
>;

export type ProductUpdated = DomainEvent<
  'product.updated',
  { productId: string; price: number; cost: number; published: boolean }
>;

/** Table de correspondance type → événement, utilisée pour typer émetteurs et abonnés. */
export interface EventMap {
  'business.created': BusinessCreated;
  'member.invited': MemberInvited;
  'contact.created': ContactCreated;
  'product.updated': ProductUpdated;
}

export type EventType = keyof EventMap;
export type PayloadOf<T extends EventType> = EventMap[T]['payload'];
