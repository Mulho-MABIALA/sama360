-- Option du patron : obliger à ouvrir la caisse avant de vendre (désactivée par défaut).
-- Les ventes faites hors ligne, déjà conclues en boutique, restent toujours acceptées.
ALTER TABLE core.businesses
  ADD COLUMN IF NOT EXISTS require_open_cash boolean NOT NULL DEFAULT false;
