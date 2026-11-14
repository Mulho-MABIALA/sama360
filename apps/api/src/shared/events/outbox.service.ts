import { Injectable } from '@nestjs/common';
import type { EventType, PayloadOf } from '@sama360/contracts';
import type { Tx } from '../db/db.service';
import { outboxEvents } from '../db/schema';
import { newId } from '../ids';

export interface RecordEventInput<T extends EventType> {
  type: T;
  businessId: string;
  aggregateId: string;
  actorId?: string | null;
  payload: PayloadOf<T>;
  version?: number;
}

/**
 * Écrit un événement dans core.outbox_events, DANS la transaction métier fournie.
 * Si la transaction échoue, l'événement disparaît avec elle ; si elle réussit,
 * le relais le publiera forcément.
 */
@Injectable()
export class OutboxService {
  async record<T extends EventType>(tx: Tx, input: RecordEventInput<T>): Promise<string> {
    const id = newId();
    await tx.insert(outboxEvents).values({
      id,
      type: input.type,
      version: input.version ?? 1,
      businessId: input.businessId,
      aggregateId: input.aggregateId,
      actorId: input.actorId ?? null,
      payload: input.payload as unknown as Record<string, unknown>,
    });
    return id;
  }
}
