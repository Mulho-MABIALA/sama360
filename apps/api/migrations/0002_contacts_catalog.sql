-- =====================================================================
-- Sama360 — 0002 : contacts et catalogue (données métier, isolées par RLS)
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS contacts;
CREATE SCHEMA IF NOT EXISTS catalog;

CREATE TABLE contacts.contacts (
  id           uuid PRIMARY KEY,
  business_id  uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  type         varchar(10) NOT NULL DEFAULT 'customer', -- customer, supplier, both
  name         varchar(120) NOT NULL,
  phone        varchar(20),
  email        varchar(160),
  address      text,
  notes        text,
  balance      bigint NOT NULL DEFAULT 0, -- cache du solde dû (journal dans le module sales)
  version      int NOT NULL DEFAULT 1,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  deleted_at   timestamptz,
  CONSTRAINT contacts_type_chk CHECK (type IN ('customer', 'supplier', 'both'))
);
CREATE INDEX contacts_business_phone_idx ON contacts.contacts (business_id, phone);
CREATE INDEX contacts_business_name_idx ON contacts.contacts (business_id, lower(name));

CREATE TABLE catalog.categories (
  id           uuid PRIMARY KEY,
  business_id  uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  name         varchar(80) NOT NULL,
  position     int NOT NULL DEFAULT 0,
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (business_id, name)
);

CREATE TABLE catalog.products (
  id                   uuid PRIMARY KEY,
  business_id          uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  category_id          uuid REFERENCES catalog.categories(id) ON DELETE SET NULL,
  type                 varchar(10) NOT NULL DEFAULT 'product', -- product, service
  name                 varchar(160) NOT NULL,
  sku                  varchar(60),
  barcode              varchar(60),
  price                bigint NOT NULL CHECK (price >= 0),
  cost                 bigint NOT NULL DEFAULT 0 CHECK (cost >= 0),
  unit                 varchar(20) NOT NULL DEFAULT 'pièce',
  track_stock          boolean NOT NULL DEFAULT true,
  low_stock_threshold  int NOT NULL DEFAULT 5,
  published            boolean NOT NULL DEFAULT false,
  image_file_ids       uuid[] NOT NULL DEFAULT '{}',
  version              int NOT NULL DEFAULT 1,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  deleted_at           timestamptz,
  CONSTRAINT products_type_chk CHECK (type IN ('product', 'service'))
);
CREATE UNIQUE INDEX products_business_sku_uq ON catalog.products (business_id, sku) WHERE sku IS NOT NULL;
CREATE INDEX products_business_name_idx ON catalog.products (business_id, lower(name));

-- ---------- Row Level Security ----------
-- FORCE : la politique s'applique aussi au propriétaire des tables (rôle de l'API).
-- Attention : un rôle SUPERUSER ou BYPASSRLS ignore toujours la RLS.

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'contacts.contacts',
    'catalog.categories',
    'catalog.products',
    'core.module_activations'
  ] LOOP
    EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %s FORCE ROW LEVEL SECURITY', t);
    EXECUTE format(
      'CREATE POLICY tenant_isolation ON %s USING (business_id = core.current_business_id()) WITH CHECK (business_id = core.current_business_id())',
      t
    );
  END LOOP;
END $$;
