-- =====================================================================
-- Sama360 — 0008 : fiche produit complète
-- Prix de gros (à partir d'une quantité) et codes uniques parmi les
-- produits encore actifs : un produit supprimé libère son code-barres.
-- =====================================================================

ALTER TABLE catalog.products
  ADD COLUMN wholesale_price   bigint CHECK (wholesale_price >= 0),
  ADD COLUMN wholesale_min_qty numeric(12,3) CHECK (wholesale_min_qty > 0),
  ADD CONSTRAINT products_wholesale_chk CHECK ((wholesale_price IS NULL) = (wholesale_min_qty IS NULL));

DROP INDEX IF EXISTS catalog.products_business_sku_uq;
CREATE UNIQUE INDEX products_business_sku_uq
  ON catalog.products (business_id, sku) WHERE sku IS NOT NULL AND deleted_at IS NULL;
CREATE UNIQUE INDEX products_business_barcode_uq
  ON catalog.products (business_id, barcode) WHERE barcode IS NOT NULL AND deleted_at IS NULL;
