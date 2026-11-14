import IORedis from 'ioredis';
import { env } from '../config/env';

export const DOMAIN_EVENTS_QUEUE = 'domain-events';

export interface DispatchJob {
  eventId: string;
  handler: string;
}

/** Connexion Redis adaptée à BullMQ (maxRetriesPerRequest doit être null). */
export function createRedis(): IORedis {
  return new IORedis(env().REDIS_URL, { maxRetriesPerRequest: null });
}
