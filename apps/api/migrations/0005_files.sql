-- =====================================================================
-- Sama360 — 0005 : fichiers (photos produit, puis logos, PDF…)
-- Le contenu est dans le stockage (disque ou S3/R2) ; la base garde les métadonnées.
-- Pas de RLS sur cette table : les photos produit sont publiques (boutique en ligne)
-- et lues par leur identifiant aléatoire ; toute écriture passe par un module qui
-- vérifie l'entreprise.
-- =====================================================================

CREATE TABLE core.files (
  id           uuid PRIMARY KEY,
  business_id  uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  kind         varchar(30) NOT NULL,          -- product_image, logo, document
  storage_key  varchar(255) NOT NULL UNIQUE,
  mime         varchar(60) NOT NULL,
  size         int NOT NULL CHECK (size > 0),
  created_by   uuid REFERENCES core.users(id),
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX files_business_idx ON core.files (business_id, created_at DESC);

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sama_app') AND current_user <> 'sama_app' THEN
    GRANT SELECT, INSERT, UPDATE, DELETE ON core.files TO sama_app;
  END IF;
END $$;
