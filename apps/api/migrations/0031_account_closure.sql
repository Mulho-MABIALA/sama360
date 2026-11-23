-- =====================================================================
-- Sama360 — 0031 : suppression d'une boutique et d'un compte
-- Suppression douce : 30 jours pour changer d'avis (restaurer la boutique,
-- ou se reconnecter pour garder son compte), puis effacement définitif :
-- la boutique et toutes ses données ; le compte est rendu anonyme (le numéro
-- redevient libre pour une nouvelle inscription).
-- =====================================================================
ALTER TABLE core.users ALTER COLUMN phone TYPE varchar(64);
ALTER TABLE core.users ADD COLUMN IF NOT EXISTS deleted_at timestamptz;
ALTER TABLE core.businesses ADD COLUMN IF NOT EXISTS deleted_by uuid REFERENCES core.users(id);
-- Supprimée avec le compte du propriétaire : revient s'il se reconnecte dans les 30 jours
ALTER TABLE core.businesses ADD COLUMN IF NOT EXISTS deleted_with_account boolean NOT NULL DEFAULT false;
CREATE INDEX IF NOT EXISTS businesses_deleted_idx ON core.businesses (deleted_at) WHERE deleted_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS users_deleted_idx ON core.users (deleted_at) WHERE deleted_at IS NOT NULL;
