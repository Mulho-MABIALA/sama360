-- Réservation : rendez-vous des clients (salons, couturiers, réparateurs…).
CREATE TABLE sales.appointments (
  id                uuid PRIMARY KEY,
  business_id       uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  customer_id       uuid REFERENCES contacts.contacts(id),
  customer_name     varchar(120) NOT NULL,           -- copie : un client de passage n'a pas de fiche
  customer_phone    varchar(25),
  service_id        uuid REFERENCES catalog.products(id),
  service_name      varchar(160) NOT NULL,
  price             bigint NOT NULL DEFAULT 0 CHECK (price >= 0),
  starts_at         timestamptz NOT NULL,
  duration_minutes  int NOT NULL DEFAULT 30 CHECK (duration_minutes BETWEEN 5 AND 720),
  status            varchar(12) NOT NULL DEFAULT 'booked'
                    CHECK (status IN ('booked', 'done', 'no_show', 'cancelled')),
  note              text,
  created_by        uuid REFERENCES core.users(id),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX appointments_day_idx ON sales.appointments (business_id, starts_at);

DO $$
BEGIN
  ALTER TABLE sales.appointments ENABLE ROW LEVEL SECURITY;
  ALTER TABLE sales.appointments FORCE ROW LEVEL SECURITY;
  CREATE POLICY tenant_isolation ON sales.appointments
    USING (business_id = core.current_business_id()) WITH CHECK (business_id = core.current_business_id());
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sama_app') AND current_user <> 'sama_app' THEN
    GRANT SELECT, INSERT, UPDATE, DELETE ON sales.appointments TO sama_app;
  END IF;
END $$;
