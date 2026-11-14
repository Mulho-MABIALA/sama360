-- =====================================================================
-- Sama360 — 0003 : droits du rôle applicatif
-- Sur Neon, le propriétaire (neondb_owner) a BYPASSRLS : l'API doit donc se
-- connecter avec un rôle dédié « sama_app » (NOBYPASSRLS), qui n'a que les droits
-- de lecture/écriture et reste soumis à la Row Level Security.
-- Le rôle est créé hors migration (il porte un mot de passe) ; s'il n'existe pas
-- (tests locaux, CI), cette migration ne fait rien.
-- =====================================================================

DO $$
DECLARE s text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sama_app') THEN
    RAISE NOTICE 'Rôle sama_app absent : droits non accordés';
    RETURN;
  END IF;
  -- Si sama_app est lui-même le propriétaire (base locale de test), rien à faire.
  IF current_user = 'sama_app' THEN
    RETURN;
  END IF;

  FOREACH s IN ARRAY ARRAY['core', 'contacts', 'catalog'] LOOP
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO sama_app', s);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA %I TO sama_app', s);
    EXECUTE format('GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA %I TO sama_app', s);
    EXECUTE format('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA %I TO sama_app', s);
    -- Tables créées plus tard dans ces schémas par le même propriétaire
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO sama_app', s);
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT USAGE, SELECT ON SEQUENCES TO sama_app', s);
    EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT EXECUTE ON FUNCTIONS TO sama_app', s);
  END LOOP;
  -- Lecture seule sur le suivi des migrations (diagnostic)
  GRANT SELECT ON public.schema_migrations TO sama_app;
END $$;
