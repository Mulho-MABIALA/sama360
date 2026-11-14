-- =====================================================================
-- Sama360 — 0001 : socle (identités, entreprises, rôles, outbox)
-- Conventions : ids UUID v7 générés par l'application, montants en bigint
-- (unités monétaires, le FCFA n'a pas de centimes), horodatage timestamptz.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS core;

-- Entreprise courante de la transaction, positionnée par l'API :
--   SET LOCAL app.business_id = '<uuid>'
CREATE OR REPLACE FUNCTION core.current_business_id() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('app.business_id', true), '')::uuid
$$;

-- ---------- Identités ----------

CREATE TABLE core.users (
  id          uuid PRIMARY KEY,
  phone       varchar(20) NOT NULL UNIQUE,          -- E.164, ex. +221771234567
  full_name   varchar(120),                          -- complété après la 1re connexion
  email       varchar(160),
  pin_hash    varchar(255),
  locale      varchar(5)  NOT NULL DEFAULT 'fr',
  status      varchar(20) NOT NULL DEFAULT 'active', -- active, invited, suspended
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE core.otp_codes (
  id           uuid PRIMARY KEY,
  phone        varchar(20) NOT NULL,
  code_hash    varchar(128) NOT NULL,
  attempts     int NOT NULL DEFAULT 0,
  expires_at   timestamptz NOT NULL,
  consumed_at  timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX otp_codes_phone_idx ON core.otp_codes (phone, created_at DESC);

CREATE TABLE core.refresh_tokens (
  id           uuid PRIMARY KEY,
  user_id      uuid NOT NULL REFERENCES core.users(id) ON DELETE CASCADE,
  token_hash   varchar(128) NOT NULL UNIQUE,
  device_id    varchar(120),
  expires_at   timestamptz NOT NULL,
  revoked_at   timestamptz,
  replaced_by  uuid,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX refresh_tokens_user_idx ON core.refresh_tokens (user_id);

-- ---------- Entreprises (tenants) ----------

CREATE TABLE core.businesses (
  id            uuid PRIMARY KEY,
  owner_id      uuid NOT NULL REFERENCES core.users(id),
  name          varchar(120) NOT NULL,
  slug          varchar(80)  NOT NULL UNIQUE,           -- sama360.com/{slug}
  category      varchar(60),
  ninea         varchar(30),
  phone         varchar(20),
  address       text,
  city          varchar(80),
  country       char(2) NOT NULL DEFAULT 'SN',
  currency      char(3) NOT NULL DEFAULT 'XOF',
  vat_rate      numeric(5,2) NOT NULL DEFAULT 18.00,
  logo_file_id  uuid,
  settings      jsonb NOT NULL DEFAULT '{}',
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  deleted_at    timestamptz
);

CREATE TABLE core.roles (
  id           uuid PRIMARY KEY,
  business_id  uuid REFERENCES core.businesses(id) ON DELETE CASCADE, -- NULL = rôle système
  key          varchar(40) NOT NULL,
  name         varchar(80) NOT NULL,
  permissions  jsonb NOT NULL DEFAULT '[]'
);
CREATE UNIQUE INDEX roles_system_key_uq ON core.roles (key) WHERE business_id IS NULL;
CREATE UNIQUE INDEX roles_business_key_uq ON core.roles (business_id, key) WHERE business_id IS NOT NULL;

CREATE TABLE core.memberships (
  id           uuid PRIMARY KEY,
  business_id  uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  user_id      uuid NOT NULL REFERENCES core.users(id) ON DELETE CASCADE,
  role_id      uuid NOT NULL REFERENCES core.roles(id),
  status       varchar(20) NOT NULL DEFAULT 'active', -- invited, active, suspended
  invited_by   uuid REFERENCES core.users(id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (business_id, user_id)
);
CREATE INDEX memberships_user_idx ON core.memberships (user_id);

CREATE TABLE core.subscriptions (
  id                  uuid PRIMARY KEY,
  business_id         uuid NOT NULL UNIQUE REFERENCES core.businesses(id) ON DELETE CASCADE,
  plan                varchar(20) NOT NULL DEFAULT 'free',   -- free, essential, pro, enterprise
  status              varchar(20) NOT NULL DEFAULT 'active', -- active, past_due, cancelled
  billing_cycle       varchar(10) NOT NULL DEFAULT 'monthly',
  current_period_end  timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE core.module_activations (
  business_id   uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  module        varchar(40) NOT NULL,
  enabled       boolean NOT NULL DEFAULT true,
  settings      jsonb NOT NULL DEFAULT '{}',
  activated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (business_id, module)
);

CREATE TABLE core.audit_logs (
  id           uuid PRIMARY KEY,
  business_id  uuid,
  actor_id     uuid,
  action       varchar(60) NOT NULL,
  entity_type  varchar(40),
  entity_id    uuid,
  data         jsonb NOT NULL DEFAULT '{}',
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX audit_logs_business_idx ON core.audit_logs (business_id, created_at DESC);

-- ---------- Bus d'événements (pattern outbox) ----------

CREATE TABLE core.outbox_events (
  id            uuid PRIMARY KEY,
  business_id   uuid NOT NULL,
  type          varchar(60) NOT NULL,
  version       int NOT NULL DEFAULT 1,
  aggregate_id  uuid NOT NULL,
  actor_id      uuid,
  payload       jsonb NOT NULL,
  status        varchar(10) NOT NULL DEFAULT 'pending', -- pending, published, failed
  attempts      int NOT NULL DEFAULT 0,
  last_error    text,
  occurred_at   timestamptz NOT NULL DEFAULT now(),
  published_at  timestamptz
);
CREATE INDEX outbox_pending_idx ON core.outbox_events (occurred_at) WHERE status = 'pending';

-- Idempotence des abonnés : un couple (événement, handler) n'est traité qu'une fois.
CREATE TABLE core.processed_events (
  event_id      uuid NOT NULL,
  handler       varchar(120) NOT NULL,
  processed_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (event_id, handler)
);

-- ---------- Rôles système ----------

INSERT INTO core.roles (id, business_id, key, name, permissions) VALUES
  ('01930000-0000-7000-8000-000000000001', NULL, 'owner',      'Propriétaire', '["*"]'),
  ('01930000-0000-7000-8000-000000000002', NULL, 'manager',    'Gérant',
     '["business:read","members:read","members:invite","contacts:*","catalog:*","sales:*","inventory:*","invoicing:*","payments:read","reports:read"]'),
  ('01930000-0000-7000-8000-000000000003', NULL, 'cashier',    'Vendeur / caissier',
     '["business:read","contacts:read","contacts:write","catalog:read","sales:read","sales:create","inventory:read","invoicing:read","payments:collect"]'),
  ('01930000-0000-7000-8000-000000000004', NULL, 'accountant', 'Comptable',
     '["business:read","contacts:read","catalog:read","sales:read","inventory:read","invoicing:*","payments:read","reports:read"]');
