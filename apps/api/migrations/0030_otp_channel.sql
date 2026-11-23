-- =====================================================================
-- Sama360 — 0030 : moyen d'envoi du code de connexion
-- WhatsApp, SMS ou appel vocal, au choix du commerçant. Changer de moyen
-- est permis plus vite qu'un simple renvoi : on retient le moyen utilisé.
-- =====================================================================
ALTER TABLE core.otp_codes ADD COLUMN IF NOT EXISTS channel varchar(10);
