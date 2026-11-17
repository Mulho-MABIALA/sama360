-- Relances : historique des rappels de paiement (crédit client ou facture) et date du dernier
-- rappel sur chaque facture (celle des clients existe déjà : contacts.contacts.last_reminded_at).
ALTER TABLE invoicing.documents ADD COLUMN IF NOT EXISTS last_reminded_at timestamptz;

CREATE TABLE sales.reminders (
  id           uuid PRIMARY KEY,
  business_id  uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  customer_id  uuid NOT NULL REFERENCES contacts.contacts(id),
  invoice_id   uuid REFERENCES invoicing.documents(id),
  channel      varchar(12) NOT NULL CHECK (channel IN ('whatsapp', 'sms', 'call')),
  amount       bigint NOT NULL DEFAULT 0,     -- somme due au moment du rappel
  created_by   uuid REFERENCES core.users(id),
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX reminders_business_idx ON sales.reminders (business_id, created_at DESC);
CREATE INDEX reminders_customer_idx ON sales.reminders (customer_id, created_at DESC);

ALTER TABLE sales.reminders ENABLE ROW LEVEL SECURITY;
ALTER TABLE sales.reminders FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON sales.reminders
  USING (business_id = core.current_business_id())
  WITH CHECK (business_id = core.current_business_id());

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sama_app') AND current_user <> 'sama_app' THEN
    GRANT SELECT, INSERT, UPDATE, DELETE ON sales.reminders TO sama_app;
  END IF;
END $$;
