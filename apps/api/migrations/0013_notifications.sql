-- Notifications dans l'app (cloche de l'accueil).
-- Une notification appartient à l'entreprise ; elle est visible par les membres qui ont la
-- permission `audience`, ou seulement par `user_id` quand il est renseigné.
-- L'état « lu » est propre à chaque membre (core.notification_reads).
CREATE TABLE core.notifications (
  id           uuid PRIMARY KEY,
  business_id  uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  kind         varchar(30) NOT NULL,           -- stock_low, shop_order, sale_voided, invoices_overdue, credit_stale, cash_open…
  title        varchar(160) NOT NULL,
  body         varchar(400) NOT NULL DEFAULT '',
  link         varchar(200),                   -- écran de l'app à ouvrir (/shop/orders/…)
  audience     varchar(40) NOT NULL,           -- permission requise pour la voir
  user_id      uuid REFERENCES core.users(id) ON DELETE CASCADE,
  actor_id     uuid,                           -- auteur de l'action : il ne reçoit pas sa propre notification
  dedupe_key   varchar(160),
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX notifications_business_idx ON core.notifications (business_id, created_at DESC);
CREATE UNIQUE INDEX notifications_dedupe_idx ON core.notifications (business_id, dedupe_key) WHERE dedupe_key IS NOT NULL;

CREATE TABLE core.notification_reads (
  notification_id uuid NOT NULL REFERENCES core.notifications(id) ON DELETE CASCADE,
  user_id         uuid NOT NULL REFERENCES core.users(id) ON DELETE CASCADE,
  business_id     uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  read_at         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (notification_id, user_id)
);

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['core.notifications', 'core.notification_reads'] LOOP
    EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %s FORCE ROW LEVEL SECURITY', t);
    EXECUTE format(
      'CREATE POLICY tenant_isolation ON %s USING (business_id = core.current_business_id()) WITH CHECK (business_id = core.current_business_id())',
      t
    );
  END LOOP;

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sama_app') AND current_user <> 'sama_app' THEN
    GRANT SELECT, INSERT, UPDATE, DELETE ON core.notifications, core.notification_reads TO sama_app;
  END IF;
END $$;
