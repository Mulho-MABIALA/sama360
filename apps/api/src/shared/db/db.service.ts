import { Injectable, OnModuleDestroy } from '@nestjs/common';
import { drizzle, NodePgDatabase } from 'drizzle-orm/node-postgres';
import { sql } from 'drizzle-orm';
import { Pool } from 'pg';
import { env } from '../config/env';
import * as schema from './schema';

export type Db = NodePgDatabase<typeof schema>;
/** Transaction Drizzle (même API que Db). */
export type Tx = Parameters<Parameters<Db['transaction']>[0]>[0];

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

@Injectable()
export class DbService implements OnModuleDestroy {
  readonly pool: Pool;
  readonly db: Db;

  constructor() {
    const e = env();
    // Neon : utiliser la chaîne "pooled" (PgBouncer en mode transaction).
    // SET LOCAL reste valable car il est limité à la transaction.
    this.pool = new Pool({ connectionString: e.DATABASE_URL, max: e.DATABASE_POOL_MAX });
    this.db = drizzle(this.pool, { schema });
  }

  /** Transaction sans tenant : identités, adhésions, outbox. */
  transaction<T>(fn: (tx: Tx) => Promise<T>): Promise<T> {
    return this.db.transaction(fn);
  }

  /**
   * Transaction dans le contexte d'une entreprise : positionne app.business_id
   * pour que les politiques RLS filtrent automatiquement les données.
   */
  withTenant<T>(businessId: string, fn: (tx: Tx) => Promise<T>): Promise<T> {
    if (!UUID_RE.test(businessId)) throw new Error('businessId invalide');
    return this.db.transaction(async (tx) => {
      await tx.execute(sql`select set_config('app.business_id', ${businessId}, true)`);
      return fn(tx);
    });
  }

  async onModuleDestroy(): Promise<void> {
    await this.pool.end();
  }
}
