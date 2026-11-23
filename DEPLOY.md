# Mettre Sama360 en ligne

Ce guide met Sama360 en ligne pour que l'app fonctionne partout, pas seulement sur le Wi-Fi du PC :
l'API et la version web de l'app (`https://<adresse>/app`, utilisable sur iPhone comme sur Android).
Compter environ une heure la première fois. **Aucun mot de passe ni clé ne va dans GitHub** : ils se collent
uniquement dans Render (ou dans le `.env` du serveur).

| Brique | Service | Coût de départ |
|---|---|---|
| API + traitement des événements + version web | Render, service web Docker (`render.yaml`) | offre gratuite pour tester (réglée dans `render.yaml`) ; « Starter » (7 $/mois) pour de vrais clients |
| File d'événements (Redis) | Render Key Value | gratuit |
| Base de données | Neon (déjà en place) | gratuit au départ |
| Fichiers (logos, photos) | Cloudflare R2 | gratuit jusqu'à 10 Go |
| SMS de connexion | Orange SMS API (Sénégal) | forfaits SMS payés en crédit Orange ou Orange Money |
| Assistant IA, facture en photo (facultatif) | API Anthropic (console.anthropic.com) | paiement à l'usage |

Vérifier les prix du moment sur les sites de chaque service.

---

## Étape 0 : pousser le code sur GitHub

```bash
cd C:\sama360
git push
```

Render déploie depuis GitHub : chaque `git push` sur `main` redéploie l'API automatiquement,
migrations comprises.

## Étape 1 : SMS Orange

1. Créer un compte sur **developer.orange.com**, puis **My Apps → Add an app** (nom : Sama360).
2. Dans l'app, **Add API → SMS Senegal**.
3. Acheter un forfait SMS (page *Pricing* de l'API), payé en crédit Orange ou Orange Money.
4. Onglet **Credentials** : noter le **Client ID** et le **Client Secret**.
5. Numéro expéditeur : celui indiqué par Orange pour le Sénégal (souvent `+2210000`).
   Un nom d'expéditeur (« Sama360 ») peut être demandé à Orange ; une fois accepté, le mettre dans
   `ORANGE_SMS_SENDER_NAME`.

Valeurs à garder pour l'étape 3 : `ORANGE_SMS_CLIENT_ID`, `ORANGE_SMS_CLIENT_SECRET`, `ORANGE_SMS_SENDER`.

> Twilio reste possible (`OTP_PROVIDER=twilio`, `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_FROM`).
> Pour Orange et Expresso au Sénégal, Twilio exige un nom d'expéditeur enregistré.

## Étape 2 : stockage des fichiers (Cloudflare R2)

Le disque d'un service Render est effacé à chaque déploiement : les logos et photos doivent vivre ailleurs.

1. Compte **Cloudflare** → **R2** → **Create bucket** : `sama360-fichiers` (privé, pas d'accès public).
2. **R2 → Manage API tokens → Create API token** : permission *Object Read & Write*, limité à ce seau.
3. Noter l'**Access Key ID**, le **Secret Access Key** et l'**endpoint**
   (`https://<id-du-compte>.r2.cloudflarestorage.com`).

Valeurs : `S3_BUCKET=sama360-fichiers`, `S3_ENDPOINT`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`.

## Étape 3 : Render

1. Compte **render.com**, connecté au GitHub qui contient `sama360`.
2. **New → Blueprint** → choisir le dépôt `sama360`. Render lit `render.yaml` et prépare :
   - `sama360-api` : l'API (avec le worker intégré), région Ohio comme la base Neon ;
   - `sama360-redis` : la file d'événements.
3. Render demande les valeurs marquées `sync: false`. Les coller :
   - `DATABASE_URL` et `DATABASE_URL_DIRECT` : **les mêmes que dans `apps/api/.env` sur le PC**
     (`sama_app` pour l'API, `neondb_owner` pour les migrations) ;
   - les trois valeurs Orange de l'étape 1 ;
   - les quatre valeurs R2 de l'étape 2 ;
   - `ADMIN_PHONES` : ton numéro au format international (ex. `+221781234567`), pour valider les
     paiements Sama360 Pro dans l'app ; plusieurs numéros séparés par des virgules ;
   - `PRO_PAY_TO_SN`, `PRO_PAY_TO_CI`, `PRO_PAY_TO_CG` : le numéro Wave / Orange Money / MTN qui reçoit
     les abonnements dans chaque pays (laisser vide un pays pas encore ouvert) ;
   - `ANTHROPIC_API_KEY` : facultatif. Pour activer l'assistant et la facture en photo, coller la clé
     puis passer `ASSISTANT_PROVIDER` à `anthropic` (onglet **Environment** du service).
   Un champ laissé vide est simplement ignoré.
   Les secrets `JWT_ACCESS_SECRET`, `JWT_REFRESH_SECRET` et `OTP_SECRET` sont générés par Render.
4. **Apply**. La première construction prend 10 à 15 minutes (elle construit aussi la version web de l'app
   avec Flutter) ; les suivantes réutilisent le cache. Au démarrage, l'API applique les migrations.
5. Vérifier : ouvrir `https://sama360-api.onrender.com/health` (l'adresse exacte est en haut de la page
   du service). Réponse attendue : `{"status":"ok","db":"ok"}`.

`render.yaml` démarre sur l'offre **gratuite** : le service s'endort après 15 minutes sans visite et met
environ une minute à se réveiller ; les tâches de fond (relances, rappels de fin d'essai) attendent le réveil.
Avant les vrais commerçants : Render → sama360-api → **Settings → Instance Type → Starter** (ou `plan: starter`
dans `render.yaml`).

Si l'adresse donnée par Render n'est pas `https://sama360-api.onrender.com` (nom déjà pris), la mettre
dans `apps/mobile/lib/core/config.dart` (`productionApiUrl`).

## Étape 4 : tester la connexion

Sur n'importe quel téléphone, ouvrir **`https://sama360-api.onrender.com/app`** (adresse exacte : page du
service). Sur iPhone : Safari → Partager → **Sur l'écran d'accueil** pour l'avoir comme une app.
Se connecter avec son numéro : le code doit arriver **par SMS**.

En cas d'échec, l'app affiche « Le SMS n'a pas pu être envoyé » et on peut redemander tout de suite.
Le détail est dans **Render → sama360-api → Logs** (par exemple « Not enough credit » : forfait épuisé).

## Étape 5 : l'app Android

Version de production (API en ligne, HTTPS obligatoire, sans le réglage « Serveur » des tests) :

```bash
cd apps/mobile
set SAMA_STORE=true
flutter build apk --release --split-per-abi --dart-define=STORE=true
```

(PowerShell : `$env:SAMA_STORE="true"` au lieu de `set`.) Une version publiée utilise automatiquement l'API en
ligne. Pour une autre adresse : `--dart-define=API_URL=https://...`.

Pour Google Play, il faudra en plus une clé de signature à soi (pas la clé de débogage) : étape à faire au
moment de la publication.

---

## Mises à jour

`git push` sur `main` → Render reconstruit et redéploie ; les nouvelles migrations s'appliquent au démarrage
(une migration en échec bloque le déploiement : l'ancienne version reste en ligne).

## Quand l'activité grandit

- **Séparer le worker** : passer `RUN_WORKER` à `false` sur l'API et ajouter un service
  `type: worker` avec la même image et `dockerCommand: node dist/worker.js`.
- **Nom de domaine** : Render → Settings → Custom Domains (ex. `api.sama360.sn`), puis mettre cette adresse
  dans `productionApiUrl`.

## Variante : serveur à soi (VPS)

Pour un VPS (Hetzner, Contabo, OVH…) avec Docker :

```bash
git clone <dépôt> sama360 && cd sama360/infra/vps
cp .env.example .env    # remplir : domaine, Neon, secrets, Orange
docker compose up -d --build
```

Faire pointer le domaine (`API_DOMAIN`) vers l'IP du serveur : Caddy obtient le certificat HTTPS seul.
Les fichiers restent sur le disque du serveur (volume `files`) ; penser à le sauvegarder, ou utiliser R2.

## Sécurité

- Les secrets ne vivent que dans Render (ou le `.env` du serveur), jamais dans GitHub ni dans l'app.
- En cas de fuite d'une clé : la régénérer chez le fournisseur (Neon, Orange, Cloudflare) puis la remplacer
  dans Render. Changer `JWT_*_SECRET` déconnecte tout le monde ; changer `OTP_SECRET` invalide les codes en cours.
- L'API refuse de démarrer en production si les SMS ne sont pas configurés
  (sauf `OTP_CONSOLE_IN_PRODUCTION=true`, réservé à un test).
- Derrière Render, `TRUST_PROXY=1` permet de limiter les requêtes par client et non pour tout le monde à la fois.
