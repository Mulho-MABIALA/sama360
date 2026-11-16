-- =====================================================================
-- Sama360 — 0010 : fournisseurs et achats
-- Bon de commande (BC-…) → réceptions (la marchandise entre en stock et le
-- coût moyen d'achat est recalculé) → paiements au fournisseur.
-- Dette fournisseur d'un bon = valeur reçue − montant payé.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS purchasing;

CREATE TABLE purchasing.sequences (
  business_id  uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  key          varchar(20) NOT NULL,
  year         int NOT NULL,
  last_value   int NOT NULL DEFAULT 0,
  PRIMARY KEY (business_id, key, year)
);

CREATE TABLE purchasing.orders (
  id              uuid PRIMARY KEY,           -- peut venir du mobile : renvoi sans doublon
  business_id     uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  number          varchar(30) NOT NULL,
  status          varchar(12) NOT NULL,       -- draft, ordered, partial, received, cancelled
  supplier_id     uuid NOT NULL REFERENCES contacts.contacts(id),
  order_date      date NOT NULL,
  expected_date   date,
  total           bigint NOT NULL,            -- valeur commandée
  received_total  bigint NOT NULL DEFAULT 0,  -- valeur reçue (ce qu'on doit vraiment)
  paid            bigint NOT NULL DEFAULT 0,
  note            text,
  warehouse_id    uuid NOT NULL REFERENCES inventory.warehouses(id),
  created_by      uuid NOT NULL REFERENCES core.users(id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  received_at     timestamptz,
  cancelled_at    timestamptz,
  UNIQUE (business_id, number),
  CONSTRAINT orders_status_chk CHECK (status IN ('draft', 'ordered', 'partial', 'received', 'cancelled')),
  CONSTRAINT orders_amounts_chk CHECK (total >= 0 AND received_total >= 0 AND paid >= 0)
);
CREATE INDEX orders_business_idx ON purchasing.orders (business_id, order_date DESC, created_at DESC);
CREATE INDEX orders_supplier_idx ON purchasing.orders (business_id, supplier_id);

CREATE TABLE purchasing.order_lines (
  id            uuid PRIMARY KEY,
  business_id   uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  order_id      uuid NOT NULL REFERENCES purchasing.orders(id) ON DELETE CASCADE,
  position      int NOT NULL,
  product_id    uuid NOT NULL REFERENCES catalog.products(id),
  name          varchar(160) NOT NULL,
  quantity      numeric(12,3) NOT NULL CHECK (quantity > 0),
  received_qty  numeric(12,3) NOT NULL DEFAULT 0 CHECK (received_qty >= 0),
  unit_cost     bigint NOT NULL CHECK (unit_cost >= 0),
  total         bigint NOT NULL
);
CREATE INDEX order_lines_order_idx ON purchasing.order_lines (order_id, position);

CREATE TABLE purchasing.receipts (
  id           uuid PRIMARY KEY,
  business_id  uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  order_id     uuid NOT NULL REFERENCES purchasing.orders(id) ON DELETE CASCADE,
  total        bigint NOT NULL,
  note         text,
  received_at  timestamptz NOT NULL,
  created_by   uuid NOT NULL REFERENCES core.users(id)
);
CREATE INDEX receipts_order_idx ON purchasing.receipts (order_id, received_at);

CREATE TABLE purchasing.receipt_lines (
  id           uuid PRIMARY KEY,
  business_id  uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  receipt_id   uuid NOT NULL REFERENCES purchasing.receipts(id) ON DELETE CASCADE,
  line_id      uuid NOT NULL REFERENCES purchasing.order_lines(id) ON DELETE CASCADE,
  product_id   uuid NOT NULL REFERENCES catalog.products(id),
  quantity     numeric(12,3) NOT NULL CHECK (quantity > 0),
  unit_cost    bigint NOT NULL CHECK (unit_cost >= 0)
);
CREATE INDEX receipt_lines_receipt_idx ON purchasing.receipt_lines (receipt_id);

CREATE TABLE purchasing.payments (
  id           uuid PRIMARY KEY,
  business_id  uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  order_id     uuid NOT NULL REFERENCES purchasing.orders(id) ON DELETE CASCADE,
  supplier_id  uuid NOT NULL REFERENCES contacts.contacts(id),
  method       varchar(15) NOT NULL,
  amount       bigint NOT NULL CHECK (amount > 0),
  reference    varchar(80),
  paid_at      timestamptz NOT NULL,
  created_by   uuid NOT NULL REFERENCES core.users(id),
  CONSTRAINT purchase_payments_method_chk CHECK (method IN ('cash', 'wave', 'orange_money', 'free_money', 'card', 'transfer', 'cheque'))
);
CREATE INDEX purchase_payments_order_idx ON purchasing.payments (order_id, paid_at);
CREATE INDEX purchase_payments_supplier_idx ON purchasing.payments (business_id, supplier_id, paid_at DESC);

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'purchasing.sequences', 'purchasing.orders', 'purchasing.order_lines',
    'purchasing.receipts', 'purchasing.receipt_lines', 'purchasing.payments'
  ] LOOP
    EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %s FORCE ROW LEVEL SECURITY', t);
    EXECUTE format(
      'CREATE POLICY tenant_isolation ON %s USING (business_id = core.current_business_id()) WITH CHECK (business_id = core.current_business_id())',
      t
    );
  END LOOP;

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sama_app') AND current_user <> 'sama_app' THEN
    GRANT USAGE ON SCHEMA purchasing TO sama_app;
    GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA purchasing TO sama_app;
  END IF;
END $$;
