-- =====================================================================
-- Sama360 — 0009 : clients et crédit
-- Plafond de crédit par client (null = pas de plafond) et date du
-- dernier rappel de paiement envoyé.
-- =====================================================================
ALTER TABLE contacts.contacts
  ADD COLUMN IF NOT EXISTS credit_limit bigint CHECK (credit_limit >= 0),
  ADD COLUMN IF NOT EXISTS last_reminded_at timestamptz;
