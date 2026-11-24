-- =====================================================================
-- Sama360 — 0038 : besoins des métiers
-- Restaurant : suppléments et options d'un plat (extras), ajoutés au prix.
-- Alimentation : date de péremption du stock (expires_on).
-- Téléphonie : numéro de série / IMEI à la vente, garantie en mois.
-- =====================================================================
ALTER TABLE catalog.products ADD COLUMN IF NOT EXISTS extras jsonb;
ALTER TABLE catalog.products ADD COLUMN IF NOT EXISTS expires_on date;
ALTER TABLE catalog.products ADD COLUMN IF NOT EXISTS warranty_months integer
  CHECK (warranty_months IS NULL OR warranty_months BETWEEN 0 AND 120);
ALTER TABLE catalog.products ADD COLUMN IF NOT EXISTS track_serial boolean NOT NULL DEFAULT false;
ALTER TABLE sales.sale_items ADD COLUMN IF NOT EXISTS serials text[];
ALTER TABLE sales.sale_items ADD COLUMN IF NOT EXISTS warranty_until date;
CREATE INDEX IF NOT EXISTS sale_items_serials_idx ON sales.sale_items USING gin (serials) WHERE serials IS NOT NULL;
