# Publier Sama360 sur le Play Store

Tout ce qu'il faut, dans l'ordre : la clé de signature, le fichier à envoyer, la fiche
et les questionnaires de la Play Console. Les visuels (icône, bannière, captures) sont
prêts dans `apps/mobile/store/playstore/` (refaits avec
`apps/mobile/test/store_screenshots_test.dart`).

---

## 1. La clé de signature (une seule fois, sur le PC)

La clé « upload » signe chaque version envoyée à Google. **Si elle est perdue, on ne peut
plus mettre l'app à jour** (sauf démarche auprès de Google) : la garder en lieu sûr,
avec ses mots de passe, hors du dépôt git (sauvegarde sur clé USB et dans un coffre de mots de passe).

Dans PowerShell (le `keytool` d'Android Studio) :

```powershell
& "C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe" -genkeypair -v `
  -keystore "$env:USERPROFILE\sama360-upload.jks" -storetype JKS `
  -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

Il demande un mot de passe (deux fois), puis nom, organisation (Zolaa Tech), ville, pays (SN).

Créer ensuite `apps/mobile/android/key.properties` (déjà ignoré par git) :

```properties
storePassword=LE_MOT_DE_PASSE
keyPassword=LE_MOT_DE_PASSE
keyAlias=upload
storeFile=C:/Users/HP/sama360-upload.jks
```

(barres obliques `/` dans le chemin, même sous Windows).

## 2. Construire le fichier à envoyer (.aab)

À chaque nouvelle version, augmenter d'abord la version dans `apps/mobile/pubspec.yaml` :
`version: 1.0.0+1` → `1.0.1+2` (le nombre après `+` doit toujours augmenter).

```powershell
cd C:\sama360\apps\mobile
$env:SAMA_STORE = "true"     # version Play Store : HTTPS seulement
flutter build appbundle --release
```

Le fichier : `apps/mobile/build/app/outputs/bundle/release/app-release.aab`.
Pour les notifications push, `apps/mobile/android/app/google-services.json` doit être présent
(téléchargé depuis Firebase, jamais dans git).

## 3. Créer l'app dans la Play Console

play.google.com/console → **Créer une application** :

| Champ | Valeur |
|---|---|
| Nom | Sama360 |
| Langue par défaut | Français (France) – fr-FR |
| Application ou jeu | Application |
| Gratuite ou payante | Gratuite (l'abonnement Pro se paie hors de l'app, sur le web) |

Activer **la signature des applications par Google Play** (proposée par défaut) : Google garde
la clé de diffusion, nous gardons seulement la clé upload.

## 4. Fiche du Play Store

**Nom** (30 caractères max) :
> Sama360 : caisse et boutique

**Description courte** (80 caractères max) :
> Caisse, stock, crédits clients et boutique en ligne pour les commerçants.

**Description complète** :

> Sama360, c'est votre boutique dans la poche : vendez, suivez votre stock et vos crédits,
> et vendez en ligne, depuis votre téléphone.
>
> 💰 UNE CAISSE RAPIDE
> • Encaissez en quelques secondes : espèces, Wave, Orange Money, MTN MoMo, Moov, crédit.
> • Scannez les codes-barres avec l'appareil photo.
> • Montrez votre QR Wave au client avec le montant.
> • Vendez même sans internet : la vente part toute seule au retour du réseau.
> • Reçus envoyés par WhatsApp ou en PDF.
>
> 📦 UN STOCK TOUJOURS À JOUR
> • Le stock baisse à chaque vente, alerte avant la rupture.
> • Tailles et couleurs (habits, chaussures), vente au mètre, au kilo, au carton.
> • Commandes aux fournisseurs, réception de la marchandise, prix d'achat moyen.
> • Plusieurs points de vente, transferts entre boutiques.
>
> 📒 LES CRÉDITS SOUS CONTRÔLE
> • Qui vous doit combien, depuis quand.
> • Crédit maximum par client, rappels par WhatsApp ou SMS.
> • Programme de fidélité : points et récompenses.
>
> 🛍️ VOTRE BOUTIQUE EN LIGNE
> • Une page à votre nom, avec photo de couverture, à partager sur WhatsApp, Facebook, TikTok.
> • Vos clients commandent sans compte ; livraison ou retrait.
> • Statuts WhatsApp prêts à publier, avec le lien vers le produit.
>
> 📊 VOS CHIFFRES, CLAIRS
> • Vendu, gagné, ce qu'on vous doit, jour par jour.
> • Dépenses, fin de journée de caisse, produits qui dorment.
>
> 🧑‍🍳 POUR CHAQUE MÉTIER
> • Restaurant : suppléments et options.
> • Alimentation : dates de péremption.
> • Téléphonie : IMEI et garantie sur le reçu.
> • Salon et prestataires : rendez-vous en ligne.
>
> 👥 EN ÉQUIPE
> • Invitez vos vendeurs avec leur rôle : chacun voit ce qu'il doit voir.
> • Code PIN et empreinte pour les actions sensibles.
>
> Gratuit pour commencer. Sama360 Pro débloque la boutique en ligne, les vendeurs,
> les livraisons et l'assistant.
> Pour le Sénégal, la Côte d'Ivoire et le Congo.

**Catégorie** : Entreprise · **Tags** : point de vente, gestion de stock, facturation.

**Coordonnées** : e-mail `imulhomabiala@gmail.com` (ou l'adresse pro), site
`https://sama360-api.onrender.com`.

**Règles de confidentialité** : `https://sama360-api.onrender.com/confidentialite`

**Visuels** :

| Élément | Fichier |
|---|---|
| Icône 512 × 512 | `icone-512.png` |
| Bannière 1024 × 500 | `banniere-1024x500.png` |
| Captures téléphone (8) | `capture-1.png` … `capture-8.png` (1080 × 1920) |

## 5. Questionnaires de la Play Console

### Accès à l'application (validation par Google)
Toutes les fonctions demandent une connexion par code SMS. Donner le **compte de démonstration** :
dans Render, renseigner `REVIEW_PHONE` (ex. `+221700000777`, un numéro qui n'est à personne)
et `REVIEW_CODE` (6 chiffres). Ce numéro reçoit toujours ce code, sans SMS.
Dans la console : « Toutes ou certaines fonctionnalités sont limitées » →
identifiant = le numéro (77 000 07 77 avec le Sénégal choisi), mot de passe = le code,
instructions : « Choisir Sénégal, saisir le numéro, puis le code à 6 chiffres. Créer une entreprise
pour découvrir la caisse. »

### Annonces
L'application ne contient **pas** d'annonces.

### Classification du contenu
Catégorie « Utilitaires, productivité, communication… » : répondre non à toutes les questions
(pas de violence, pas de contenu sexuel, pas de jeux d'argent…) → classé « Tout public ».

### Public cible
18 ans et plus (outil professionnel pour commerçants). L'app ne s'adresse pas aux enfants.

### Sécurité des données
- Données chiffrées en transit : **oui** (HTTPS).
- Les utilisateurs peuvent demander la suppression : **oui** — dans l'app (Profil → Supprimer mon
  compte) et sur le web : `https://sama360-api.onrender.com/suppression-compte`.
- Données collectées (aucune n'est vendue ni partagée à des fins publicitaires) :

| Type | Donnée | Pourquoi | Obligatoire |
|---|---|---|---|
| Infos personnelles | Numéro de téléphone | Compte, connexion | Oui |
| Infos personnelles | Nom, e-mail | Compte, reçus | Nom oui, e-mail non |
| Photos | Photos de produits, logo, couverture, factures | Fonctionnement de l'app | Non |
| Infos financières | Historique des ventes, achats, dépenses de la boutique | Fonctionnement de l'app | Oui |
| Contacts | Noms et téléphones des clients saisis par le commerçant | Fonctionnement (crédits, reçus) | Non |
| Identifiants de l'appareil | Jeton de notifications | Notifications | Non |

Partage : aux prestataires techniques seulement (hébergement Render et Neon, stockage des
fichiers, envoi des SMS, Firebase pour les notifications), pour faire fonctionner le service.

### Autorisations demandées par l'app
- **Appareil photo** : scanner les codes-barres, photographier les produits et les factures.
- **Biométrie** : déverrouiller l'app avec l'empreinte (facultatif).
- **Internet**, **notifications**.

## 6. Envoyer la première version

1. **Tests > Test interne** : créer une version, envoyer `app-release.aab`, ajouter sa propre
   adresse Gmail comme testeur, installer depuis le lien.
2. Pour un compte développeur personnel créé récemment, Google exige un **test fermé** avec au
   moins 12 testeurs pendant 14 jours avant la production : inviter des commerçants de confiance.
3. **Production** : créer la version, notes de version (« Première version de Sama360 »),
   pays : Sénégal, Côte d'Ivoire, Congo (et autres au choix), envoyer pour examen.
