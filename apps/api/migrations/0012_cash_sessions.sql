-- =====================================================================
-- Sama360 — 0012 : clôture de caisse
-- Chaque vendeur ouvre sa caisse (fond de caisse), puis la clôture en
-- comptant ce qu'il a réellement. L'attendu est calculé par moyen de
-- paiement à partir des ventes, remboursements, paiements de factures,
-- dépenses, paiements fournisseurs et mouvements de caisse de la session.
-- =====================================================================

CREATE TABLE sales.cash_sessions (
  id             uuid PRIMARY KEY,
  business_id    uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  number         varchar(30) NOT NULL,
  user_id        uuid NOT NULL REFERENCES core.users(id),
  status         varchar(10) NOT NULL DEFAULT 'open',   -- open, closed
  opening_float  bigint NOT NULL DEFAULT 0 CHECK (opening_float >= 0),
  opened_at      timestamptz NOT NULL DEFAULT now(),
  opening_note   text,
  closed_at      timestamptz,
  closed_by      uuid REFERENCES core.users(id),
  expected       jsonb,                                  -- { cash: 12500, wave: 3000, … } à la clôture
  counted        jsonb,                                  -- ce que le vendeur a compté
  difference     bigint,                                 -- total compté − total attendu
  summary        jsonb,                                  -- chiffres du rapport Z figés à la clôture
  closing_note   text,
  UNIQUE (business_id, number),
  CONSTRAINT cash_sessions_status_chk CHECK (status IN ('open', 'closed'))
);
-- Une seule caisse ouverte par vendeur
CREATE UNIQUE INDEX cash_sessions_open_uq ON sales.cash_sessions (business_id, user_id) WHERE status = 'open';
CREATE INDEX cash_sessions_business_idx ON sales.cash_sessions (business_id, opened_at DESC);

CREATE TABLE sales.cash_movements (
  id           uuid PRIMARY KEY,
  business_id  uuid NOT NULL REFERENCES core.businesses(id) ON DELETE CASCADE,
  session_id   uuid NOT NULL REFERENCES sales.cash_sessions(id) ON DELETE CASCADE,
  direction    varchar(3) NOT NULL,                      -- in, out
  amount       bigint NOT NULL CHECK (amount > 0),
  reason       varchar(200) NOT NULL,
  created_by   uuid NOT NULL REFERENCES core.users(id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT cash_movements_direction_chk CHECK (direction IN ('in', 'out'))
);
CREATE INDEX cash_movements_session_idx ON sales.cash_movements (session_id, created_at);

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['sales.cash_sessions', 'sales.cash_movements'] LOOP
    EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %s FORCE ROW LEVEL SECURITY', t);
    EXECUTE format(
      'CREATE POLICY tenant_isolation ON %s USING (business_id = core.current_business_id()) WITH CHECK (business_id = core.current_business_id())',
      t
    );
  END LOOP;

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sama_app') AND current_user <> 'sama_app' THEN
    GRANT SELECT, INSERT, UPDATE, DELETE ON sales.cash_sessions, sales.cash_movements TO sama_app;
  END IF;
END $$;
