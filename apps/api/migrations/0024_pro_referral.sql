-- Sama360 Pro (abonnement) et parrainage entre commerçants.

-- Essai : les entreprises existantes reçoivent 30 jours de Pro pour ne rien perdre d'un coup.
UPDATE core.subscriptions
   SET plan = 'pro', status = 'trialing', current_period_end = now() + interval '30 days'
 WHERE plan = 'free';

-- Demandes de paiement (Wave, Orange Money, MoMo…) validées à la main par l'équipe Sama360.
CREATE TABLE IF NOT EXISTS core.subscription_requests (
  id            uuid PRIMARY KEY,
  business_id   uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  cycle         varchar(10) NOT NULL CHECK (cycle IN ('monthly', 'yearly')),
  amount        integer NOT NULL CHECK (amount > 0),
  currency      char(3) NOT NULL,
  method        varchar(15) NOT NULL,
  reference     varchar(60) NOT NULL,
  payer_phone   varchar(20),
  status        varchar(10) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected')),
  note          text,
  created_by    uuid REFERENCES core.users(id),
  decided_by    uuid REFERENCES core.users(id),
  decided_at    timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS subscription_requests_business_idx ON core.subscription_requests (business_id, created_at DESC);
CREATE INDEX IF NOT EXISTS subscription_requests_pending_idx ON core.subscription_requests (created_at) WHERE status = 'pending';
-- Une seule demande en attente par entreprise
CREATE UNIQUE INDEX IF NOT EXISTS subscription_requests_one_pending ON core.subscription_requests (business_id) WHERE status = 'pending';

-- Parrainage : code par entreprise, parrain éventuel
ALTER TABLE core.businesses ADD COLUMN IF NOT EXISTS referral_code varchar(12);
ALTER TABLE core.businesses ADD COLUMN IF NOT EXISTS referred_by uuid REFERENCES core.businesses(id) ON DELETE SET NULL;
UPDATE core.businesses
   SET referral_code = rpad(left(upper(regexp_replace(translate(name,
         'àâäáãçéèêëíìîïñóòôöõúùûüÀÂÄÁÃÇÉÈÊËÍÌÎÏÑÓÒÔÖÕÚÙÛÜ',
         'aaaaaceeeeiiiinooooouuuuAAAAACEEEEIIIINOOOOOUUUU'), '[^A-Za-z]', '', 'g')), 3), 3, 'X')
       || upper(substr(md5(id::text), 1, 3))
 WHERE referral_code IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS businesses_referral_code_key ON core.businesses (referral_code);

-- Récompenses déjà données (une seule par filleul)
CREATE TABLE IF NOT EXISTS core.referral_rewards (
  referee_id   uuid PRIMARY KEY REFERENCES core.businesses(id) ON DELETE CASCADE,
  referrer_id  uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  days         integer NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS referral_rewards_referrer_idx ON core.referral_rewards (referrer_id);
