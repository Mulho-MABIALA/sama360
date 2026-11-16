-- =====================================================================
-- Sama360 — 0011 : boutique en ligne
-- Une page publique par entreprise (/s/{slug}) montre les produits publiés.
-- Le client commande sans compte (nom + téléphone) ; le commerçant confirme,
-- prépare, livre, puis la commande devient une vente (stock et caisse).
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS shop;

CREATE TABLE shop.settings (
  business_id    uuid PRIMARY KEY REFERENCES core.businesses(id) ON DELETE CASCADE,
  enabled        boolean NOT NULL DEFAULT false,
  title          varchar(120),
  description    text,
  whatsapp       varchar(20),
  pickup         boolean NOT NULL DEFAULT true,
  delivery       boolean NOT NULL DEFAULT true,
  delivery_fee   bigint NOT NULL DEFAULT 0 CHECK (delivery_fee >= 0),
  delivery_zone  varchar(200),
  min_order      bigint NOT NULL DEFAULT 0 CHECK (min_order >= 0),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT settings_mode_chk CHECK (pickup OR delivery)
);

CREATE TABLE shop.sequences (
  business_id  uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  key          varchar(20) NOT NULL,
  year         int NOT NULL,
  last_value   int NOT NULL DEFAULT 0,
  PRIMARY KEY (business_id, key, year)
);

CREATE TABLE shop.orders (
  id              uuid PRIMARY KEY,            -- vient de la page web : renvoi sans doublon
  business_id     uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  number          varchar(30) NOT NULL,
  status          varchar(12) NOT NULL,        -- new, confirmed, ready, delivering, completed, cancelled
  customer_name   varchar(120) NOT NULL,
  customer_phone  varchar(20) NOT NULL,
  contact_id      uuid REFERENCES contacts.contacts(id),
  mode            varchar(10) NOT NULL,        -- pickup, delivery
  address         text,
  note            text,
  subtotal        bigint NOT NULL,
  delivery_fee    bigint NOT NULL DEFAULT 0,
  total           bigint NOT NULL,
  sale_id         uuid,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  confirmed_at    timestamptz,
  completed_at    timestamptz,
  cancelled_at    timestamptz,
  cancel_reason   text,
  UNIQUE (business_id, number),
  CONSTRAINT orders_status_chk CHECK (status IN ('new', 'confirmed', 'ready', 'delivering', 'completed', 'cancelled')),
  CONSTRAINT orders_mode_chk CHECK (mode IN ('pickup', 'delivery')),
  CONSTRAINT orders_amounts_chk CHECK (subtotal >= 0 AND delivery_fee >= 0 AND total = subtotal + delivery_fee)
);
CREATE INDEX shop_orders_business_idx ON shop.orders (business_id, created_at DESC);
CREATE INDEX shop_orders_status_idx ON shop.orders (business_id, status);

CREATE TABLE shop.order_lines (
  id           uuid PRIMARY KEY,
  business_id  uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  order_id     uuid NOT NULL REFERENCES shop.orders(id) ON DELETE CASCADE,
  position     int NOT NULL,
  product_id   uuid NOT NULL REFERENCES catalog.products(id),
  name         varchar(160) NOT NULL,
  quantity     numeric(12,3) NOT NULL CHECK (quantity > 0),
  unit_price   bigint NOT NULL CHECK (unit_price >= 0),
  total        bigint NOT NULL
);
CREATE INDEX shop_order_lines_order_idx ON shop.order_lines (order_id, position);

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['shop.settings', 'shop.sequences', 'shop.orders', 'shop.order_lines'] LOOP
    EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %s FORCE ROW LEVEL SECURITY', t);
    EXECUTE format(
      'CREATE POLICY tenant_isolation ON %s USING (business_id = core.current_business_id()) WITH CHECK (business_id = core.current_business_id())',
      t
    );
  END LOOP;

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sama_app') AND current_user <> 'sama_app' THEN
    GRANT USAGE ON SCHEMA shop TO sama_app;
    GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA shop TO sama_app;
  END IF;
END $$;
