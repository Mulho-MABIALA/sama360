-- Pro à la semaine (1 500 F) en plus du mois et de l'année
ALTER TABLE core.subscription_requests DROP CONSTRAINT IF EXISTS subscription_requests_cycle_check;
ALTER TABLE core.subscription_requests
  ADD CONSTRAINT subscription_requests_cycle_check CHECK (cycle IN ('weekly', 'monthly', 'yearly'));
ALTER TABLE core.online_payments DROP CONSTRAINT IF EXISTS online_payments_cycle_check;
ALTER TABLE core.online_payments
  ADD CONSTRAINT online_payments_cycle_check CHECK (cycle IN ('weekly', 'monthly', 'yearly'));
