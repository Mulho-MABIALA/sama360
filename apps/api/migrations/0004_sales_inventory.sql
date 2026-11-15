-- =====================================================================
-- Sama360 — 0004 : ventes (caisse, carnet de crédit, dépenses) et stock
-- Principes : les lignes copient nom et prix au moment de la vente ;
-- le stock et les dettes clients sont des JOURNAUX de mouvements.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS sales;
CREATE SCHEMA IF NOT EXISTS inventory;

-- ---------- Stock ----------

CREATE TABLE inventory.warehouses (
  id           uuid PRIMARY KEY,
  business_id  uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  name         varchar(80) NOT NULL,
  is_default   boolean NOT NULL DEFAULT false,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX warehouses_default_uq ON inventory.warehouses (business_id) WHERE is_default;

CREATE TABLE inventory.stock_movements (
  id            uuid PRIMARY KEY,
  business_id   uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  product_id    uuid NOT NULL REFERENCES catalog.products(id),
  warehouse_id  uuid NOT NULL REFERENCES inventory.warehouses(id),
  type          varchar(15) NOT NULL,       -- purchase, sale, return, adjustment, count
  quantity      numeric(12,3) NOT NULL,     -- + entrée, − sortie
  unit_cost     bigint,
  ref_type      varchar(20),                -- sale, count…
  ref_id        uuid,
  note          text,
  occurred_at   timestamptz NOT NULL DEFAULT now(),
  created_by    uuid,
  CONSTRAINT stock_movements_type_chk CHECK (type IN ('purchase', 'sale', 'return', 'adjustment', 'count')),
  CONSTRAINT stock_movements_qty_chk CHECK (quantity <> 0)
);
CREATE INDEX stock_movements_product_idx ON inventory.stock_movements (business_id, product_id, occurred_at DESC);
-- Une vente ne décrémente qu'une fois chaque produit (idempotence des abonnés)
CREATE UNIQUE INDEX stock_movements_ref_uq ON inventory.stock_movements (ref_type, ref_id, product_id, type)
  WHERE ref_id IS NOT NULL;

-- Cache du stock, mis à jour dans la même transaction que chaque mouvement
CREATE TABLE inventory.stock_levels (
  business_id   uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  product_id    uuid NOT NULL REFERENCES catalog.products(id),
  warehouse_id  uuid NOT NULL REFERENCES inventory.warehouses(id),
  on_hand       numeric(12,3) NOT NULL DEFAULT 0,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (business_id, product_id, warehouse_id)
);

-- ---------- Ventes ----------

-- Numérotation continue par entreprise et par année : VEN-2026-0001
CREATE TABLE sales.sequences (
  business_id  uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  key          varchar(20) NOT NULL,
  year         int NOT NULL,
  last_value   int NOT NULL DEFAULT 0,
  PRIMARY KEY (business_id, key, year)
);

CREATE TABLE sales.sales (
  id            uuid PRIMARY KEY,           -- peut être généré par le mobile (hors ligne)
  business_id   uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  number        varchar(30) NOT NULL,
  customer_id   uuid REFERENCES contacts.contacts(id),
  cashier_id    uuid NOT NULL REFERENCES core.users(id),
  warehouse_id  uuid NOT NULL REFERENCES inventory.warehouses(id),
  source        varchar(10) NOT NULL DEFAULT 'pos',   -- pos, shop, invoice
  status        varchar(12) NOT NULL DEFAULT 'completed', -- completed, voided
  subtotal      bigint NOT NULL,
  discount      bigint NOT NULL DEFAULT 0,
  total         bigint NOT NULL,
  paid          bigint NOT NULL DEFAULT 0,
  due           bigint GENERATED ALWAYS AS (total - paid) STORED,
  cost_total    bigint NOT NULL DEFAULT 0,
  note          text,
  sold_at       timestamptz NOT NULL,
  voided_at     timestamptz,
  void_reason   text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (business_id, number),
  CONSTRAINT sales_amounts_chk CHECK (total >= 0 AND paid >= 0 AND paid <= total AND discount >= 0),
  CONSTRAINT sales_status_chk CHECK (status IN ('completed', 'voided'))
);
CREATE INDEX sales_business_sold_idx ON sales.sales (business_id, sold_at DESC);
CREATE INDEX sales_customer_idx ON sales.sales (business_id, customer_id);

CREATE TABLE sales.sale_items (
  id           uuid PRIMARY KEY,
  business_id  uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  sale_id      uuid NOT NULL REFERENCES sales.sales(id) ON DELETE CASCADE,
  product_id   uuid REFERENCES catalog.products(id),
  name         varchar(160) NOT NULL,
  quantity     numeric(12,3) NOT NULL CHECK (quantity > 0),
  unit_price   bigint NOT NULL CHECK (unit_price >= 0),
  unit_cost    bigint NOT NULL DEFAULT 0,
  discount     bigint NOT NULL DEFAULT 0,
  total        bigint NOT NULL,
  track_stock  boolean NOT NULL DEFAULT false
);
CREATE INDEX sale_items_sale_idx ON sales.sale_items (sale_id);

CREATE TABLE sales.sale_payments (
  id           uuid PRIMARY KEY,
  business_id  uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  sale_id      uuid NOT NULL REFERENCES sales.sales(id) ON DELETE CASCADE,
  method       varchar(15) NOT NULL,      -- cash, wave, orange_money, free_money, card
  amount       bigint NOT NULL CHECK (amount > 0),
  reference    varchar(80),
  paid_at      timestamptz NOT NULL,
  CONSTRAINT sale_payments_method_chk CHECK (method IN ('cash', 'wave', 'orange_money', 'free_money', 'card'))
);
CREATE INDEX sale_payments_sale_idx ON sales.sale_payments (sale_id);

-- Carnet de crédit : + augmente la dette du client, − la diminue
CREATE TABLE sales.customer_ledger (
  id           uuid PRIMARY KEY,
  business_id  uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  customer_id  uuid NOT NULL REFERENCES contacts.contacts(id),
  entry_type   varchar(12) NOT NULL,      -- debt, repayment, adjustment
  amount       bigint NOT NULL CHECK (amount <> 0),
  method       varchar(15),
  ref_type     varchar(20),
  ref_id       uuid,
  note         text,
  occurred_at  timestamptz NOT NULL,
  created_by   uuid,
  CONSTRAINT customer_ledger_type_chk CHECK (entry_type IN ('debt', 'repayment', 'adjustment'))
);
CREATE INDEX customer_ledger_customer_idx ON sales.customer_ledger (business_id, customer_id, occurred_at DESC);

CREATE TABLE sales.expenses (
  id           uuid PRIMARY KEY,
  business_id  uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  category     varchar(40) NOT NULL,
  amount       bigint NOT NULL CHECK (amount > 0),
  method       varchar(15),
  note         text,
  spent_at     date NOT NULL,
  created_by   uuid NOT NULL REFERENCES core.users(id),
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX expenses_business_date_idx ON sales.expenses (business_id, spent_at DESC);

-- ---------- Row Level Security ----------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'inventory.warehouses', 'inventory.stock_movements', 'inventory.stock_levels',
    'sales.sequences', 'sales.sales', 'sales.sale_items', 'sales.sale_payments',
    'sales.customer_ledger', 'sales.expenses'
  ] LOOP
    EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %s FORCE ROW LEVEL SECURITY', t);
    EXECUTE format(
      'CREATE POLICY tenant_isolation ON %s USING (business_id = core.current_business_id()) WITH CHECK (business_id = core.current_business_id())',
      t
    );
  END LOOP;
END $$;

-- ---------- Droits du rôle applicatif (voir 0003) ----------
DO $$
DECLARE s text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sama_app') OR current_user = 'sama_app' THEN
    RETURN;
  END IF;
  FOREACH s IN ARRAY ARRAY['sales', 'inventory'] LOOP
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO sama_app', s);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA %I TO sama_app', s);
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO sama_app', s);
  END LOOP;
END $$;
