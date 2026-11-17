-- Livraison : livreurs et courses (commandes en ligne ou livraisons notées à la main).
CREATE TABLE sales.couriers (
  id           uuid PRIMARY KEY,
  business_id  uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  name         varchar(120) NOT NULL,
  phone        varchar(25),
  vehicle      varchar(10) NOT NULL DEFAULT 'moto' CHECK (vehicle IN ('moto', 'voiture', 'velo', 'pied')),
  active       boolean NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE sales.deliveries (
  id                 uuid PRIMARY KEY,
  business_id        uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  order_id           uuid REFERENCES shop.orders(id),
  customer_name      varchar(120) NOT NULL,
  customer_phone     varchar(25),
  address            text NOT NULL,
  note               text,
  courier_id         uuid REFERENCES sales.couriers(id),
  fee                bigint NOT NULL DEFAULT 0 CHECK (fee >= 0),
  amount_to_collect  bigint NOT NULL DEFAULT 0 CHECK (amount_to_collect >= 0),  -- à encaisser chez le client
  status             varchar(10) NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending', 'assigned', 'picked', 'delivered', 'failed', 'cancelled')),
  failure_reason     varchar(200),
  settled            boolean NOT NULL DEFAULT false,                             -- argent remis par le livreur
  assigned_at        timestamptz,
  picked_at          timestamptz,
  delivered_at       timestamptz,
  settled_at         timestamptz,
  created_by         uuid REFERENCES core.users(id),
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX deliveries_status_idx ON sales.deliveries (business_id, status, created_at DESC);
-- Une seule course en cours par commande en ligne
CREATE UNIQUE INDEX deliveries_active_order_uq ON sales.deliveries (order_id)
  WHERE order_id IS NOT NULL AND status IN ('pending', 'assigned', 'picked', 'delivered');

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['sales.couriers', 'sales.deliveries'] LOOP
    EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %s FORCE ROW LEVEL SECURITY', t);
    EXECUTE format(
      'CREATE POLICY tenant_isolation ON %s USING (business_id = core.current_business_id()) WITH CHECK (business_id = core.current_business_id())',
      t
    );
  END LOOP;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sama_app') AND current_user <> 'sama_app' THEN
    GRANT SELECT, INSERT, UPDATE, DELETE ON sales.couriers, sales.deliveries TO sama_app;
  END IF;
END $$;
