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
| POST | `/v1/businesses` | connecté — crée une entreprise (devient propriétaire) |
| GET / PATCH | `/v1/business` | `business:read` / `business:update` |
| GET | `/v1/roles` | connecté |
| GET / POST | `/v1/members` | `members:read` / `members:invite` |
| PATCH | `/v1/members/:id` | `members:manage` |
| GET / POST | `/v1/contacts` | `contacts:read` / `contacts:write` |
| GET / PATCH / DELETE | `/v1/contacts/:id` | idem |
| GET / POST | `/v1/catalog/categories` | `catalog:read` / `catalog:write` |
| GET / POST | `/v1/catalog/products` | idem (`?search=&categoryId=&cursor=&limit=`) |
| GET / PATCH / DELETE | `/v1/catalog/products/:id` | idem |
| POST | `/v1/sales` | `sales:create` — encaisser (idempotent si `id` fourni par le mobile) |
| GET | `/v1/sales` · `/v1/sales/:id` | `sales:read` (`?from=&to=&customerId=&status=`) |
| POST | `/v1/sales/:id/void` | `sales:void` — annule : stock remis, dette annulée |
| GET | `/v1/sales/summary` | `reports:read` — CA, coût, bénéfice, dépenses, encaissé, crédit (`?from=&to=`) |
| GET | `/v1/sales/debtors` | `sales:read` — clients qui doivent de l'argent |
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
