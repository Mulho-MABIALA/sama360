-- =====================================================================
-- Sama360 — 0034 : back office de l'équipe Sama360
-- Suspendre une boutique (abus, impayé…) et garder la trace de chaque
-- action de l'équipe (mois offert, suspension, restauration).
-- =====================================================================
ALTER TABLE core.businesses ADD COLUMN IF NOT EXISTS suspended_at timestamptz;
ALTER TABLE core.businesses ADD COLUMN IF NOT EXISTS suspended_reason text;

CREATE TABLE IF NOT EXISTS core.admin_actions (
  id           uuid PRIMARY KEY,
  admin_id     uuid NOT NULL REFERENCES core.users(id),
  business_id  uuid REFERENCES core.businesses(id) ON DELETE CASCADE,
  action       varchar(30) NOT NULL,
  details      jsonb NOT NULL DEFAULT '{}',
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS admin_actions_business_idx ON core.admin_actions (business_id, created_at DESC);
CREATE INDEX IF NOT EXISTS admin_actions_created_idx ON core.admin_actions (created_at DESC);
