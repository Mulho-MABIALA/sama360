-- =====================================================================
-- Sama360 — 0035 : vitrine de la boutique en ligne
-- Une image de couverture et une phrase d'accroche, affichées en grand
-- en haut de la page publique (/s/{slug}).
-- =====================================================================
ALTER TABLE shop.settings ADD COLUMN IF NOT EXISTS cover_file_id uuid REFERENCES core.files(id) ON DELETE SET NULL;
ALTER TABLE shop.settings ADD COLUMN IF NOT EXISTS tagline varchar(120);
