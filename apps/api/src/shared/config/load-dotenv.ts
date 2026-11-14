import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';

/**
 * Charge apps/api/.env dans process.env sans écraser les variables déjà définies.
 * Volontairement minimal (pas de dépendance) : lignes CLE=valeur, # pour les commentaires.
 */
export function loadDotenv(file = resolve(__dirname, '../../../.env')): void {
  if (!existsSync(file)) return;
  for (const raw of readFileSync(file, 'utf8').split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const eq = line.indexOf('=');
    if (eq === -1) continue;
    const key = line.slice(0, eq).trim();
    let value = line.slice(eq + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    if (process.env[key] === undefined) process.env[key] = value;
  }
}
