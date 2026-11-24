-- =====================================================================
-- Sama360 — 0036 : variantes de produit (taille, couleur, contenance…)
-- Un produit « modèle » (ex. T-shirt col V) décrit ses options dans
-- variant_axes ; chaque combinaison (T-shirt col V · Noir · M) est un
-- produit à part entière, rattaché par parent_id : son stock, son prix,
-- son code-barres. Ventes, achats et commandes en ligne portent sur la
-- variante ; le modèle ne se vend pas directement.
-- =====================================================================
ALTER TABLE catalog.products ADD COLUMN IF NOT EXISTS parent_id uuid REFERENCES catalog.products(id) ON DELETE CASCADE;
ALTER TABLE catalog.products ADD COLUMN IF NOT EXISTS options jsonb;
ALTER TABLE catalog.products ADD COLUMN IF NOT EXISTS variant_axes jsonb;
CREATE INDEX IF NOT EXISTS products_parent_idx ON catalog.products (parent_id) WHERE parent_id IS NOT NULL;
