-- Fidélité : points gagnés à chaque achat, échangés contre une remise ; anniversaires des clients.

-- Réglages du programme (une ligne par entreprise ; absente = programme désactivé)
CREATE TABLE sales.loyalty_settings (
  business_id    uuid PRIMARY KEY REFERENCES core.businesses(id) ON DELETE CASCADE,
  enabled        boolean NOT NULL DEFAULT true,
  earn_per       integer NOT NULL DEFAULT 1000 CHECK (earn_per BETWEEN 50 AND 1000000),   -- F dépensés pour 1 point
  reward_points  integer NOT NULL DEFAULT 100 CHECK (reward_points BETWEEN 1 AND 1000000), -- points pour une récompense
  reward_value   integer NOT NULL DEFAULT 2000 CHECK (reward_value BETWEEN 50 AND 10000000), -- remise d'une récompense (F)
  updated_at     timestamptz NOT NULL DEFAULT now()
);

-- Journal des points : le solde d'un client est la somme de ses lignes
CREATE TABLE sales.loyalty_ledger (
  id           uuid PRIMARY KEY,
  business_id  uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  customer_id  uuid NOT NULL REFERENCES contacts.contacts(id),
  kind         varchar(10) NOT NULL CHECK (kind IN ('earn', 'redeem', 'reverse', 'adjust')),
  points       integer NOT NULL,                 -- positif : gagnés ; négatif : utilisés ou retirés
  sale_id      uuid,
  note         varchar(200),
  created_by   uuid,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX loyalty_ledger_customer_idx ON sales.loyalty_ledger (customer_id, created_at DESC);
CREATE INDEX loyalty_ledger_sale_idx ON sales.loyalty_ledger (sale_id) WHERE sale_id IS NOT NULL;

-- Anniversaire (jour et mois seulement : l'année n'est pas demandée)
ALTER TABLE contacts.contacts
  ADD COLUMN IF NOT EXISTS birth_day smallint CHECK (birth_day BETWEEN 1 AND 31),
  ADD COLUMN IF NOT EXISTS birth_month smallint CHECK (birth_month BETWEEN 1 AND 12);

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['sales.loyalty_settings', 'sales.loyalty_ledger'] LOOP
    EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %s FORCE ROW LEVEL SECURITY', t);
    EXECUTE format(
      'CREATE POLICY tenant_isolation ON %s USING (business_id = core.current_business_id()) WITH CHECK (business_id = core.current_business_id())',
      t
    );
  END LOOP;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sama_app') AND current_user <> 'sama_app' THEN
    GRANT SELECT, INSERT, UPDATE, DELETE ON sales.loyalty_settings, sales.loyalty_ledger TO sama_app;
  END IF;
END $$;
