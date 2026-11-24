/**
 * Page publique de la boutique : /s/{slug} (catalogue, panier, commande) et
 * /s/{slug}/c/{id} (suivi). Une seule page autonome : elle lit l'API publique
 * du même serveur. Le slug est validé avant d'arriver ici (lettres, chiffres, tirets).
 */
export function storefrontPage(slug: string): string {
  return `<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#052E24">
<title>Boutique</title>
<style>
:root{--green:#097E4F;--leaf:#19B56F;--deep:#0F1A15;--ink:#16201B;--muted:#66706B;--line:#E6E4DE;--soft:#E7F3EC;--cream:#E9F0C9;--warn:#B25E00;--danger:#B42318;
  --serif:"Iowan Old Style","Palatino Linotype",Palatino,Georgia,"Times New Roman",serif}
*{box-sizing:border-box}
html{scroll-behavior:smooth}
html,body{margin:0}
body{font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;color:var(--ink);background:#F7F6F2;min-height:100vh;-webkit-font-smoothing:antialiased}
button{font:inherit;cursor:pointer}
a{color:inherit}
.wrap{max-width:1080px;margin:0 auto;padding:0 16px 130px}
/* ---- Barre du haut (verre sombre) ---- */
.top{position:fixed;top:12px;left:12px;right:12px;z-index:15;max-width:1056px;margin:0 auto;display:flex;align-items:center;gap:10px;
  padding:10px 12px 10px 14px;border-radius:18px;background:rgba(12,24,18,.55);backdrop-filter:blur(18px) saturate(1.4);-webkit-backdrop-filter:blur(18px) saturate(1.4);
  border:1px solid rgba(255,255,255,.12);color:#fff;transition:background .3s}
.top.solid{background:color-mix(in srgb,var(--green) 22%,#0C1812 78%)}
.top .lg{width:32px;height:32px;border-radius:10px;background:#fff;overflow:hidden;display:grid;place-items:center;color:var(--green);font-weight:800;font-size:13px;flex:none}
.top .lg img{width:100%;height:100%;object-fit:cover}
.top .nm{font-family:var(--serif);font-size:19px;letter-spacing:-.2px;flex:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.top .cart{position:relative;width:40px;height:40px;border:0;border-radius:12px;background:rgba(255,255,255,.1);color:#fff;display:grid;place-items:center}
.top .cart svg{width:21px;height:21px}
.top .cart b{position:absolute;top:-4px;right:-4px;min-width:19px;height:19px;padding:0 5px;border-radius:10px;background:var(--cream);color:var(--deep);font-size:11px;display:grid;place-items:center}
/* ---- Couverture plein écran ---- */
.cover{position:relative;min-height:100vh;min-height:100svh;display:flex;flex-direction:column;justify-content:center;align-items:center;text-align:center;
  color:#fff;padding:110px 22px 90px;overflow:hidden;
  background:radial-gradient(80% 60% at 20% 10%,color-mix(in srgb,var(--green) 70%,#fff 30%) 0,transparent 60%),
    radial-gradient(70% 60% at 90% 90%,color-mix(in srgb,var(--green) 50%,#000 50%) 0,transparent 60%),
    linear-gradient(160deg,color-mix(in srgb,var(--green) 85%,#000 15%),color-mix(in srgb,var(--green) 35%,#000 65%))}
.cover .bg{position:absolute;inset:0;background-size:cover;background-position:center;transform:scale(1.04);animation:zoom 18s ease-out forwards}
.cover:after{content:"";position:absolute;inset:0;background:radial-gradient(70% 45% at 50% 52%,rgba(0,0,0,.32),transparent 75%),linear-gradient(180deg,rgba(0,0,0,.35) 0%,rgba(0,0,0,.22) 40%,rgba(0,0,0,.6) 100%)}
@keyframes zoom{to{transform:scale(1.12)}}
@keyframes up{from{opacity:0;transform:translateY(16px)}to{opacity:1;transform:none}}
.cover .in{position:relative;z-index:1;max-width:640px;animation:up .8s ease both}
.kick{font-size:12px;letter-spacing:.22em;text-transform:uppercase;font-weight:600;opacity:.9}
.cover h1{font-family:var(--serif);font-weight:400;font-size:clamp(38px,9vw,68px);line-height:1.04;letter-spacing:-.02em;margin:14px 0 0;text-shadow:0 2px 24px rgba(0,0,0,.25)}
.cover h1 em{font-style:italic}
.cover p{margin:16px auto 0;max-width:520px;font-size:15.5px;line-height:1.55;color:rgba(255,255,255,.92);text-shadow:0 1px 12px rgba(0,0,0,.35)}
.go{display:inline-flex;align-items:center;gap:12px;margin-top:28px;padding:7px 7px 7px 22px;border-radius:999px;background:var(--cream);color:var(--deep);
  font-weight:700;font-size:15px;text-decoration:none;box-shadow:0 12px 30px rgba(0,0,0,.25);transition:transform .2s}
.go:hover{transform:translateY(-2px)}
.go i{width:38px;height:38px;border-radius:50%;background:var(--deep);color:#fff;display:grid;place-items:center;font-style:normal;font-size:17px}
.facts{display:flex;flex-wrap:wrap;justify-content:center;gap:8px;margin-top:26px}
.fact{background:rgba(255,255,255,.14);border:1px solid rgba(255,255,255,.22);backdrop-filter:blur(10px);-webkit-backdrop-filter:blur(10px);
  padding:7px 12px;border-radius:999px;font-size:12.5px;text-decoration:none;color:#fff}
.down{position:absolute;z-index:1;bottom:22px;left:50%;transform:translateX(-50%);color:rgba(255,255,255,.8);font-size:22px;animation:bob 2s ease-in-out infinite;text-decoration:none}
@keyframes bob{50%{transform:translate(-50%,6px)}}
/* ---- Catalogue ---- */
.head{display:flex;align-items:flex-end;justify-content:space-between;gap:12px;padding:34px 2px 6px}
.head h2{font-family:var(--serif);font-weight:400;font-size:30px;letter-spacing:-.01em;margin:0}
.head span{color:var(--muted);font-size:13.5px}
.tools{position:sticky;top:76px;z-index:5;padding:10px 0 12px;background:linear-gradient(#F7F6F2 75%,rgba(247,246,242,0))}
.search{width:100%;border:1px solid var(--line);background:#fff;border-radius:16px;padding:13px 16px;font-size:15px;outline:none}
.search:focus{border-color:var(--green);box-shadow:0 0 0 3px color-mix(in srgb,var(--green) 15%,transparent)}
.chips{display:flex;gap:8px;overflow-x:auto;padding-top:10px;scrollbar-width:none}
.chip{flex:none;border:1px solid var(--line);background:#fff;border-radius:999px;padding:8px 15px;font-weight:600;font-size:13.5px;color:var(--ink)}
.chip.on{background:var(--deep);color:#fff;border-color:var(--deep)}
.grid{display:grid;grid-template-columns:repeat(2,1fr);gap:12px}
.card{background:#fff;border-radius:22px;overflow:hidden;display:flex;flex-direction:column;box-shadow:0 1px 2px rgba(0,0,0,.04),0 10px 26px rgba(20,30,25,.06);transition:transform .2s}
.card:hover{transform:translateY(-3px)}
.ph{aspect-ratio:4/5;background:linear-gradient(160deg,var(--soft),color-mix(in srgb,var(--green) 18%,#fff));display:grid;place-items:center;color:var(--green);font-family:var(--serif);font-size:34px;position:relative}
.ph img{width:100%;height:100%;object-fit:cover}
.body{padding:11px 12px 12px;display:flex;flex-direction:column;gap:3px;flex:1}
.name{font-weight:600;font-size:14px;line-height:1.3;min-height:2.6em}
.price{font-weight:800;font-size:15.5px;margin-top:2px}
.hint{font-size:12px;color:var(--muted);font-weight:500}
.out{font-size:12px;color:var(--danger);font-weight:700}
.card.hot{outline:2px solid var(--leaf)}
.tag{position:absolute;top:10px;left:10px;background:var(--cream);color:var(--deep);font-family:system-ui,sans-serif;font-size:11px;font-weight:800;border-radius:999px;padding:4px 9px}
.add{margin-top:auto;border:0;border-radius:14px;background:var(--green);color:#fff;font-weight:700;padding:10px;font-size:14px}
.add:disabled{background:#D5D8D4;color:#6F7672}
.step{margin-top:auto;display:flex;align-items:center;justify-content:space-between;background:var(--soft);border-radius:14px;padding:4px}
.step button{width:36px;height:36px;border:0;border-radius:11px;background:#fff;font-size:20px;font-weight:700;color:var(--green)}
.step b{font-size:15px}
.empty{text-align:center;color:var(--muted);padding:40px 10px}
.bar{position:fixed;left:0;right:0;bottom:0;padding:12px 16px calc(12px + env(safe-area-inset-bottom));z-index:10}
.bar button{width:100%;max-width:560px;margin:0 auto;display:flex;justify-content:space-between;align-items:center;border:0;border-radius:999px;
  background:var(--deep);color:#fff;padding:15px 22px;font-weight:800;font-size:15.5px;box-shadow:0 14px 34px rgba(0,0,0,.3)}
.bar button span:last-child{background:var(--cream);color:var(--deep);border-radius:999px;padding:6px 12px;margin:-6px -10px -6px 0}
.sheet{position:fixed;inset:0;background:rgba(10,18,14,.5);z-index:20;display:flex;align-items:flex-end;justify-content:center}
.panel{background:#FAF9F6;width:100%;max-width:560px;max-height:92vh;overflow:auto;border-radius:26px 26px 0 0;padding:18px 18px calc(18px + env(safe-area-inset-bottom))}
.panel h2{margin:4px 0 12px;font-family:var(--serif);font-weight:400;font-size:26px}
.row{display:flex;justify-content:space-between;align-items:center;gap:10px;padding:8px 0;border-bottom:1px solid var(--line)}
.row:last-child{border-bottom:0}
.mini{display:flex;align-items:center;gap:6px}
.mini button{width:30px;height:30px;border:1px solid var(--line);border-radius:10px;background:#fff;font-weight:700;color:var(--green)}
.box{background:#fff;border:1px solid var(--line);border-radius:18px;padding:12px 14px;margin:12px 0}
label{display:block;font-size:13px;color:var(--muted);margin:10px 0 4px}
input,textarea{width:100%;border:1px solid var(--line);border-radius:14px;padding:12px 14px;font:inherit;font-size:15px;background:#fff;outline:none}
input:focus,textarea:focus{border-color:var(--green)}
.modes{display:flex;gap:8px}
.mode{flex:1;border:1.5px solid var(--line);background:#fff;border-radius:14px;padding:11px;text-align:left}
.mode.on{border-color:var(--green);background:var(--soft)}
.mode b{display:block;font-size:14px}.mode span{font-size:12px;color:var(--muted)}
.total{display:flex;justify-content:space-between;font-size:18px;font-weight:800;margin-top:6px}
.cta{width:100%;border:0;border-radius:16px;background:var(--green);color:#fff;font-weight:800;padding:15px;font-size:16px;margin-top:14px}
.cta:disabled{opacity:.6}
.ghost{width:100%;border:1px solid var(--line);border-radius:16px;background:#fff;color:var(--ink);font-weight:700;padding:13px;font-size:15px;margin-top:10px}
.err{color:var(--danger);font-size:13.5px;margin-top:10px;font-weight:600}
.hero{margin:84px 0 16px;border-radius:26px;padding:22px;color:#fff;background:linear-gradient(135deg,var(--green),color-mix(in srgb,var(--green) 40%,#000))}
.hero h1{margin:0;font-family:var(--serif);font-weight:400;font-size:28px}
.hero p{margin:6px 0 0;color:rgba(255,255,255,.85);font-size:14px;line-height:1.45}
.done{text-align:center;padding:10px 0}
.badge{display:inline-block;padding:6px 12px;border-radius:999px;background:var(--soft);color:var(--green);font-weight:800;font-size:13px}
.steps{display:flex;justify-content:space-between;margin:18px 0 6px;position:relative}
.steps:before{content:"";position:absolute;left:8%;right:8%;top:11px;height:3px;background:var(--line)}
.s{flex:1;text-align:center;font-size:11.5px;color:var(--muted);position:relative}
.s i{display:block;width:24px;height:24px;margin:0 auto 6px;border-radius:50%;background:#fff;border:3px solid var(--line)}
.s.on{color:var(--ink);font-weight:700}.s.on i{border-color:var(--green);background:var(--green)}
.foot{text-align:center;color:var(--muted);font-size:12px;margin-top:36px}
.wa{display:inline-flex;align-items:center;gap:8px;text-decoration:none;background:#25D366;color:#08361A;font-weight:800;border-radius:14px;padding:12px 16px;margin-top:12px}
@media (min-width:700px){.grid{grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:16px}.head h2{font-size:36px}}
@media (prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}html{scroll-behavior:auto}}
</style>
</head>
<body>
<nav class="top" id="top" hidden></nav>
<div id="app"><div class="empty">Chargement de la boutique…</div></div>
<div class="bar" id="bar" hidden><button id="cartBtn"></button></div>
<script>
(function(){
  var SLUG = ${JSON.stringify(slug)};
  var API = '/v1/public/shops/' + SLUG;
  var app = document.getElementById('app');
  var bar = document.getElementById('bar');
  var state = { data: null, cart: {}, cat: '', q: '', mode: null };
  // Produits mis en avant par un statut WhatsApp : ?p=id1,id2
  var HOT = (new URLSearchParams(location.search).get('p') || '').split(',').filter(Boolean);

  function money(n){ return new Intl.NumberFormat('fr-FR').format(Math.round(n)).replace(/[\\u202f\\u00a0]/g,' ') + ' F'; }
  function esc(s){ return String(s == null ? '' : s).replace(/[&<>"']/g, function(c){ return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]; }); }
  function initials(s){ return esc(String(s||'?').trim().split(/\\s+/).slice(0,2).map(function(w){return w[0]||'';}).join('').toUpperCase()); }
  function uuid(){
    if (window.crypto && crypto.randomUUID) return crypto.randomUUID();
    var b = new Uint8Array(16); (window.crypto||{}).getRandomValues ? crypto.getRandomValues(b) : b.forEach(function(_,i){b[i]=Math.random()*256|0;});
    b[6]=(b[6]&15)|64; b[8]=(b[8]&63)|128;
    var h = Array.prototype.map.call(b,function(x){return (x+256).toString(16).slice(1);}).join('');
    return h.slice(0,8)+'-'+h.slice(8,12)+'-'+h.slice(12,16)+'-'+h.slice(16,20)+'-'+h.slice(20);
  }
  function store(k,v){ try{ if(v===undefined) return JSON.parse(localStorage.getItem(k)||'null'); localStorage.setItem(k, JSON.stringify(v)); }catch(e){ return null; } }
  function api(path, opts){
    return fetch(API + path, Object.assign({ headers: { 'Content-Type': 'application/json' } }, opts || {}))
      .then(function(r){ return r.json().catch(function(){return {};}).then(function(j){ if(!r.ok) throw new Error((j.error && j.error.message) || 'Erreur, réessayez'); return j; }); });
  }
  function unitPrice(p, q){ return (p.wholesalePrice != null && p.wholesaleMinQty != null && q >= p.wholesaleMinQty) ? p.wholesalePrice : p.price; }
  function lines(){
    var d = state.data; if(!d) return [];
    return Object.keys(state.cart).map(function(id){
      var p = d.products.find(function(x){return x.id===id;}); var q = state.cart[id];
      return p && q > 0 ? { p: p, q: q, unit: unitPrice(p,q), total: unitPrice(p,q)*q } : null;
    }).filter(Boolean);
  }
  function subtotal(){ return lines().reduce(function(s,l){return s+l.total;},0); }
  function count(){ return lines().reduce(function(s,l){return s+l.q;},0); }
  function setQty(id, q){
    var p = state.data.products.find(function(x){return x.id===id;});
    q = Math.max(0, Math.min(q, p ? p.maxQuantity : 99));
    if (q === 0) delete state.cart[id]; else state.cart[id] = q;
    store('cart:' + SLUG, state.cart); renderGrid(); renderBar();
  }

  var CART_SVG = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M6 7h12l-1 12H7L6 7Z"/><path d="M9 7a3 3 0 0 1 6 0"/></svg>';
  // Grand titre : les deux derniers mots en italique (« Un parfum pour <em>chaque rituel.</em> »)
  function headline(t){
    var w = String(t).trim().split(/\\s+/);
    if (w.length < 4) return esc(t);
    return esc(w.slice(0, -2).join(' ')) + ' <em>' + esc(w.slice(-2).join(' ')) + '</em>';
  }
  function renderTop(){
    var s = state.data.shop, n = count(), top = document.getElementById('top');
    top.hidden = false;
    top.innerHTML = '<div class="lg">' + (s.logoFileId ? '<img alt="" src="/v1/files/' + esc(s.logoFileId) + '">' : initials(s.name)) + '</div>' +
      '<div class="nm">' + esc(s.name) + '</div>' +
      '<button class="cart" id="topCart" aria-label="Panier">' + CART_SVG + (n ? '<b>' + n + '</b>' : '') + '</button>';
    document.getElementById('topCart').addEventListener('click', function(){ if (count()) checkout(); else openShop(); });
  }
  function openShop(){ var el = document.getElementById('boutique'); if (el) el.scrollIntoView({ behavior: 'smooth' }); }

  function renderShop(){
    var s = state.data.shop;
    document.title = s.name + ' · boutique en ligne';
    if (s.brandColor && /^#[0-9A-F]{6}$/i.test(s.brandColor)) {
      var root = document.documentElement.style;
      root.setProperty('--green', s.brandColor);
      root.setProperty('--soft', 'color-mix(in srgb, ' + s.brandColor + ' 12%, white)');
      root.setProperty('--cream', 'color-mix(in srgb, ' + s.brandColor + ' 14%, #F3F6DA)');
      var meta = document.querySelector('meta[name=theme-color]'); if (meta) meta.setAttribute('content', s.brandColor);
    }
    var wa = s.whatsapp ? 'https://wa.me/' + s.whatsapp.replace(/\\D/g,'') : null;
    var cats = state.data.categories;
    var n = state.data.products.length;
    var facts = (s.delivery ? '<span class="fact">🛵 Livraison' + (s.deliveryFee ? ' ' + money(s.deliveryFee) : ' offerte') + (s.deliveryZone ? ' · ' + esc(s.deliveryZone) : '') + '</span>' : '') +
      (s.pickup ? '<span class="fact">🏬 Retrait en boutique</span>' : '') +
      (s.minOrder ? '<span class="fact">Minimum ' + money(s.minOrder) + '</span>' : '') +
      (wa ? '<a class="fact" href="' + wa + '" target="_blank" rel="noopener">💬 WhatsApp</a>' : '') +
      (s.booking ? '<a class="fact" href="/r/' + SLUG + '">📅 Prendre rendez-vous</a>' : '');
    app.innerHTML =
      '<header class="cover">' + (s.coverFileId ? '<div class="bg" style="background-image:url(/v1/files/' + esc(s.coverFileId) + ')"></div>' : '') +
      '<div class="in"><div class="kick">' + esc(s.address || s.businessName || 'Boutique en ligne') + '</div>' +
      '<h1>' + headline(s.tagline || s.name) + '</h1>' +
      (s.description ? '<p>' + esc(s.description) + '</p>' : '') +
      '<a class="go" href="#boutique" id="go">Découvrir la boutique <i>›</i></a>' +
      (facts ? '<div class="facts">' + facts + '</div>' : '') + '</div>' +
      '<a class="down" href="#boutique" aria-label="Voir les produits">⌄</a></header>' +
      '<div class="wrap"><section id="boutique"><div class="head"><h2>Nos produits</h2><span>' + n + ' produit' + (n > 1 ? 's' : '') + '</span></div>' +
      '<div class="tools"><input class="search" id="q" placeholder="Rechercher un produit" value="' + esc(state.q) + '">' +
      (cats.length ? '<div class="chips"><button class="chip' + (state.cat ? '' : ' on') + '" data-cat="">Tout</button>' +
        cats.map(function(c){ return '<button class="chip' + (state.cat===c.id?' on':'') + '" data-cat="' + esc(c.id) + '">' + esc(c.name) + '</button>'; }).join('') + '</div>' : '') +
      '</div><div class="grid" id="grid"></div></section><div class="foot">Boutique propulsée par Sama360</div></div>';
    document.getElementById('go').addEventListener('click', function(e){ e.preventDefault(); openShop(); });
    document.getElementById('q').addEventListener('input', function(e){ state.q = e.target.value; renderGrid(); });
    Array.prototype.forEach.call(app.querySelectorAll('.chip'), function(b){
      b.addEventListener('click', function(){ state.cat = b.getAttribute('data-cat'); renderShop(); openShop(); });
    });
    renderTop(); renderGrid(); renderBar();
  }
  // La barre du haut devient opaque une fois la couverture passée
  window.addEventListener('scroll', function(){
    var top = document.getElementById('top'); if (!top) return;
    top.classList.toggle('solid', window.scrollY > window.innerHeight * 0.7);
  }, { passive: true });

  function renderGrid(){
    var grid = document.getElementById('grid'); if(!grid) return;
    var q = state.q.trim().toLowerCase();
    var items = state.data.products.filter(function(p){ return (!state.cat || p.categoryId === state.cat) && (!q || p.name.toLowerCase().indexOf(q) >= 0); });
    if (HOT.length) items = items.slice().sort(function(a,b){ return (HOT.indexOf(a.id) < 0 ? 99 : HOT.indexOf(a.id)) - (HOT.indexOf(b.id) < 0 ? 99 : HOT.indexOf(b.id)); });
    if (!items.length){ grid.innerHTML = '<div class="empty" style="grid-column:1/-1">Aucun produit ne correspond.</div>'; return; }
    grid.innerHTML = items.map(function(p){
      var q2 = state.cart[p.id] || 0;
      var unit = p.unit && p.unit !== 'pièce' ? ' / ' + esc(p.unit) : '';
      var action = !p.available ? '<button class="add" disabled>Épuisé</button>' :
        q2 ? '<div class="step"><button data-dec="' + p.id + '" aria-label="Un de moins">−</button><b>' + q2 + '</b><button data-inc="' + p.id + '" aria-label="Un de plus">+</button></div>' :
        '<button class="add" data-inc="' + p.id + '">Ajouter</button>';
      var hot = HOT.indexOf(p.id) >= 0;
      return '<article class="card' + (hot ? ' hot' : '') + '"><div class="ph">' + (p.imageFileId ? '<img loading="lazy" alt="" src="/v1/files/' + esc(p.imageFileId) + '">' : initials(p.name)) + (hot ? '<span class="tag">En vedette</span>' : '') + '</div>' +
        '<div class="body"><div class="name">' + esc(p.name) + '</div><div class="price">' + money(p.price) + '<span class="hint">' + unit + '</span></div>' +
        (p.wholesalePrice != null ? '<div class="hint">' + money(p.wholesalePrice) + ' dès ' + p.wholesaleMinQty + '</div>' : '') +
        (!p.available ? '<div class="out">Rupture de stock</div>' : '') + action + '</div></article>';
    }).join('');
    Array.prototype.forEach.call(grid.querySelectorAll('[data-inc]'), function(b){ b.addEventListener('click', function(){ var id=b.getAttribute('data-inc'); setQty(id,(state.cart[id]||0)+1); }); });
    Array.prototype.forEach.call(grid.querySelectorAll('[data-dec]'), function(b){ b.addEventListener('click', function(){ var id=b.getAttribute('data-dec'); setQty(id,(state.cart[id]||0)-1); }); });
  }

  function renderBar(){
    var n = count();
    bar.hidden = n === 0;
    document.getElementById('cartBtn').innerHTML = '<span>' + n + ' article' + (n>1?'s':'') + ' · ' + money(subtotal()) + '</span><span>Commander ›</span>';
    if (state.data && !document.getElementById('top').hidden) renderTop();
  }

  function checkout(){
    var s = state.data.shop;
    if (!state.mode) state.mode = s.delivery ? 'delivery' : 'pickup';
    var saved = store('customer') || {};
    var sheet = document.createElement('div'); sheet.className = 'sheet';
    sheet.addEventListener('click', function(e){ if (e.target === sheet) sheet.remove(); });
    function draw(){
      var ls = lines(); if (!ls.length){ sheet.remove(); return; }
      var fee = state.mode === 'delivery' ? s.deliveryFee : 0;
      var sub = subtotal();
      sheet.innerHTML = '<div class="panel" role="dialog" aria-label="Votre commande"><h2>Votre commande</h2><div class="box">' +
        ls.map(function(l){ return '<div class="row"><div><b>' + esc(l.p.name) + '</b><div class="hint">' + money(l.unit) + ' × ' + l.q + '</div></div>' +
          '<div class="mini"><button data-dec="' + l.p.id + '">−</button><b>' + l.q + '</b><button data-inc="' + l.p.id + '">+</button></div></div>'; }).join('') + '</div>' +
        '<div class="modes">' + (s.delivery ? '<button class="mode' + (state.mode==='delivery'?' on':'') + '" data-mode="delivery"><b>🛵 Livraison</b><span>' + (s.deliveryFee ? money(s.deliveryFee) : 'Offerte') + '</span></button>' : '') +
        (s.pickup ? '<button class="mode' + (state.mode==='pickup'?' on':'') + '" data-mode="pickup"><b>🏬 Retrait</b><span>En boutique</span></button>' : '') + '</div>' +
        '<label for="n">Votre nom</label><input id="n" autocomplete="name" value="' + esc(saved.name||'') + '">' +
        '<label for="t">Téléphone</label><input id="t" type="tel" autocomplete="tel" inputmode="tel" placeholder="' + esc(s.phoneExample || '77 123 45 67') + '" value="' + esc(saved.phone||'') + '">' +
        (state.mode === 'delivery' ? '<label for="a">Adresse de livraison</label><textarea id="a" rows="2" placeholder="Quartier, rue, repère">' + esc(saved.address||'') + '</textarea>' : '') +
        '<label for="m">Note (facultatif)</label><input id="m" placeholder="Couleur, taille, heure de passage…">' +
        '<div class="box"><div class="row"><span>Articles</span><b>' + money(sub) + '</b></div>' + (fee ? '<div class="row"><span>Livraison</span><b>' + money(fee) + '</b></div>' : '') +
        '<div class="total"><span>Total</span><span>' + money(sub + fee) + '</span></div></div>' +
        (s.minOrder && sub < s.minOrder ? '<div class="err">Commande minimum : ' + money(s.minOrder) + '</div>' : '') +
        '<div class="err" id="e"></div><button class="cta" id="go"' + (s.minOrder && sub < s.minOrder ? ' disabled' : '') + '>Envoyer la commande · ' + money(sub + fee) + '</button>' +
        '<button class="ghost" id="close">Continuer mes achats</button><p class="hint" style="text-align:center">Vous payez à la livraison ou au retrait (' + esc(s.payHint || 'espèces, Wave, Orange Money') + ').</p></div>';
      Array.prototype.forEach.call(sheet.querySelectorAll('[data-inc]'), function(b){ b.addEventListener('click', function(){ var id=b.getAttribute('data-inc'); setQty(id,(state.cart[id]||0)+1); keep(); draw(); }); });
      Array.prototype.forEach.call(sheet.querySelectorAll('[data-dec]'), function(b){ b.addEventListener('click', function(){ var id=b.getAttribute('data-dec'); setQty(id,(state.cart[id]||0)-1); keep(); draw(); }); });
      Array.prototype.forEach.call(sheet.querySelectorAll('[data-mode]'), function(b){ b.addEventListener('click', function(){ keep(); state.mode=b.getAttribute('data-mode'); draw(); }); });
      sheet.querySelector('#close').addEventListener('click', function(){ keep(); sheet.remove(); });
      sheet.querySelector('#go').addEventListener('click', send);
    }
    function keep(){
      var n = sheet.querySelector('#n'), t = sheet.querySelector('#t'), a = sheet.querySelector('#a');
      if (n) saved.name = n.value; if (t) saved.phone = t.value; if (a) saved.address = a.value;
    }
    function send(){
      keep();
      var err = sheet.querySelector('#e'), btn = sheet.querySelector('#go');
      if (!saved.name || saved.name.trim().length < 2) { err.textContent = 'Indiquez votre nom'; return; }
      if (!saved.phone || saved.phone.replace(/\\D/g,'').length < 9) { err.textContent = 'Indiquez votre numéro de téléphone'; return; }
      if (state.mode === 'delivery' && !(saved.address||'').trim()) { err.textContent = 'Indiquez l’adresse de livraison'; return; }
      store('customer', saved);
      var pendingId = store('pending:' + SLUG) || uuid();
      store('pending:' + SLUG, pendingId);
      btn.disabled = true; btn.textContent = 'Envoi…'; err.textContent = '';
      api('/orders', { method: 'POST', body: JSON.stringify({
        id: pendingId, customerName: saved.name.trim(), customerPhone: saved.phone, mode: state.mode,
        address: state.mode === 'delivery' ? saved.address : null, note: (sheet.querySelector('#m').value || '').trim() || null,
        items: lines().map(function(l){ return { productId: l.p.id, quantity: l.q }; })
      }) }).then(function(order){
        store('pending:' + SLUG, null); state.cart = {}; store('cart:' + SLUG, {});
        var mine = store('orders:' + SLUG) || []; mine.unshift(order.id); store('orders:' + SLUG, mine.slice(0, 10));
        sheet.remove(); history.pushState(null, '', '/s/' + SLUG + '/c/' + order.id); showOrder(order);
      }).catch(function(e){
        btn.disabled = false; btn.textContent = 'Réessayer'; err.textContent = e.message;
        // Un refus définitif (stock, adresse…) : la prochaine tentative est une nouvelle commande
        if (!/réseau|Failed|fetch/i.test(e.message)) store('pending:' + SLUG, null);
      });
    }
    draw(); document.body.appendChild(sheet);
  }

  var poll = null;
  function showOrder(o){
    bar.hidden = true;
    var steps = o.mode === 'delivery' ? ['new','confirmed','ready','delivering','completed'] : ['new','confirmed','ready','completed'];
    var names = { new: 'Reçue', confirmed: 'Confirmée', ready: 'Prête', delivering: 'En route', completed: o.mode === 'delivery' ? 'Livrée' : 'Retirée' };
    var at = steps.indexOf(o.status);
    var s = state.data ? state.data.shop : null;
    var wa = s && s.whatsapp ? 'https://wa.me/' + s.whatsapp.replace(/\\D/g,'') + '?text=' + encodeURIComponent('Bonjour, je viens de passer la commande ' + o.number + '.') : null;
    if (state.data) renderTop();
    app.innerHTML = '<div class="wrap"><header class="hero"><div><div><h1>✓ Commande <span style="white-space:nowrap">' + esc(o.number) + '</span></h1><p>' +
      (o.status === 'cancelled' ? 'Cette commande a été annulée.' : 'Merci ' + esc(o.customerName) + ' ! ' + (o.status === 'new' ? 'La boutique va confirmer votre commande.' : 'Suivez son avancement ici.')) + '</p></div></div></header>' +
      '<div class="box done"><span class="badge">' + esc(o.statusLabel) + '</span>' +
      (o.status !== 'cancelled' ? '<div class="steps">' + steps.map(function(k,i){ return '<div class="s' + (i <= at ? ' on' : '') + '"><i></i>' + names[k] + '</div>'; }).join('') + '</div>' : '') + '</div>' +
      '<div class="box">' + o.lines.map(function(l){ return '<div class="row"><span>' + esc(l.name) + ' × ' + l.quantity + '</span><b>' + money(l.total) + '</b></div>'; }).join('') +
      (o.deliveryFee ? '<div class="row"><span>Livraison</span><b>' + money(o.deliveryFee) + '</b></div>' : '') +
      '<div class="total"><span>Total à payer</span><span>' + money(o.total) + '</span></div>' +
      '<p class="hint">' + (o.mode === 'delivery' ? '🛵 Livraison : ' + esc(o.address) : '🏬 Retrait en boutique') + '</p></div>' +
      (wa ? '<div style="text-align:center"><a class="wa" target="_blank" rel="noopener" href="' + wa + '">💬 Écrire à la boutique</a></div>' : '') +
      '<button class="ghost" id="back">Retour à la boutique</button><div class="foot">Gardez cette page : elle se met à jour toute seule.</div></div>';
    document.getElementById('back').addEventListener('click', function(){ history.pushState(null, '', '/s/' + SLUG); clearInterval(poll); start(); });
    clearInterval(poll);
    if (o.status !== 'completed' && o.status !== 'cancelled') {
      poll = setInterval(function(){ api('/orders/' + o.id).then(function(n){ if (n.status !== o.status) showOrder(n); }).catch(function(){}); }, 20000);
    }
  }

  function start(){
    var m = location.pathname.match(/\\/c\\/([0-9a-f-]{36})/i);
    api('').then(function(d){
      state.data = d; state.cart = store('cart:' + SLUG) || {};
      if (m) return api('/orders/' + m[1]).then(showOrder);
      renderShop();
    }).catch(function(e){
      app.innerHTML = '<div class="wrap"><div class="empty" style="padding-top:120px"><h2>Boutique introuvable</h2><p>' + esc(e.message) + '</p></div>';
    });
  }
  document.getElementById('cartBtn').addEventListener('click', checkout);
  window.addEventListener('popstate', start);
  start();
})();
</script>
</body>
</html>`;
}
