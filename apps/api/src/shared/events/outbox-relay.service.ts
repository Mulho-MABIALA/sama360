import { Injectable, Logger, OnApplicationShutdown } from '@nestjs/common';
import { Queue } from 'bullmq';
import { sql } from 'drizzle-orm';
import type IORedis from 'ioredis';
import { env } from '../config/env';
import { DbService } from '../db/db.service';
import { EventRegistry } from './event-registry';
import { createRedis, DispatchJob, DOMAIN_EVENTS_QUEUE } from './queue';

const BATCH_SIZE = 100;
const MAX_ATTEMPTS = 10;

interface OutboxRow {
  id: string;
  type: string;
  attempts: number;
}

/**
 * Lit les événements « pending » de l'outbox et crée un job BullMQ par abonné.
 * FOR UPDATE SKIP LOCKED permet de lancer plusieurs relais sans doublon.
 * Les jobs ont un id déterministe (événement + handler) : un re-envoi est ignoré.
 */
@Injectable()
export class OutboxRelayService implements OnApplicationShutdown {
  private readonly logger = new Logger(OutboxRelayService.name);
  private redis?: IORedis;
  private queue?: Queue<DispatchJob>;
  private timer?: NodeJS.Timeout;
  private running = false;
  private stopped = false;

  constructor(
    private readonly dbs: DbService,
    private readonly registry: EventRegistry,
  ) {}

  private ensureQueue(): Queue<DispatchJob> {
    if (!this.queue) {
      this.redis = createRedis();
      this.queue = new Queue<DispatchJob>(DOMAIN_EVENTS_QUEUE, { connection: this.redis });
    }
    return this.queue;
  }

  start(): void {
    this.ensureQueue();
    const tick = async () => {
      if (this.stopped) return;
      try {
        await this.relayOnce();
      } catch (err) {
        this.logger.error(`Relais : ${(err as Error).message}`);
      }
      if (!this.stopped) this.timer = setTimeout(tick, env().OUTBOX_POLL_MS);
    };
    void tick();
    this.logger.log('Relais outbox démarré');
  }

  /** Traite un lot ; renvoie le nombre d'événements publiés. Exposé pour les tests. */
  async relayOnce(): Promise<number> {
    if (this.running) return 0;
    const queue = this.ensureQueue();
    this.running = true;
    try {
      return await this.dbs.transaction(async (tx) => {
        const res = await tx.execute(sql`
          SELECT id, type, attempts FROM core.outbox_events
          WHERE status = 'pending'
          ORDER BY occurred_at
          LIMIT ${BATCH_SIZE}
          FOR UPDATE SKIP LOCKED`);
        const rows = res.rows as unknown as OutboxRow[];
        let published = 0;
        for (const row of rows) {
          try {
            const handlers = this.registry.handlersFor(row.type);
            if (handlers.length > 0) {
              await queue.addBulk(
                handlers.map((h) => ({
                  name: row.type,
                  data: { eventId: row.id, handler: h.name },
                  opts: {
                    jobId: `${row.id}__${h.name}`,
                    attempts: 5,
                    backoff: { type: 'exponential', delay: 2000 },
                    removeOnComplete: { age: 24 * 3600 },
                    removeOnFail: false,
                  },
                })),
              );
            }
            await tx.execute(
              sql`UPDATE core.outbox_events SET status = 'published', published_at = now() WHERE id = ${row.id}`,
            );
            published++;
          } catch (err) {
            const failed = row.attempts + 1 >= MAX_ATTEMPTS;
            await tx.execute(sql`
              UPDATE core.outbox_events
              SET attempts = attempts + 1, last_error = ${(err as Error).message},
                  status = ${failed ? 'failed' : 'pending'}
              WHERE id = ${row.id}`);
          }
        }
        return published;
      });
    } finally {
      this.running = false;
    }
  }

  async onApplicationShutdown(): Promise<void> {
    this.stopped = true;
    if (this.timer) clearTimeout(this.timer);
    await this.queue?.close();
    this.redis?.disconnect();
  }
}
