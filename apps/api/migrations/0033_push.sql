-- =====================================================================
-- Sama360 — 0033 : notifications push (Firebase Cloud Messaging)
-- Chaque téléphone ou navigateur enregistre son jeton. Les notifications
-- importantes (commande en ligne, Pro, stock bas, crédits…) passent par une
-- file, remplie dans la même transaction : rien ne part si l'action est annulée.
-- =====================================================================
CREATE TABLE IF NOT EXISTS core.push_tokens (
  token         varchar(512) PRIMARY KEY,
  user_id       uuid NOT NULL REFERENCES core.users(id) ON DELETE CASCADE,
  platform      varchar(10) NOT NULL CHECK (platform IN ('android', 'ios', 'web')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  last_seen_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS push_tokens_user_idx ON core.push_tokens (user_id);

CREATE TABLE IF NOT EXISTS core.push_queue (
  notification_id uuid PRIMARY KEY,
  business_id     uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  created_at      timestamptz NOT NULL DEFAULT now(),
  attempts        int NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS push_queue_created_idx ON core.push_queue (created_at);
