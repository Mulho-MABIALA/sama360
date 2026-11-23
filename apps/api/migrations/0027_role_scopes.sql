-- =====================================================================
-- Sama360 — 0027 : droits plus précis par rôle
-- Les achats fournisseurs (prix d'achat, dettes fournisseurs) ne font plus partie
-- de « voir le stock » : nouveau droit purchasing:*, donné au gérant (tout) et au
-- comptable (lecture). Le vendeur / caissier n'y a plus accès.
-- =====================================================================
UPDATE core.roles SET permissions = permissions || '["purchasing:*"]'::jsonb
  WHERE business_id IS NULL AND key = 'manager' AND NOT permissions @> '["purchasing:*"]'::jsonb;
UPDATE core.roles SET permissions = permissions || '["purchasing:read"]'::jsonb
  WHERE business_id IS NULL AND key = 'accountant' AND NOT permissions @> '["purchasing:read"]'::jsonb;
