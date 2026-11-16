-- =====================================================================
-- Sama360 — 0006 : photo de profil
-- Une photo de profil appartient à l'utilisateur, pas à une entreprise :
-- core.files.business_id devient facultatif.
-- =====================================================================

ALTER TABLE core.files ALTER COLUMN business_id DROP NOT NULL;

ALTER TABLE core.users
  ADD COLUMN avatar_file_id uuid REFERENCES core.files(id) ON DELETE SET NULL;
