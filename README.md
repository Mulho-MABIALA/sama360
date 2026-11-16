# Sama360

Super app multiservice pour commerçants, prestataires et petites entreprises (Sénégal d'abord).
Un seul compte, plusieurs services : ventes, stock, facturation, boutique en ligne, paiements, documents.

Ce dépôt est un monorepo :

| Dossier | Contenu |
| --- | --- |
| `apps/api` | API NestJS + worker d'événements (TypeScript) |
| `apps/mobile` | App Flutter des commerçants (voir `apps/mobile/README.md`) |
| `packages/contracts` | Types partagés : événements de domaine, permissions, rôles |
| `infra` | docker-compose local (Redis, PostgreSQL optionnel) |

Le back-office React et les boutiques Next.js viendront dans `apps/`.

## Démarrage rapide

Prérequis : Node 22, pnpm 10, un projet [Neon](https://neon.tech) et Redis.

```bash
pnpm install
cp apps/api/.env.example apps/api/.env   # puis renseigner les URL Neon et les secrets
docker compose -f infra/docker-compose.yml up -d redis
pnpm db:migrate                          # crée les schémas core, contacts, catalog
pnpm dev                                 # API sur http://localhost:3000
pnpm worker                             # dans un 2e terminal : relais outbox + abonnés
```

En développement, le code OTP s'affiche dans les logs de l'API (`OTP_PROVIDER=console`).
Les photos envoyées sont rangées dans `apps/api/storage/` (ignoré par Git ; dossier réglable avec `STORAGE_DIR`).
En production sur un serveur sans disque persistant, brancher un stockage S3 / Cloudflare R2
(une seule classe à ajouter : `FileStorage` dans `src/modules/files/storage.ts`).

### Configurer Neon

1. Créer un projet Neon (région la plus proche : `aws-eu-central-1`).
2. `DATABASE_URL_DIRECT` = chaîne **directe** du propriétaire `neondb_owner`, utilisée **uniquement** par `pnpm db:migrate`.
3. Créer le **rôle applicatif** `sama_app` (le propriétaire Neon a `BYPASSRLS`, l'API ne doit donc pas l'utiliser) :
   ```sql
   CREATE ROLE sama_app WITH LOGIN NOSUPERUSER NOBYPASSRLS PASSWORD '<mot de passe fort>';
   ```
   puis lancer `pnpm db:migrate` : la migration `0003` lui accorde les droits de lecture/écriture.
4. `DATABASE_URL` = chaîne **pooled** (hôte en `-pooler`) avec l'utilisateur `sama_app`, utilisée par l'API.
5. Créer des branches Neon `dev` et `staging` pour ne jamais tester sur la production.

> **Important — RLS.** L'isolation des entreprises repose sur la Row Level Security de PostgreSQL.
> Un rôle `SUPERUSER` ou `BYPASSRLS` l'ignore. Vérifier avec :
> `SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user;` → les deux doivent être `false`.
> Les tests e2e refusent de tourner avec un tel rôle.

## Architecture du socle

- **Monolithe modulaire** : chaque module (`apps/api/src/modules/*`) possède ses tables et ses routes.
  Entre modules métier, on ne communique que par **événements**.
- **Multi-tenant** : chaque requête métier porte l'en-tête `X-Business-Id`. Le `TenantGuard` vérifie
  l'adhésion et les permissions ; `DbService.withTenant()` positionne `app.business_id` et les politiques
  RLS filtrent les lignes dans PostgreSQL.
- **Événements (pattern outbox)** : un événement est écrit dans `core.outbox_events` *dans la même
  transaction* que la donnée. Le worker le relaie vers BullMQ (Redis), puis exécute chaque abonné
  (`@OnDomainEvent`) une seule fois grâce à `core.processed_events`.
- **Identifiants** UUID v7 (triables, générables hors ligne par le mobile) ; **montants** en entiers FCFA.

## API (v1)

Toutes les erreurs : `{ "error": { "code", "message", "details?" } }`.

| Méthode | Route | Accès |
| --- | --- | --- |
| POST | `/v1/auth/otp/request` | public — `{ phone }` |
| POST | `/v1/auth/otp/verify` | public — `{ phone, code, deviceId? }` → jetons |
| POST | `/v1/auth/refresh` | public — rotation du jeton de rafraîchissement |
| POST | `/v1/auth/logout` | public |
| GET / PATCH | `/v1/me` | connecté — profil + entreprises |
| POST / DELETE | `/v1/business/logo` | `business:update` — logo de l'entreprise (factures, devis) |
| POST / DELETE | `/v1/me/avatar` | connecté — photo de profil (multipart, champ `file`) |
| POST | `/v1/me/logout-all` | connecté — déconnecte tous les appareils |
| POST | `/v1/businesses` | connecté — crée une entreprise (devient propriétaire) |
| GET / PATCH | `/v1/business` | `business:read` / `business:update` |
| GET | `/v1/roles` | connecté |
| GET / POST | `/v1/members` | `members:read` / `members:invite` |
| PATCH / DELETE | `/v1/members/:id` | `members:manage` — rôle, suspension, retrait |
| GET / POST | `/v1/contacts` | `contacts:read` / `contacts:write` — `creditLimit` (plafond de crédit) réservé à `sales:void` |
| GET / PATCH / DELETE | `/v1/contacts/:id` | idem ; suppression refusée (409) tant que le client doit de l'argent |
| GET | `/v1/customers` | `contacts:read` — annuaire avec soldes et achats (`?search=&filter=all\|debt\|over_limit&sort=name\|balance\|recent&limit=&offset=`) et totaux |
| GET | `/v1/customers/:id` | `contacts:read` — fiche client : solde, plafond et crédit disponible, plus ancienne dette impayée, statistiques, achats, top produits, relevé avec solde après chaque mouvement |
| POST | `/v1/customers/:id/adjustments` | `sales:void` — reprise d'ancienne dette (montant positif) ou remise de dette (négatif) |
| POST | `/v1/customers/:id/reminders` | `contacts:write` — note l'envoi d'un rappel de paiement |
| GET / POST | `/v1/catalog/categories` | `catalog:read` / `catalog:write` |
| GET | `/v1/catalog/products/by-code/:code` | `catalog:read` — produit par code-barres ou référence (scan) |
| PATCH / DELETE | `/v1/catalog/categories/:id` | `catalog:write` — renommer, supprimer (les produits restent, sans catégorie) |
| GET / POST | `/v1/catalog/products` | idem (`?search=&categoryId=&cursor=&limit=`) |
| GET / PATCH / DELETE | `/v1/catalog/products/:id` | idem |
| POST / DELETE | `/v1/catalog/products/:id/image` | `catalog:write` — photo (multipart, champ `file`, JPEG/PNG/WebP, 5 Mo max) |
| GET | `/v1/files/:id` | public — sert une photo (cache long, l'identifiant change à chaque nouvelle photo) |
| POST | `/v1/sales` | `sales:create` — encaisser (idempotent si `id` fourni par le mobile) ; vente à crédit refusée au-delà du plafond du client (422 `CREDIT_LIMIT_EXCEEDED`), sauf vente hors ligne (`soldAt`) |
| GET | `/v1/sales` · `/v1/sales/:id` | `sales:read` (`?from=&to=&customerId=&cashierId=&mine=true&status=`) |
| POST | `/v1/sales/:id/void` | `sales:void` — annule : stock remis, dette annulée |
| GET | `/v1/sales/summary` | `reports:read` — CA, coût, bénéfice, dépenses, encaissé, crédit, ventes par vendeur (`?from=&to=`) |
| GET | `/v1/reports/overview` | `reports:read` — rapport d'une période (`?from=&to=`, 400 jours max) : totaux, évolution vs période précédente, série jour/mois, moyens de paiement, top produits, vendeurs, dépenses, factures |
| GET | `/v1/sales/my-day` | `sales:create` — ma journée de vendeur (nombre, montant) |
| GET | `/v1/sales/debtors` | `sales:read` — clients qui doivent de l'argent |
| GET | `/s/:slug` · `/s/:slug/c/:id` | public — page web de la boutique (catalogue, panier, commande) et suivi de commande |
| GET | `/v1/public/shops/:slug` | public — vitrine : réglages, catégories, produits publiés et disponibilité (sans coût ni stock exact) |
| POST | `/v1/public/shops/:slug/orders` | public, 10/min — commande d'un client sans compte (idempotente sur `id`), prix calculés par le serveur, fiche client créée |
| GET | `/v1/public/shops/:slug/orders/:id` | public — suivi de la commande par le client |
| GET | `/v1/shop` | `sales:read` — adresse, réglages et chiffres de la boutique |
| PUT | `/v1/shop/settings` | `catalog:write` — ouverture, présentation, WhatsApp, retrait, livraison (frais, zone), minimum |
| POST | `/v1/shop/publish` | `catalog:write` — mettre en ligne ou retirer des produits (tous si `productIds` absent) |
| GET | `/v1/shop/orders` · `/v1/shop/orders/:id` | `sales:read` — commandes reçues (`?filter=new\|open\|done\|all`) |
| POST | `/v1/shop/orders/:id/status` | `sales:create` — confirmée → prête → en livraison → livrée (vente enregistrée avec le paiement reçu, reste au carnet) ou annulée |
| GET / POST | `/v1/purchases` | `inventory:read` / `inventory:write` — bons de commande BC-… (`?filter=open\|unpaid\|received\|all&supplierId=`), totaux ; création idempotente si `id` fourni, `draft`, achat direct `receive: true` + `payment` |
| GET / PATCH | `/v1/purchases/:id` | détail (lignes commandées / reçues, réceptions, paiements) ; modification tant que rien n'est reçu ni payé |
| POST | `/v1/purchases/:id/confirm` · `/cancel` | `inventory:write` — brouillon → commandé ; annulation si rien reçu ni payé |
| POST | `/v1/purchases/:id/receive` | `inventory:write` — réception (tout le reste par défaut, ou `lines` avec quantité et prix réel) : entrée en stock, coût moyen pondéré recalculé, paiement au livreur facultatif |
| POST | `/v1/purchases/:id/payments` | `inventory:write` — paiement fournisseur (avance possible jusqu'au montant commandé) |
| GET | `/v1/suppliers` · `/v1/suppliers/:id` | `inventory:read` — fournisseurs avec dette, achats, commandes en cours ; fiche avec commandes, paiements et produits achetés (dernier prix) |
| POST | `/v1/suppliers/:id/payments` | `inventory:write` — paiement global réparti sur les bons impayés, du plus ancien au plus récent |
| GET / POST | `/v1/invoicing/documents` | `invoicing:read` / `invoicing:write` — devis (DEV-…) et factures (FAC-…), idempotent si `id` fourni |
| GET / PATCH | `/v1/invoicing/documents/:id` | lecture ; modification d'un devis tant qu'il n'est pas facturé |
| POST | `/v1/invoicing/documents/:id/accept` · `/decline` · `/reopen` | `invoicing:write` — réponse du client à un devis |
| POST | `/v1/invoicing/documents/:id/convert` | `invoicing:write` — devis → facture (une seule fois) |
| POST | `/v1/invoicing/documents/:id/payments` | `invoicing:write` — paiement (idempotent, sans dépasser le reste dû) |
| POST | `/v1/invoicing/documents/:id/cancel` | `invoicing:write` — annule une facture sans paiement (retour en stock) |
| GET | `/v1/invoicing/summary` | `invoicing:read` — à encaisser, en retard, devis en cours, facturé ce mois |
| GET | `/v1/cash/current` | `sales:create` — ma caisse ouverte (`session: null` sinon) avec l'attendu par moyen de paiement, en direct |
| POST | `/v1/cash/open` | `sales:create` — ouvre la caisse (Z-AAAA-NNNN) avec un fond ; une seule caisse ouverte par vendeur |
| POST | `/v1/cash/current/movements` | `sales:create` — entrée ou sortie d'espèces (refusée au-delà des espèces attendues) |
| POST | `/v1/cash/current/close` | `sales:create` — clôture avec le comptage par moyen ; le rapport Z est figé |
| POST | `/v1/cash/sessions/:id/close` | `sales:void` — un gérant clôture la caisse d'un vendeur |
| GET | `/v1/cash/sessions` · `/v1/cash/sessions/:id` | `sales:create` — historique (le gérant voit toutes les caisses) et rapport Z |
| GET | `/v1/sales/customers/:id/ledger` | `sales:read` — carnet de crédit d'un client |
| POST | `/v1/sales/customers/:id/repayments` | `sales:create` — remboursement |
| GET / POST | `/v1/sales/expenses` | `reports:read` / `sales:create` |
| GET | `/v1/inventory/stock` | `inventory:read` (`?search=&lowOnly=true`) |
| POST | `/v1/inventory/movements` | `inventory:write` — entrée, retour, correction |
| POST | `/v1/inventory/counts` | `inventory:write` — inventaire physique |
| GET | `/v1/inventory/products/:id/movements` | `inventory:read` |
| GET | `/health` | public |

Rôles système : `owner` (tout), `manager`, `cashier`, `accountant` — voir `migrations/0001_core.sql`.

## Tests

```bash
pnpm test        # unitaires
pnpm test:e2e    # bout en bout : TEST_DATABASE_URL (base vide, rôle non superutilisateur) + REDIS_URL
```

La CI GitHub Actions lance build, typecheck, tests unitaires et e2e (PostgreSQL 16 + Redis).

## Prochaines étapes

1. ~~Module **sales** + **inventory**~~ ✔ (caisse, carnet de crédit, dépenses, résumé, stock).
2. Synchronisation hors ligne (`/v1/sync/push`, `/v1/sync/pull`).
3. **invoicing** + génération PDF, puis **payments** (agrégateur Wave / Orange Money).
4. Fournisseur OTP réel (SMS / WhatsApp Business).
5. ~~App Flutter branchée sur cette API~~ ✔ (connexion, accueil, caisse, stock, crédits).
