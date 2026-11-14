/**
 * Applique les migrations SQL de apps/api/migrations dans l'ordre, une seule fois chacune.
 * Usage : pnpm db:migrate   (utilise DATABASE_URL_DIRECT si défini, sinon DATABASE_URL)
 */
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { Client } from 'pg';
import { loadDotenv } from '../config/load-dotenv';

export const MIGRATIONS_DIR = join(__dirname, '../../../migrations');

export async function migrate(connectionString: string, log: (m: string) => void = console.log): Promise<string[]> {
  const client = new Client({ connectionString });
  await client.connect();
  const applied: string[] = [];
  try {
    await client.query(`CREATE TABLE IF NOT EXISTS public.schema_migrations (
      name text PRIMARY KEY,
      applied_at timestamptz NOT NULL DEFAULT now()
    )`);
    // Verrou consultatif : deux déploiements simultanés ne migrent pas en même temps.
    await client.query('SELECT pg_advisory_lock(36036036)');
    const done = new Set(
      (await client.query<{ name: string }>('SELECT name FROM public.schema_migrations')).rows.map((r) => r.name),
    );
    const files = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort();
    for (const file of files) {
      if (done.has(file)) continue;
      const sqlText = readFileSync(join(MIGRATIONS_DIR, file), 'utf8');
      await client.query('BEGIN');
      try {
        await client.query(sqlText);
        await client.query('INSERT INTO public.schema_migrations (name) VALUES ($1)', [file]);
        await client.query('COMMIT');
        applied.push(file);
        log(`✔ ${file}`);
      } catch (err) {
        await client.query('ROLLBACK');
        throw new Error(`Échec de la migration ${file} : ${(err as Error).message}`);
      }
    }
    if (applied.length === 0) log('Base à jour, aucune migration à appliquer.');
    return applied;
  } finally {
    await client.query('SELECT pg_advisory_unlock(36036036)').catch(() => undefined);
    await client.end();
  }
}

if (require.main === module) {
  loadDotenv();
  const url = process.env.DATABASE_URL_DIRECT || process.env.DATABASE_URL;
  if (!url) {
    console.error('DATABASE_URL (ou DATABASE_URL_DIRECT) manquant.');
    process.exit(1);
  }
  migrate(url)
    .then(() => process.exit(0))
    .catch((err) => {
      console.error(err.message);
      process.exit(1);
    });
}
