-- =====================================================================
-- Sama360 — 0037 : conditionnement (vendre ou acheter au carton, au sac…)
-- Le stock reste compté à l'unité de base ; pack_size dit combien d'unités
-- contient un carton (ex. 24 pièces, 50 kg).
-- =====================================================================
ALTER TABLE catalog.products ADD COLUMN IF NOT EXISTS pack_name varchar(20);
ALTER TABLE catalog.products ADD COLUMN IF NOT EXISTS pack_size numeric(12, 3)
  CHECK (pack_size IS NULL OR pack_size > 1);
