import { SetMetadata } from '@nestjs/common';
import type { EventType } from '@sama360/contracts';

export const DOMAIN_EVENT_HANDLER = 'sama:domainEventHandler';

/**
 * Marque une méthode comme abonnée à un type d'événement.
 * La méthode reçoit (event, tx) : tx est une transaction déjà placée dans
 * le contexte de l'entreprise de l'événement (RLS active).
 * Le nom stable du handler est « NomDeClasse.nomDeMethode » : ne pas le renommer
 * à la légère, il sert à l'idempotence (core.processed_events).
 */
export const OnDomainEvent = (type: EventType) => SetMetadata(DOMAIN_EVENT_HANDLER, type);
