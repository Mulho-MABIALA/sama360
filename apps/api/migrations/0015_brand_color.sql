-- Couleur choisie par le commerçant : accents de l'app, reçus, factures et boutique en ligne.
ALTER TABLE core.businesses
  ADD COLUMN IF NOT EXISTS brand_color varchar(7)
  CHECK (brand_color IS NULL OR brand_color ~ '^#[0-9A-F]{6}$');
