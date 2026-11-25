/**
 * Pages légales publiques de Sama360 : conditions d'utilisation, politique de confidentialité,
 * suppression du compte (page web exigée par Google Play). HTML autonome, sans dépendance.
 */

import { FREE_LIMITS, PRO_PRICES, TRIAL_DAYS } from '../../shared/plans';

/** « 5 000 F CFA » (espace insécable entre les milliers) */
const price = (n: number) => `${n.toLocaleString('fr-FR').replace(/\s/g, '&nbsp;')}&nbsp;F&nbsp;CFA`;

/** Date de la version en vigueur, affichée en haut de chaque page. */
export const LEGAL_VERSION = '25 novembre 2026';

/** Adresse de contact affichée (variable LEGAL_EMAIL sur le serveur). */
export const legalEmail = () => process.env.LEGAL_EMAIL?.trim() || 'imulhomabiala@gmail.com';

const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);

function layout(title: string, body: string, script = ''): string {
  return `<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#052E24">
<title>${esc(title)} · Sama360</title>
<style>
:root{--green:#097E4F;--deep:#052E24;--ink:#13241C;--muted:#5E6E66;--line:#E3EBE6;--soft:#E4F5EC;--danger:#B42318;--accent:#FF7A2F}
*{box-sizing:border-box}html,body{margin:0}
body{font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;color:var(--ink);background:#F4F8F5;line-height:1.6;
  background-image:radial-gradient(60% 40% at 0% 0%,#C9F2DD 0,transparent 70%),radial-gradient(50% 40% at 100% 10%,#D3EEF5 0,transparent 70%);
  background-attachment:fixed;-webkit-font-smoothing:antialiased}
.hero{background:linear-gradient(135deg,#0B6E47 0%,#052E24 60%,#0E4F5C 100%);color:#fff;padding:28px 20px 56px;border-radius:0 0 32px 32px}
.hero .in,.wrap{max-width:760px;margin:0 auto}
.brand{display:flex;align-items:center;gap:10px;font-weight:800;font-size:18px}
.brand b{display:grid;place-items:center;width:36px;height:36px;border-radius:11px;background:#19B56F;font-size:20px}
.hero h1{margin:18px 0 4px;font-size:28px;letter-spacing:-.5px;line-height:1.2}
.hero p{margin:0;color:#CDE9DD;font-size:14px}
.wrap{padding:0 16px 48px;margin-top:-32px}
.card{background:rgba(255,255,255,.9);border:1px solid rgba(255,255,255,.7);border-radius:24px;padding:22px 20px;box-shadow:0 10px 30px rgba(5,46,36,.08);margin-bottom:14px}
h2{font-size:18px;margin:26px 0 8px;letter-spacing:-.2px}h2:first-child{margin-top:0}
p,li{font-size:15px}ul{padding-left:20px}li{margin:4px 0}
a{color:var(--green);font-weight:600}
.lead{font-size:16px;font-weight:500}
.nav{display:flex;flex-wrap:wrap;gap:8px;margin-top:16px}
.nav a{color:#fff;text-decoration:none;font-size:13px;background:rgba(255,255,255,.14);border:1px solid rgba(255,255,255,.22);padding:6px 12px;border-radius:999px;font-weight:600}
table{width:100%;border-collapse:collapse;font-size:14px;margin:8px 0}
td,th{text-align:left;padding:8px 6px;border-bottom:1px solid var(--line);vertical-align:top}th{color:var(--muted);font-weight:600;font-size:13px}
label{display:block;font-weight:700;margin:14px 0 6px}
input{width:100%;font:inherit;font-size:17px;padding:13px 14px;border:1.5px solid var(--line);border-radius:14px;background:#fff}
input:focus{outline:none;border-color:var(--green)}
button{font:inherit;font-weight:800;font-size:16px;border:0;border-radius:16px;padding:14px 18px;width:100%;margin-top:14px;cursor:pointer}
.primary{background:var(--accent);color:#2B1200}.danger{background:var(--danger);color:#fff}
button:disabled{opacity:.5;cursor:default}
.msg{margin-top:12px;font-weight:600}.msg.err{color:var(--danger)}.msg.ok{color:var(--green)}
.steps{counter-reset:s;list-style:none;padding:0}.steps li{counter-increment:s;padding-left:38px;position:relative;margin:10px 0}
.steps li:before{content:counter(s);position:absolute;left:0;top:0;width:26px;height:26px;border-radius:50%;background:var(--soft);color:var(--green);display:grid;place-items:center;font-weight:800;font-size:13px}
.foot{text-align:center;color:var(--muted);font-size:13px;margin-top:20px}
</style>
</head>
<body>
<header class="hero"><div class="in">
  <div class="brand"><b>S</b>Sama360</div>
  <h1>${esc(title)}</h1>
  <p>Version du ${LEGAL_VERSION}</p>
  <nav class="nav"><a href="/cgu">Conditions d’utilisation</a><a href="/confidentialite">Confidentialité</a><a href="/suppression-compte">Supprimer mon compte</a></nav>
</div></header>
<main class="wrap">${body}
<p class="foot">Sama360 · Zolaa Tech · Dakar, Sénégal · <a href="mailto:${esc(legalEmail())}">${esc(legalEmail())}</a></p>
</main>
${script}
</body>
</html>`;
}

const contact = () => `<a href="mailto:${esc(legalEmail())}">${esc(legalEmail())}</a>`;

// ─────────────────────────────────────────────────────────────── conditions d'utilisation

export function termsPage(): string {
  return layout(
    'Conditions d’utilisation',
    `<section class="card">
<p class="lead">En créant un compte Sama360, vous acceptez ces conditions. Elles disent ce que nous vous apportons, ce que vous vous engagez à faire, et comment arrêter quand vous voulez.</p>

<h2>1. Qui sommes-nous</h2>
<p>Sama360 est une application de gestion pour les commerçants, éditée par <strong>Zolaa Tech</strong> (Ibrahim-Trésor Mabiala-Mulho, entrepreneur individuel), à Dakar, Sénégal. Pour nous écrire : ${contact()}.</p>

<h2>2. Le service</h2>
<p>Sama360 vous aide à tenir votre commerce : caisse, stock, clients et crédits, factures et devis, achats, dépenses, rapports, boutique en ligne, réservations, équipe. L’application fonctionne sur Android et dans un navigateur, au Sénégal, en Côte d’Ivoire et au Congo.</p>
<p>Sama360 est un outil d’aide à la gestion. Il ne remplace ni un comptable, ni vos obligations fiscales et déclaratives.</p>

<h2>3. Votre compte</h2>
<ul>
<li>Vous vous connectez avec votre numéro de téléphone et un code reçu par SMS, appel ou WhatsApp. Le numéro doit être le vôtre.</li>
<li>Vous gardez votre téléphone et votre code secret pour vous. Tout ce qui est fait depuis votre compte est réputé fait par vous.</li>
<li>Si vous invitez des vendeurs ou un gérant, vous choisissez ce qu’ils peuvent faire et vous restez responsable des accès donnés.</li>
<li>Sama360 est réservé aux personnes de 18 ans et plus, pour un usage professionnel.</li>
</ul>

<h2>4. Offre gratuite et Sama360 Pro</h2>
<ul>
<li>L’offre gratuite reste gratuite : ventes, caisse, stock (jusqu’à ${FREE_LIMITS.products} produits), clients et crédits, dépenses, factures et rapports des ${FREE_LIMITS.historyDays} derniers jours. Les reçus envoyés depuis l’offre gratuite portent la mention « fait avec Sama360 ».</li>
<li><strong>Sama360 Pro</strong> donne accès à tout : produits illimités, tout l’historique, boutique en ligne, vendeurs, livraisons, réservation en ligne, statistiques avancées, assistant et les autres outils. Prix fixe, sans commission sur vos ventes : <strong>${price(PRO_PRICES.weekly)} par semaine</strong>, <strong>${price(PRO_PRICES.monthly)} par mois</strong> ou <strong>${price(PRO_PRICES.yearly)} par an</strong>. Une nouvelle boutique reçoit un essai gratuit de ${TRIAL_DAYS} jours.</li>
<li>Vous payez en ligne (Wave, Orange Money, MoMo, carte, via notre prestataire Chariow) ou par transfert que nous vérifions. Pro s’active pour la durée payée. <strong>Il n’y a pas de renouvellement automatique</strong> : rien n’est prélevé sans que vous payiez à nouveau.</li>
<li>Une période payée n’est pas remboursée, sauf si l’erreur vient de nous (paiement débité deux fois, Pro jamais activé). Écrivez-nous dans ce cas.</li>
<li>Nous pouvons changer les prix ; le nouveau prix ne s’applique qu’à la période suivante, et nous vous prévenons dans l’application avant.</li>
</ul>

<h2>5. Vos données vous appartiennent</h2>
<p>Les produits, ventes, clients, factures et documents que vous saisissez sont à vous. Nous les gardons pour faire fonctionner le service, nous ne les vendons pas et nous ne faisons pas de publicité avec. Les détails sont dans la <a href="/confidentialite">politique de confidentialité</a>.</p>
<p>Quand vous enregistrez les coordonnées de vos clients (nom, téléphone, crédit), c’est vous qui en êtes responsable : vous les collectez pour votre commerce et vous respectez leurs droits.</p>

<h2>6. Ce qui est interdit</h2>
<ul>
<li>Vendre ou annoncer des produits illégaux, contrefaits ou dangereux, y compris dans la boutique en ligne.</li>
<li>Tromper vos clients, frauder, ou utiliser Sama360 pour blanchir de l’argent.</li>
<li>Envoyer des messages non désirés en masse (relances, statuts) à des personnes qui ne sont pas vos clients.</li>
<li>Utiliser le compte ou les données de quelqu’un d’autre sans son accord.</li>
<li>Chercher à contourner la sécurité, surcharger ou copier le service.</li>
</ul>

<h2>7. Disponibilité</h2>
<p>Nous faisons de notre mieux pour que Sama360 marche tout le temps et nous sauvegardons les données. Des coupures peuvent arriver (maintenance, réseau, prestataires). La caisse continue de fonctionner hors connexion et envoie les ventes au retour du réseau.</p>

<h2>8. Suspension et suppression</h2>
<ul>
<li>En cas d’abus ou de manquement grave à ces conditions, nous pouvons suspendre une boutique. Rien n’est effacé pendant une suspension, et nous vous en donnons la raison.</li>
<li>Vous pouvez supprimer votre boutique ou votre compte à tout moment, dans l’application (Mon compte) ou sur la page <a href="/suppression-compte">Supprimer mon compte</a>. Vous avez 30 jours pour changer d’avis ; ensuite, tout est effacé définitivement.</li>
</ul>

<h2>9. Responsabilité</h2>
<p>Sama360 est fourni tel quel. Nous ne sommes pas responsables des pertes dues à une erreur de saisie, à un téléphone perdu, à un accès donné par vous à un tiers, ou à une coupure de réseau. Si notre responsabilité est engagée, elle est limitée au montant que vous nous avez payé sur les 12 derniers mois.</p>

<h2>10. Changements</h2>
<p>Nous pouvons mettre à jour ces conditions. Pour un changement important, nous vous prévenons dans l’application au moins 15 jours avant. Continuer à utiliser Sama360 après cette date vaut accord.</p>

<h2>11. Droit applicable</h2>
<p>Ces conditions sont soumises au droit sénégalais. En cas de désaccord, nous cherchons d’abord une solution à l’amiable ; à défaut, les tribunaux de Dakar sont compétents.</p>
</section>`,
  );
}

// ─────────────────────────────────────────────────────────────── confidentialité

export function privacyPage(): string {
  return layout(
    'Politique de confidentialité',
    `<section class="card">
<p class="lead">Cette page dit quelles données Sama360 garde, pourquoi, avec qui elles sont partagées, combien de temps, et comment vous pouvez les voir, les corriger ou les effacer.</p>

<h2>Responsable</h2>
<p><strong>Zolaa Tech</strong> (Ibrahim-Trésor Mabiala-Mulho), Dakar, Sénégal. Contact pour toute question ou demande : ${contact()}.</p>

<h2>Ce que nous gardons</h2>
<table>
<tr><th>Données</th><th>Pourquoi</th></tr>
<tr><td>Votre numéro de téléphone, votre nom, votre e-mail (facultatif), votre photo (facultative)</td><td>Vous connecter, vous reconnaître dans l’équipe, vous envoyer vos reçus</td></tr>
<tr><td>Votre boutique : nom, logo, pays, ville, adresse, numéros de paiement mobile</td><td>Reçus, factures, boutique en ligne, QR de paiement à la caisse</td></tr>
<tr><td>Votre activité : produits, ventes, stock, dépenses, achats, factures, caisse</td><td>Le service lui-même : caisse, stock, rapports</td></tr>
<tr><td>Les clients et fournisseurs que vous saisissez : nom, téléphone, crédit, notes</td><td>Suivi des crédits, relances, factures (voir « Les données de vos clients »)</td></tr>
<tr><td>Votre téléphone : identifiant de session, jeton de notifications</td><td>Garder votre session ouverte, vous envoyer des alertes (stock bas, commandes)</td></tr>
<tr><td>Paiements Sama360 Pro : montant, référence, e-mail de reçu</td><td>Activer Pro et garder la preuve du paiement</td></tr>
<tr><td>Questions posées à l’assistant, photos de factures fournisseurs</td><td>Répondre à vos questions, lire la facture pour remplir l’achat</td></tr>
</table>
<p>Nous n’utilisons pas votre position, nous ne lisons pas les contacts de votre téléphone, nous n’avons ni publicité ni outil de pistage. L’appareil photo ne sert que quand vous scannez un code-barres ou prenez une photo. Votre empreinte digitale reste sur votre téléphone : Sama360 ne la reçoit jamais.</p>

<h2>Les données de vos clients</h2>
<p>Quand vous enregistrez vos clients, vous êtes responsable de ces données et Sama360 les traite pour votre compte. Nous ne les utilisons jamais pour nous-mêmes, nous ne contactons pas vos clients, et nous ne les partageons avec aucune autre boutique. Un client qui veut voir ou effacer ses données s’adresse à vous ; nous vous aidons si besoin.</p>

<h2>Avec qui elles sont partagées</h2>
<p>Nous ne vendons aucune donnée. Seuls les prestataires techniques nécessaires au service y accèdent, pour notre compte :</p>
<table>
<tr><th>Prestataire</th><th>Rôle</th></tr>
<tr><td>Render</td><td>Héberge le serveur de Sama360 (États-Unis)</td></tr>
<tr><td>Neon</td><td>Base de données</td></tr>
<tr><td>Cloudflare</td><td>Stockage des logos, photos et documents</td></tr>
<tr><td>Twilio</td><td>Envoi des codes de connexion par SMS, appel ou WhatsApp</td></tr>
<tr><td>Google Firebase</td><td>Envoi des notifications sur votre téléphone</td></tr>
<tr><td>Chariow</td><td>Paiement en ligne de Sama360 Pro</td></tr>
<tr><td>Anthropic</td><td>Assistant et lecture des factures photographiées, seulement quand vous les utilisez</td></tr>
</table>
<p>Ces serveurs se trouvent en dehors de l’Afrique, surtout aux États-Unis et en Europe. Les échanges sont chiffrés (HTTPS) et l’accès est réservé à ce dont chaque prestataire a besoin. Nous ne communiquons des données aux autorités que sur demande légale.</p>

<h2>Combien de temps</h2>
<ul>
<li>Tant que votre compte et votre boutique existent.</li>
<li>Après une suppression : 30 jours pour changer d’avis, puis effacement définitif.</li>
<li>Les codes de connexion expirent en quelques minutes.</li>
<li>Les reçus de paiement Pro peuvent être gardés plus longtemps si la loi l’exige.</li>
</ul>

<h2>Sécurité</h2>
<p>Connexion par code à usage unique, code secret et empreinte sur le téléphone, échanges chiffrés, chaque boutique isolée des autres dans la base de données, accès de l’équipe Sama360 limité, et ses actions sur une boutique enregistrées.</p>

<h2>Vos droits</h2>
<p>Vous pouvez demander à voir vos données, les corriger, vous opposer à un traitement ou les faire effacer. La plupart se fait directement dans l’application (Mon compte, Ma boutique). Pour le reste, écrivez à ${contact()} : nous répondons sous 30 jours.</p>
<p>Ces droits viennent des lois sur les données personnelles de nos pays :</p>
<ul>
<li><strong>Sénégal</strong> : loi n° 2008-12 du 25 janvier 2008. Autorité : Commission de protection des données personnelles (CDP).</li>
<li><strong>Côte d’Ivoire</strong> : loi n° 2013-450 du 19 juin 2013. Autorité : ARTCI.</li>
<li><strong>Congo</strong> : loi n° 29-2019 du 10 octobre 2019. Autorité : Commission nationale de protection des données à caractère personnel.</li>
</ul>
<p>Si notre réponse ne vous satisfait pas, vous pouvez saisir l’autorité de votre pays.</p>

<h2>Supprimer votre compte</h2>
<p>Dans l’application : <em>Mon compte → Supprimer mon compte</em>. Sans l’application : <a href="/suppression-compte">page de suppression</a>.</p>

<h2>Changements</h2>
<p>Si cette politique change de façon importante, nous vous prévenons dans l’application avant que le changement s’applique.</p>
</section>`,
  );
}

// ─────────────────────────────────────────────────────────────── suppression du compte

export function deletionPage(): string {
  return layout(
    'Supprimer mon compte',
    `<section class="card">
<p class="lead">Vous pouvez supprimer votre compte Sama360 et ses données ici, sans l’application.</p>
<h2>Ce qui est supprimé</h2>
<ul>
<li>Votre compte : numéro, nom, e-mail, photo, sessions et notifications.</li>
<li>Les boutiques dont vous êtes propriétaire, avec leurs produits, ventes, clients, factures et documents.</li>
<li>Vous quittez les boutiques des autres où vous étiez membre ; leurs données restent à leur propriétaire.</li>
</ul>
<p>Vous avez <strong>30 jours</strong> pour changer d’avis : reconnectez-vous avec le même numéro et tout revient. Après 30 jours, l’effacement est définitif. Les reçus de paiement Pro peuvent être gardés si la loi l’exige.</p>
<p>Dans l’application, c’est aussi possible : <em>Mon compte → Supprimer mon compte</em>.</p>
</section>

<section class="card" id="form">
<h2>Demander la suppression</h2>
<ol class="steps">
<li>Entrez le numéro de votre compte, avec l’indicatif (+221, +225 ou +242).</li>
<li>Recevez un code et tapez-le.</li>
<li>Tapez SUPPRIMER pour confirmer.</li>
</ol>
<label for="phone">Numéro de téléphone</label>
<input id="phone" type="tel" inputmode="tel" autocomplete="tel" placeholder="+221 77 123 45 67">
<button class="primary" id="send">Recevoir le code</button>
<div id="step2" hidden>
  <label for="code">Code reçu</label>
  <input id="code" inputmode="numeric" autocomplete="one-time-code" maxlength="6" placeholder="6 chiffres">
  <label for="confirm">Tapez SUPPRIMER</label>
  <input id="confirm" autocapitalize="characters" placeholder="SUPPRIMER">
  <button class="danger" id="del">Supprimer mon compte</button>
</div>
<p class="msg" id="msg" role="status"></p>
</section>`,
    `<script>
(function(){
  var $=function(id){return document.getElementById(id)};
  var msg=function(t,ok){var m=$('msg');m.textContent=t;m.className='msg '+(ok?'ok':'err')};
  var phone=function(){return $('phone').value.replace(/[^0-9+]/g,'')};
  async function post(url,body){
    var r=await fetch(url,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
    var j={};try{j=await r.json()}catch(e){}
    if(!r.ok)throw new Error((j.error&&j.error.message)||'Erreur, réessayez');
    return j;
  }
  $('send').onclick=async function(){
    if(!/^\\+\\d{9,15}$/.test(phone()))return msg('Numéro complet avec l’indicatif, par exemple +221771234567');
    this.disabled=true;
    try{await post('/v1/auth/otp/request',{phone:phone()});$('step2').hidden=false;$('code').focus();msg('Code envoyé au '+phone(),true)}
    catch(e){msg(e.message)}
    this.disabled=false;
  };
  $('del').onclick=async function(){
    if($('confirm').value.trim().toUpperCase()!=='SUPPRIMER')return msg('Tapez SUPPRIMER pour confirmer');
    this.disabled=true;
    try{
      var j=await post('/v1/public/account-deletion',{phone:phone(),code:$('code').value.trim(),confirm:$('confirm').value});
      var d=new Date(j.purgeAt).toLocaleDateString('fr-FR',{day:'numeric',month:'long',year:'numeric'});
      $('step2').hidden=true;$('send').hidden=true;
      msg('Compte supprimé. Tout sera effacé le '+d+'. D’ici là, reconnectez-vous pour annuler.',true);
    }catch(e){msg(e.message);this.disabled=false}
  };
})();
</script>`,
  );
}
