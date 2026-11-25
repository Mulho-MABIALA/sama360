-- Suggestions des commerçants (profil → « Suggestions »), lues par l'équipe Sama360 dans le back office
CREATE TABLE core.feedback (
  id           uuid PRIMARY KEY,
  user_id      uuid NOT NULL REFERENCES core.users(id) ON DELETE CASCADE,
  business_id  uuid REFERENCES core.businesses(id) ON DELETE SET NULL,
  kind         varchar(10) NOT NULL CHECK (kind IN ('idea', 'problem', 'other')),
  message      text NOT NULL CHECK (length(message) BETWEEN 3 AND 2000),
  status       varchar(10) NOT NULL DEFAULT 'new' CHECK (status IN ('new', 'read', 'done')),
  app_version  varchar(30),
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX feedback_status_idx ON core.feedback (status, created_at DESC);
