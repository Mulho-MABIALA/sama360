-- Documents du commerce : registre de commerce, NINEA, factures fournisseurs, contrats, bons de livraison…
-- Fichier (photo ou PDF) dans core.files (kind = 'document'), jamais servi par l'adresse publique.
CREATE TABLE core.documents (
  id           uuid PRIMARY KEY,
  business_id  uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  title        varchar(120) NOT NULL,
  category     varchar(20) NOT NULL
               CHECK (category IN ('admin', 'supplier_invoice', 'contract', 'delivery', 'receipt', 'other')),
  file_id      uuid NOT NULL REFERENCES core.files(id),
  note         text,
  expires_on   date,                               -- bail, assurance, autorisation… : rappel avant l'échéance
  created_by   uuid REFERENCES core.users(id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  deleted_at   timestamptz
);
CREATE INDEX documents_business_idx ON core.documents (business_id, created_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX documents_expiry_idx ON core.documents (business_id, expires_on) WHERE deleted_at IS NULL AND expires_on IS NOT NULL;

DO $$
BEGIN
  ALTER TABLE core.documents ENABLE ROW LEVEL SECURITY;
  ALTER TABLE core.documents FORCE ROW LEVEL SECURITY;
  CREATE POLICY tenant_isolation ON core.documents
    USING (business_id = core.current_business_id()) WITH CHECK (business_id = core.current_business_id());
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sama_app') AND current_user <> 'sama_app' THEN
    GRANT SELECT, INSERT, UPDATE, DELETE ON core.documents TO sama_app;
  END IF;
END $$;

-- Droits : le gérant gère les documents, le comptable les consulte, le vendeur n'y a pas accès.
UPDATE core.roles SET permissions = permissions || '["documents:*"]'::jsonb
  WHERE business_id IS NULL AND key = 'manager' AND NOT permissions @> '["documents:*"]'::jsonb;
UPDATE core.roles SET permissions = permissions || '["documents:read"]'::jsonb
  WHERE business_id IS NULL AND key = 'accountant' AND NOT permissions @> '["documents:read"]'::jsonb;
