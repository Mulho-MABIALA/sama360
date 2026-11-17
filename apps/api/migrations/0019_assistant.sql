-- Assistant IA : nombre de questions par boutique et par jour (plafond pour maîtriser le coût).
-- Les conversations elles-mêmes ne sont pas gardées sur le serveur.
CREATE TABLE core.assistant_usage (
  business_id  uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  day          date NOT NULL,
  questions    int NOT NULL DEFAULT 0,
  PRIMARY KEY (business_id, day)
);

DO $$
BEGIN
  ALTER TABLE core.assistant_usage ENABLE ROW LEVEL SECURITY;
  ALTER TABLE core.assistant_usage FORCE ROW LEVEL SECURITY;
  CREATE POLICY tenant_isolation ON core.assistant_usage
    USING (business_id = core.current_business_id()) WITH CHECK (business_id = core.current_business_id());
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sama_app') AND current_user <> 'sama_app' THEN
    GRANT SELECT, INSERT, UPDATE, DELETE ON core.assistant_usage TO sama_app;
  END IF;
END $$;
