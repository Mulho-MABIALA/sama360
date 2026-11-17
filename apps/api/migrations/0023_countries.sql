-- Lancement dans 3 pays : Sénégal (SN), Côte d'Ivoire (CI), Congo-Brazzaville (CG).
-- La colonne country existe déjà (SN par défaut) : on la borne, avec la monnaie qui va avec.
ALTER TABLE core.businesses DROP CONSTRAINT IF EXISTS businesses_country_chk;
ALTER TABLE core.businesses ADD CONSTRAINT businesses_country_chk CHECK (country IN ('SN', 'CI', 'CG'));
ALTER TABLE core.businesses DROP CONSTRAINT IF EXISTS businesses_currency_chk;
ALTER TABLE core.businesses ADD CONSTRAINT businesses_currency_chk CHECK (currency IN ('XOF', 'XAF'));

-- Paiements mobiles des nouveaux pays : MTN MoMo, Moov Money, Airtel Money
ALTER TABLE sales.sale_payments DROP CONSTRAINT IF EXISTS sale_payments_method_chk;
ALTER TABLE sales.sale_payments ADD CONSTRAINT sale_payments_method_chk
  CHECK (method IN ('cash', 'wave', 'orange_money', 'free_money', 'mtn_momo', 'moov_money', 'airtel_money', 'card'));

ALTER TABLE purchasing.payments DROP CONSTRAINT IF EXISTS purchase_payments_method_chk;
ALTER TABLE purchasing.payments ADD CONSTRAINT purchase_payments_method_chk
  CHECK (method IN ('cash', 'wave', 'orange_money', 'free_money', 'mtn_momo', 'moov_money', 'airtel_money', 'card', 'transfer', 'cheque'));

ALTER TABLE invoicing.payments DROP CONSTRAINT IF EXISTS payments_method_chk;
ALTER TABLE invoicing.payments ADD CONSTRAINT payments_method_chk
  CHECK (method IN ('cash', 'wave', 'orange_money', 'free_money', 'mtn_momo', 'moov_money', 'airtel_money', 'card', 'transfer', 'cheque'));
