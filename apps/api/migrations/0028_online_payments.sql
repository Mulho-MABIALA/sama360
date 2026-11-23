-- =====================================================================
-- Sama360 — 0028 : paiement en ligne de l'abonnement Pro (Chariow)
-- Le commerçant paie sur la page Chariow (Wave, Orange Money, MoMo, carte…).
-- Chariow prévient le serveur (Pulse signé « successful.sale ») : Pro activé sans
-- validation à la main. Le paiement manuel (subscription_requests) reste possible.
-- =====================================================================
CREATE TABLE IF NOT EXISTS core.online_payments (
  id            uuid PRIMARY KEY,
  business_id   uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  provider      varchar(20) NOT NULL DEFAULT 'chariow',
  cycle         varchar(10) NOT NULL CHECK (cycle IN ('monthly', 'yearly')),
  product_id    varchar(60) NOT NULL,           -- produit Chariow payé (mensuel ou annuel)
  sale_id       varchar(60),                    -- vente Chariow (sal_…)
  checkout_url  text,
  status        varchar(10) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'paid', 'failed')),
  amount        integer,                        -- montant payé, tel que Chariow l'annonce
  currency      char(3),
  created_by    uuid REFERENCES core.users(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  paid_at       timestamptz
);
CREATE INDEX IF NOT EXISTS online_payments_business_idx ON core.online_payments (business_id, created_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS online_payments_sale_key ON core.online_payments (provider, sale_id) WHERE sale_id IS NOT NULL;

-- Pulses déjà traités (Chariow peut renvoyer le même événement)
CREATE TABLE IF NOT EXISTS core.payment_events (
  provider      varchar(20) NOT NULL,
  delivery_id   varchar(120) NOT NULL,
  event         varchar(60) NOT NULL,
  received_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (provider, delivery_id)
);
