-- =====================================================================
-- Sama360 — 0007 : factures et devis
-- Un même tableau pour les deux : un devis (DEV-…) devient une facture (FAC-…)
-- quand le client l'accepte. Une facture émise n'est plus modifiable : on l'annule.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS invoicing;

CREATE TABLE invoicing.sequences (
  business_id  uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  key          varchar(20) NOT NULL,        -- quote, invoice
  year         int NOT NULL,
  last_value   int NOT NULL DEFAULT 0,
  PRIMARY KEY (business_id, key, year)
);

CREATE TABLE invoicing.documents (
  id              uuid PRIMARY KEY,
  business_id     uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  kind            varchar(10) NOT NULL,      -- quote, invoice
  number          varchar(30) NOT NULL,
  status          varchar(12) NOT NULL,
  -- devis   : pending, accepted, declined, invoiced
  -- facture : unpaid, partial, paid, cancelled
  customer_id     uuid NOT NULL REFERENCES contacts.contacts(id),
  issue_date      date NOT NULL,
  due_date        date,                      -- facture : échéance ; devis : valable jusqu'au
  subtotal        bigint NOT NULL,
  discount        bigint NOT NULL DEFAULT 0,
  total           bigint NOT NULL,
  paid            bigint NOT NULL DEFAULT 0,
  note            text,
  warehouse_id    uuid REFERENCES inventory.warehouses(id),
  source_id       uuid REFERENCES invoicing.documents(id),   -- facture : devis d'origine
  created_by      uuid NOT NULL REFERENCES core.users(id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  cancelled_at    timestamptz,
  cancel_reason   text,
  UNIQUE (business_id, number),
  CONSTRAINT documents_kind_chk CHECK (kind IN ('quote', 'invoice')),
  CONSTRAINT documents_status_chk CHECK (
    (kind = 'quote' AND status IN ('pending', 'accepted', 'declined', 'invoiced')) OR
    (kind = 'invoice' AND status IN ('unpaid', 'partial', 'paid', 'cancelled'))
  ),
  CONSTRAINT documents_amounts_chk CHECK (total >= 0 AND discount >= 0 AND paid >= 0 AND paid <= total)
);
CREATE INDEX documents_business_idx ON invoicing.documents (business_id, kind, created_at DESC);
CREATE INDEX documents_customer_idx ON invoicing.documents (business_id, customer_id);
-- Un devis ne donne qu'une seule facture
CREATE UNIQUE INDEX documents_source_uq ON invoicing.documents (source_id) WHERE source_id IS NOT NULL;

CREATE TABLE invoicing.document_lines (
  id           uuid PRIMARY KEY,
  business_id  uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  document_id  uuid NOT NULL REFERENCES invoicing.documents(id) ON DELETE CASCADE,
  position     int NOT NULL,
  product_id   uuid REFERENCES catalog.products(id),
  name         varchar(160) NOT NULL,
  description  varchar(500),
  quantity     numeric(12,3) NOT NULL CHECK (quantity > 0),
  unit_price   bigint NOT NULL CHECK (unit_price >= 0),
  unit_cost    bigint NOT NULL DEFAULT 0,
  discount     bigint NOT NULL DEFAULT 0,
  total        bigint NOT NULL,
  track_stock  boolean NOT NULL DEFAULT false
);
CREATE INDEX document_lines_doc_idx ON invoicing.document_lines (document_id, position);

CREATE TABLE invoicing.payments (
  id           uuid PRIMARY KEY,           -- peut venir du mobile : renvoi sans doublon
  business_id  uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  document_id  uuid NOT NULL REFERENCES invoicing.documents(id) ON DELETE CASCADE,
  method       varchar(15) NOT NULL,
  amount       bigint NOT NULL CHECK (amount > 0),
  reference    varchar(80),
  paid_at      timestamptz NOT NULL,
  created_by   uuid NOT NULL REFERENCES core.users(id),
  CONSTRAINT payments_method_chk CHECK (method IN ('cash', 'wave', 'orange_money', 'free_money', 'card', 'transfer', 'cheque'))
);
CREATE INDEX payments_doc_idx ON invoicing.payments (document_id, paid_at);

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'invoicing.sequences', 'invoicing.documents', 'invoicing.document_lines', 'invoicing.payments'
  ] LOOP
    EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %s FORCE ROW LEVEL SECURITY', t);
    EXECUTE format(
      'CREATE POLICY tenant_isolation ON %s USING (business_id = core.current_business_id()) WITH CHECK (business_id = core.current_business_id())',
      t
    );
  END LOOP;

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sama_app') AND current_user <> 'sama_app' THEN
    GRANT USAGE ON SCHEMA invoicing TO sama_app;
    GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA invoicing TO sama_app;
  END IF;
END $$;
