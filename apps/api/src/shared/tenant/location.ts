import { sql, SQL } from 'drizzle-orm';
import type { TenantContext } from '../auth/auth.types';

/**
 * Condition « … AND colonne = point de vente choisi » pour les lectures (ventes, rapports) ;
 * vide quand on regarde tous les points de vente. [column] est un nom de colonne écrit en dur.
 */
export function atLocation(t: Pick<TenantContext, 'locationFilter'>, column: string): SQL {
  return t.locationFilter ? sql`AND ${sql.raw(column)} = ${t.locationFilter}` : sql``;
}
