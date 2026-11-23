-- =====================================================================
-- Sama360 — 0029 : numéro de la boutique par défaut
-- Le numéro affiché sur les reçus et factures reprend celui du propriétaire
-- (son numéro de connexion) tant qu'il n'en a pas saisi un autre.
-- =====================================================================
UPDATE core.businesses b
   SET phone = u.phone
  FROM core.users u
 WHERE u.id = b.owner_id
   AND coalesce(b.phone, '') = '';
