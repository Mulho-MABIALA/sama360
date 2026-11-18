-- =====================================================================
-- Sama360 — 0025 : photo de facture fournisseur → achat et stock
-- L'IA lit la facture ; on retient quel produit correspond à chaque libellé
-- du fournisseur, pour le reconnaître tout seul la fois suivante.
-- =====================================================================

-- Factures lues par jour (maîtrise du coût, comme les questions à l'assistant)
ALTER TABLE core.assistant_usage ADD COLUMN IF NOT EXISTS scans int NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS purchasing.item_aliases (
  business_id  uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  supplier_id  uuid NOT NULL REFERENCES contacts.contacts(id) ON DELETE CASCADE,
  label_norm   varchar(160) NOT NULL,        -- libellé de la facture, sans accents ni ponctuation
  product_id   uuid NOT NULL REFERENCES catalog.products(id) ON DELETE CASCADE,
  updated_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (business_id, supplier_id, label_norm)
);

DO $$
BEGIN
  ALTER TABLE purchasing.item_aliases ENABLE ROW LEVEL SECURITY;
  ALTER TABLE purchasing.item_aliases FORCE ROW LEVEL SECURITY;
  DROP POLICY IF EXISTS tenant_isolation ON purchasing.item_aliases;
  CREATE POLICY tenant_isolation ON purchasing.item_aliases
    USING (business_id = core.current_business_id()) WITH CHECK (business_id = core.current_business_id());
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sama_app') AND current_user <> 'sama_app' THEN
    GRANT SELECT, INSERT, UPDATE, DELETE ON purchasing.item_aliases TO sama_app;
  END IF;
END $$;
