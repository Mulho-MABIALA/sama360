-- Réservation en ligne : réglages (horaires, créneaux, capacité), durée des prestations, origine des rendez-vous.
CREATE TABLE sales.booking_settings (
  business_id         uuid PRIMARY KEY REFERENCES core.businesses(id) ON DELETE CASCADE,
  online_enabled      boolean NOT NULL DEFAULT false,
  open_days           smallint[] NOT NULL DEFAULT '{1,2,3,4,5,6}',   -- 1 = lundi … 7 = dimanche
  open_time           time NOT NULL DEFAULT '09:00',
  close_time          time NOT NULL DEFAULT '19:00',
  slot_minutes        int NOT NULL DEFAULT 30 CHECK (slot_minutes IN (15, 30, 60)),
  capacity            int NOT NULL DEFAULT 1 CHECK (capacity BETWEEN 1 AND 20),  -- rendez-vous en même temps
  min_notice_minutes  int NOT NULL DEFAULT 60 CHECK (min_notice_minutes BETWEEN 0 AND 10080),
  max_days_ahead      int NOT NULL DEFAULT 30 CHECK (max_days_ahead BETWEEN 1 AND 90),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT booking_hours_chk CHECK (close_time > open_time)
);

ALTER TABLE catalog.products
  ADD COLUMN IF NOT EXISTS duration_minutes int CHECK (duration_minutes BETWEEN 5 AND 720);

ALTER TABLE sales.appointments
  ADD COLUMN IF NOT EXISTS source varchar(10) NOT NULL DEFAULT 'staff' CHECK (source IN ('staff', 'online'));

DO $$
BEGIN
  ALTER TABLE sales.booking_settings ENABLE ROW LEVEL SECURITY;
  ALTER TABLE sales.booking_settings FORCE ROW LEVEL SECURITY;
  CREATE POLICY tenant_isolation ON sales.booking_settings
    USING (business_id = core.current_business_id()) WITH CHECK (business_id = core.current_business_id());
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sama_app') AND current_user <> 'sama_app' THEN
    GRANT SELECT, INSERT, UPDATE, DELETE ON sales.booking_settings TO sama_app;
  END IF;
END $$;
