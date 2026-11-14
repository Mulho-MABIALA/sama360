import { Injectable, Logger, OnApplicationShutdown } from '@nestjs/common';
import type { DomainEvent } from '@sama360/contracts';
import { Job, Worker } from 'bullmq';
import { eq, sql } from 'drizzle-orm';
import type IORedis from 'ioredis';
import { DbService } from '../db/db.service';
import { outboxEvents } from '../db/schema';
import { EventRegistry } from './event-registry';
import { createRedis, DispatchJob, DOMAIN_EVENTS_QUEUE } from './queue';

/**
 * Consomme les jobs « un événement × un abonné ».
 * L'abonné s'exécute dans une transaction placée dans le contexte de l'entreprise,
 * et l'insertion dans core.processed_events se fait dans la MÊME transaction :
 * un événement n'est donc appliqué qu'une seule fois par abonné, même en cas de re-livraison.
 */
@Injectable()
export class EventWorkerService implements OnApplicationShutdown {
  private readonly logger = new Logger(EventWorkerService.name);
  private redis?: IORedis;
  private worker?: Worker<DispatchJob>;

  constructor(
    private readonly dbs: DbService,
    private readonly registry: EventRegistry,
  ) {}

  start(concurrency = 5): void {
    this.redis = createRedis();
    this.worker = new Worker<DispatchJob>(DOMAIN_EVENTS_QUEUE, (job) => this.process(job), {
      connection: this.redis,
      concurrency,
    });
    this.worker.on('failed', (job, err) =>
      this.logger.warn(`Échec ${job?.data.handler} (événement ${job?.data.eventId}) : ${err.message}`),
    );
    this.logger.log('Worker d’événements démarré');
  }

  /** Exposé pour les tests. Renvoie false si l'événement avait déjà été traité. */
  async process(job: Pick<Job<DispatchJob>, 'data'>): Promise<boolean> {
    const { eventId, handler: handlerName } = job.data;
    const handler = this.registry.get(handlerName);
    if (!handler) throw new Error(`Abonné inconnu : ${handlerName}`);

    const [row] = await this.dbs.db.select().from(outboxEvents).where(eq(outboxEvents.id, eventId)).limit(1);
    if (!row) throw new Error(`Événement introuvable : ${eventId}`);

    const event: DomainEvent = {
      id: row.id,
      type: row.type,
      version: row.version,
      businessId: row.businessId,
      aggregateId: row.aggregateId,
      actorId: row.actorId,
      occurredAt: row.occurredAt.toISOString(),
      payload: row.payload,
    };

    return this.dbs.withTenant(event.businessId, async (tx) => {
      const claimed = await tx.execute(sql`
        INSERT INTO core.processed_events (event_id, handler) VALUES (${eventId}, ${handlerName})
        ON CONFLICT DO NOTHING RETURNING event_id`);
      if (claimed.rows.length === 0) return false; // déjà traité
      await handler.run(event, tx);
      return true;
    });
  }

  async onApplicationShutdown(): Promise<void> {
    await this.worker?.close();
    this.redis?.disconnect();
  }
}
