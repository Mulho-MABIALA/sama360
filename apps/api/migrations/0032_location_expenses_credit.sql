-- =====================================================================
-- Sama360 — 0032 : dépenses et crédits clients par point de vente
-- Chaque dépense et chaque dette notent leur point de vente. Le reste dû d'un
-- client est rattaché à ses dettes les plus récentes : « À encaisser » d'une
-- boutique = la part encore impayée des dettes faites dans cette boutique.
-- =====================================================================
ALTER TABLE sales.expenses
  ADD COLUMN IF NOT EXISTS warehouse_id uuid REFERENCES inventory.warehouses(id) ON DELETE SET NULL;
ALTER TABLE sales.customer_ledger
  ADD COLUMN IF NOT EXISTS warehouse_id uuid REFERENCES inventory.warehouses(id) ON DELETE SET NULL;

-- Dettes des ventes : le point de vente de la vente
UPDATE sales.customer_ledger l SET warehouse_id = s.warehouse_id
  FROM sales.sales s
 WHERE l.warehouse_id IS NULL AND l.ref_type IN ('sale', 'sale_void') AND l.ref_id = s.id;
-- Le reste (dépenses, anciennes dettes reprises, remboursements) : le point de vente principal
UPDATE sales.expenses e SET warehouse_id = w.id
  FROM inventory.warehouses w
 WHERE e.warehouse_id IS NULL AND w.business_id = e.business_id AND w.is_default;
UPDATE sales.customer_ledger l SET warehouse_id = w.id
  FROM inventory.warehouses w
 WHERE l.warehouse_id IS NULL AND w.business_id = l.business_id AND w.is_default;

CREATE INDEX IF NOT EXISTS expenses_warehouse_idx ON sales.expenses (business_id, warehouse_id, spent_at DESC);
CREATE INDEX IF NOT EXISTS customer_ledger_warehouse_idx ON sales.customer_ledger (business_id, warehouse_id);
