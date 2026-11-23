import { sql, SQL } from 'drizzle-orm';
import type { TenantContext } from '../auth/auth.types';

/**
 * Condition « … AND colonne = point de vente choisi » pour les lectures (ventes, rapports) ;
 * vide quand on regarde tous les points de vente. [column] est un nom de colonne écrit en dur.
 */
export function atLocation(t: Pick<TenantContext, 'locationFilter'>, column: string): SQL {
  return t.locationFilter ? sql`AND ${sql.raw(column)} = ${t.locationFilter}` : sql``;
}

/**
 * Reste dû par client dans le point de vente choisi : (customer_id, unpaid).
 * Ce qu'un client doit encore est rattaché à ses dettes les plus récentes ; chaque dette
 * appartient au point de vente où elle a été faite. Somme sur toutes les boutiques = total dû.
 * Sans point de vente choisi : le solde de chaque client qui doit de l'argent.
 */
export function unpaidByCustomer(t: Pick<TenantContext, 'locationFilter'>): SQL {
  if (!t.locationFilter) {
    return sql`(SELECT customer_id, sum(amount)::bigint AS unpaid FROM sales.customer_ledger
                GROUP BY customer_id HAVING sum(amount) > 0)`;
  }
  return sql`(
    SELECT d.customer_id,
           sum(greatest(0, least(d.amount, b.balance - (d.run - d.amount))))::bigint AS unpaid
    FROM (
      SELECT customer_id, warehouse_id, amount,
             sum(amount) OVER (PARTITION BY customer_id ORDER BY occurred_at DESC, id DESC) AS run
      FROM sales.customer_ledger WHERE amount > 0
    ) d
    JOIN (
      SELECT customer_id, sum(amount) AS balance FROM sales.customer_ledger
      GROUP BY customer_id HAVING sum(amount) > 0
    ) b ON b.customer_id = d.customer_id
    WHERE d.warehouse_id = ${t.locationFilter}
    GROUP BY d.customer_id
    HAVING sum(greatest(0, least(d.amount, b.balance - (d.run - d.amount)))) > 0
  )`;
}
