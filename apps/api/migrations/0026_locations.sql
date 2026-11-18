-- =====================================================================
-- Sama360 — 0026 : plusieurs points de vente
-- Un commerce peut avoir plusieurs boutiques (points de vente) : chacune a son
-- stock, sa caisse et ses ventes ; le catalogue et les clients restent communs.
-- On s'appuie sur inventory.warehouses (déjà présent sur ventes, achats, stock).
-- =====================================================================

ALTER TABLE inventory.warehouses
  ADD COLUMN IF NOT EXISTS address     varchar(200),
  ADD COLUMN IF NOT EXISTS phone       varchar(20),
  ADD COLUMN IF NOT EXISTS archived_at timestamptz;

-- Un membre peut être rattaché à un seul point de vente (vendeur) ; NULL = tous
ALTER TABLE core.memberships
  ADD COLUMN IF NOT EXISTS warehouse_id uuid REFERENCES inventory.warehouses(id) ON DELETE SET NULL;

-- La caisse est ouverte dans un point de vente
ALTER TABLE sales.cash_sessions
  ADD COLUMN IF NOT EXISTS warehouse_id uuid REFERENCES inventory.warehouses(id);
UPDATE sales.cash_sessions s SET warehouse_id = w.id
FROM inventory.warehouses w
WHERE w.business_id = s.business_id AND w.is_default AND s.warehouse_id IS NULL;
CREATE INDEX IF NOT EXISTS cash_sessions_warehouse_idx ON sales.cash_sessions (business_id, warehouse_id, opened_at DESC);

CREATE INDEX IF NOT EXISTS sales_warehouse_idx ON sales.sales (business_id, warehouse_id, sold_at DESC);

-- Transferts de marchandise entre points de vente
ALTER TABLE inventory.stock_movements DROP CONSTRAINT IF EXISTS stock_movements_type_chk;
ALTER TABLE inventory.stock_movements ADD CONSTRAINT stock_movements_type_chk
  CHECK (type IN ('purchase', 'sale', 'return', 'adjustment', 'count', 'transfer'));
-- Un transfert fait sortir puis entrer le même produit : l'unicité porte aussi sur le dépôt
DROP INDEX IF EXISTS inventory.stock_movements_ref_uq;
CREATE UNIQUE INDEX stock_movements_ref_uq ON inventory.stock_movements (ref_type, ref_id, product_id, type, warehouse_id)
  WHERE ref_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS inventory.transfers (
  id                 uuid PRIMARY KEY,           -- peut venir du téléphone : renvoi sans doublon
  business_id        uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  number             varchar(30) NOT NULL,
  from_warehouse_id  uuid NOT NULL REFERENCES inventory.warehouses(id),
  to_warehouse_id    uuid NOT NULL REFERENCES inventory.warehouses(id),
  lines              jsonb NOT NULL,             -- [{ productId, name, quantity }]
  note               text,
  created_by         uuid NOT NULL REFERENCES core.users(id),
  created_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (business_id, number),
  CONSTRAINT transfers_distinct_chk CHECK (from_warehouse_id <> to_warehouse_id)
);
CREATE INDEX IF NOT EXISTS transfers_business_idx ON inventory.transfers (business_id, created_at DESC);

DO $$
BEGIN
  ALTER TABLE inventory.transfers ENABLE ROW LEVEL SECURITY;
  ALTER TABLE inventory.transfers FORCE ROW LEVEL SECURITY;
  DROP POLICY IF EXISTS tenant_isolation ON inventory.transfers;
  CREATE POLICY tenant_isolation ON inventory.transfers
    USING (business_id = core.current_business_id()) WITH CHECK (business_id = core.current_business_id());
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sama_app') AND current_user <> 'sama_app' THEN
    GRANT SELECT, INSERT, UPDATE, DELETE ON inventory.transfers TO sama_app;
  END IF;
END $$;
