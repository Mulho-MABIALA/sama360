/**
 * Page publique de réservation : /r/{slug}. Le client choisit une prestation, un jour, un créneau libre,
 * puis laisse son nom et son numéro. Page autonome qui lit l'API publique du même serveur.
 * Le slug est validé avant d'arriver ici (lettres, chiffres, tirets).
 */
export function bookingPage(slug: string): string {
  return `<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#052E24">
<title>Prendre rendez-vous</title>
<style>
:root{--green:#097E4F;--deep:#052E24;--ink:#13241C;--muted:#5E6E66;--line:#E3EBE6;--soft:#E4F5EC;--danger:#B42318;--glass:rgba(255,255,255,.8)}
*{box-sizing:border-box}html,body{margin:0}
body{font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;color:var(--ink);background:#F4F8F5;
  background-image:radial-gradient(60% 40% at 0% 0%,#C9F2DD 0,transparent 70%),radial-gradient(50% 40% at 100% 10%,#D3EEF5 0,transparent 70%),radial-gradient(60% 40% at 50% 100%,#FBE3D2 0,transparent 70%);
  background-attachment:fixed;min-height:100vh;-webkit-font-smoothing:antialiased}
button{font:inherit;cursor:pointer}
.wrap{max-width:620px;margin:0 auto;padding:0 16px 40px}
.hero{margin:16px 0;border-radius:26px;padding:20px;color:#fff;position:relative;overflow:hidden;
  background:var(--hero,linear-gradient(135deg,#0B6E47 0%,#052E24 55%,#0E4F5C 100%));box-shadow:0 18px 40px rgba(5,46,36,.25)}
.brand{display:flex;gap:14px;align-items:center}
.logo{width:54px;height:54px;border-radius:17px;background:#fff;display:grid;place-items:center;overflow:hidden;flex:none;color:var(--green);font-weight:800;font-size:20px}
.logo img{width:100%;height:100%;object-fit:contain}
.hero h1{margin:0;font-size:22px}.hero p{margin:5px 0 0;color:#CDE9DD;font-size:14px}
h2{font-size:17px;margin:20px 4px 10px}
.card{background:var(--glass);backdrop-filter:blur(14px);border:1px solid rgba(255,255,255,.85);border-radius:20px;box-shadow:0 10px 24px rgba(11,61,46,.08)}
.svc{display:flex;justify-content:space-between;align-items:center;width:100%;text-align:left;padding:14px 16px;margin-bottom:10px;border:1.5px solid transparent}
.svc.on{border-color:var(--green);background:var(--soft)}
.svc b{display:block;font-size:15px}.svc span{color:var(--muted);font-size:13px}.svc .p{font-weight:800;white-space:nowrap}
.days{display:flex;gap:8px;overflow-x:auto;padding:2px 2px 6px;scrollbar-width:none}
.day{flex:none;width:62px;padding:9px 0;border-radius:16px;border:1px solid var(--line);background:#fff;text-align:center}
.day small{display:block;color:var(--muted);font-size:11.5px;text-transform:capitalize}.day b{font-size:18px}
.day.on{background:var(--green);border-color:var(--green);color:#fff}.day.on small{color:#E4F5EC}
.slots{display:grid;grid-template-columns:repeat(auto-fill,minmax(78px,1fr));gap:8px}
.slot{padding:11px 0;border-radius:14px;border:1px solid var(--line);background:#fff;font-weight:700}
.slot.on{background:var(--ink);color:#fff;border-color:var(--ink)}
.hint{color:var(--muted);font-size:13.5px;padding:6px 4px}
label{display:block;font-size:13px;color:var(--muted);margin:12px 0 4px}
input{width:100%;border:1px solid var(--line);border-radius:14px;padding:12px 14px;font:inherit;font-size:15px;background:#fff;outline:none}
input:focus{border-color:var(--green)}
.cta{width:100%;border:0;border-radius:16px;background:var(--green);color:#fff;font-weight:800;padding:15px;font-size:16px;margin-top:16px}
.cta:disabled{opacity:.55}
.err{color:var(--danger);font-size:13.5px;margin-top:10px;font-weight:600}
.done{text-align:center;padding:24px 18px}
.big{font-size:44px}
.wa{display:inline-flex;align-items:center;gap:8px;text-decoration:none;background:#25D366;color:#08361A;font-weight:800;border-radius:14px;padding:12px 16px;margin-top:14px}
.empty{text-align:center;color:var(--muted);padding:40px 10px}
.foot{text-align:center;color:var(--muted);font-size:12px;margin-top:26px}
</style>
</head>
<body>
<div class="wrap" id="app"><div class="empty">Chargement…</div></div>
<script>
(function(){
  var SLUG = ${JSON.stringify(slug)};
  var API = '/v1/public/shops/' + SLUG + '/booking';
  var app = document.getElementById('app');
  var st = { data: null, service: null, day: null, time: null, slots: null };

  function money(n){ return new Intl.NumberFormat('fr-FR').format(Math.round(n)).replace(/[\\u202f\\u00a0]/g,' ') + ' F'; }
  function esc(s){ return String(s == null ? '' : s).replace(/[&<>"']/g, function(c){ return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]; }); }
  function dur(m){ return m < 60 ? m + ' min' : Math.floor(m/60) + ' h' + (m % 60 ? ' ' + String(m % 60).padStart(2,'0') : ''); }
  function store(k,v){ try{ if(v===undefined) return JSON.parse(localStorage.getItem(k)||'null'); localStorage.setItem(k, JSON.stringify(v)); }catch(e){ return null; } }
  function uuid(){
    if (window.crypto && crypto.randomUUID) return crypto.randomUUID();
    var b = new Uint8Array(16); crypto.getRandomValues(b); b[6]=(b[6]&15)|64; b[8]=(b[8]&63)|128;
    var h = Array.prototype.map.call(b,function(x){return (x+256).toString(16).slice(1);}).join('');
    return h.slice(0,8)+'-'+h.slice(8,12)+'-'+h.slice(12,16)+'-'+h.slice(16,20)+'-'+h.slice(20);
  }
  function api(path, opts){
    return fetch(API + path, Object.assign({ headers: { 'Content-Type': 'application/json' } }, opts || {}))
      .then(function(r){ return r.json().catch(function(){return {};}).then(function(j){ if(!r.ok){ var e = new Error((j.error && j.error.message) || 'Erreur, réessayez'); e.code = j.error && j.error.code; throw e; } return j; }); });
  }
  function fmtDay(d, opt){ return new Intl.DateTimeFormat('fr-FR', Object.assign({ timeZone: 'UTC' }, opt)).format(new Date(d + 'T00:00:00Z')); }
  function hourLabel(t){ var p = t.split(':'); return Number(p[0]) + ' h' + (p[1] !== '00' ? ' ' + p[1] : ''); }

  function header(){
    var s = st.data.shop;
    return '<header class="hero"><div class="brand"><div class="logo">' + (s.logoFileId ? '<img alt="" src="/v1/files/' + esc(s.logoFileId) + '">' : esc(s.name.slice(0,1))) +
      '</div><div><h1>' + esc(s.name) + '</h1><p>Prendre rendez-vous' + (s.address ? ' · 📍 ' + esc(s.address) : '') + '</p></div></div></header>';
  }

  function render(){
    var d = st.data;
    if (!d.services.length) { app.innerHTML = header() + '<div class="empty">Aucune prestation n’est encore proposée. Contactez la boutique.</div>'; return; }
    var html = header() + '<h2>1. Choisissez une prestation</h2>' + d.services.map(function(s){
      return '<button class="card svc' + (st.service && st.service.id === s.id ? ' on' : '') + '" data-svc="' + esc(s.id) + '"><div><b>' + esc(s.name) + '</b><span>' + dur(s.duration) + '</span></div><span class="p">' + money(s.price) + '</span></button>';
    }).join('');
    if (st.service) {
      html += '<h2>2. Choisissez le jour</h2><div class="days">' + d.days.map(function(x){
        return '<button class="day' + (st.day === x ? ' on' : '') + '" data-day="' + x + '"><small>' + fmtDay(x, { weekday: 'short' }) + '</small><b>' + fmtDay(x, { day: 'numeric' }) + '</b><small>' + fmtDay(x, { month: 'short' }) + '</small></button>';
      }).join('') + '</div>';
    }
    if (st.service && st.day) {
      html += '<h2>3. Choisissez l’heure</h2>';
      if (st.slots === null) html += '<div class="hint">Recherche des créneaux libres…</div>';
      else if (!st.slots.length) html += '<div class="hint">Plus de créneau libre ce jour-là. Essayez un autre jour.</div>';
      else html += '<div class="slots">' + st.slots.map(function(t){ return '<button class="slot' + (st.time === t ? ' on' : '') + '" data-time="' + t + '">' + hourLabel(t) + '</button>'; }).join('') + '</div>';
    }
    if (st.time) {
      var me = store('customer') || {};
      html += '<h2>4. Vos coordonnées</h2><div class="card" style="padding:4px 14px 14px">' +
        '<label for="n">Votre nom</label><input id="n" autocomplete="name" value="' + esc(me.name || '') + '">' +
        '<label for="t">Téléphone</label><input id="t" type="tel" inputmode="tel" autocomplete="tel" placeholder="' + esc(d.shop.phoneExample || '77 123 45 67') + '" value="' + esc(me.phone || '') + '">' +
        '<label for="m">Note (facultatif)</label><input id="m" placeholder="Ex. mèches fournies"></div>' +
        '<div class="err" id="e"></div><button class="cta" id="go">Réserver ' + esc(fmtDay(st.day, { weekday: 'long', day: 'numeric', month: 'long' })) + ' à ' + hourLabel(st.time) + '</button>';
    }
    app.innerHTML = html + '<div class="foot">Réservation propulsée par Sama360</div>';
    Array.prototype.forEach.call(app.querySelectorAll('[data-svc]'), function(b){ b.addEventListener('click', function(){
      st.service = d.services.find(function(s){ return s.id === b.getAttribute('data-svc'); }); st.time = null; if (st.day) loadSlots(); else render();
    }); });
    Array.prototype.forEach.call(app.querySelectorAll('[data-day]'), function(b){ b.addEventListener('click', function(){ st.day = b.getAttribute('data-day'); st.time = null; loadSlots(); }); });
    Array.prototype.forEach.call(app.querySelectorAll('[data-time]'), function(b){ b.addEventListener('click', function(){ st.time = b.getAttribute('data-time'); render(); var go = document.getElementById('go'); if (go) go.scrollIntoView({ behavior: 'smooth', block: 'center' }); }); });
    var go = document.getElementById('go'); if (go) go.addEventListener('click', send);
  }

  function loadSlots(){
    st.slots = null; render();
    api('/slots?serviceId=' + encodeURIComponent(st.service.id) + '&day=' + st.day).then(function(r){ st.slots = r.slots; render(); })
      .catch(function(){ st.slots = []; render(); });
  }

  function send(){
    var n = document.getElementById('n').value.trim(), t = document.getElementById('t').value.trim(), m = document.getElementById('m').value.trim();
    var err = document.getElementById('e'), btn = document.getElementById('go');
    if (n.length < 2) { err.textContent = 'Indiquez votre nom'; return; }
    if (t.replace(/\\D/g,'').length < 9) { err.textContent = 'Indiquez votre numéro de téléphone'; return; }
    store('customer', { name: n, phone: t });
    var id = store('pending:' + SLUG) || uuid(); store('pending:' + SLUG, id);
    btn.disabled = true; btn.textContent = 'Envoi…'; err.textContent = '';
    api('', { method: 'POST', body: JSON.stringify({ id: id, serviceId: st.service.id, day: st.day, time: st.time, name: n, phone: t, note: m || null }) })
      .then(function(a){ store('pending:' + SLUG, null); done(a); })
      .catch(function(e){
        btn.disabled = false; btn.textContent = 'Réessayer'; err.textContent = e.message;
        if (e.code === 'SLOT_TAKEN') { store('pending:' + SLUG, null); st.time = null; loadSlots(); }
        else if (!/réseau|Failed|fetch/i.test(e.message)) store('pending:' + SLUG, null);
      });
  }

  function done(a){
    var s = st.data.shop;
    var when = fmtDay(st.day, { weekday: 'long', day: 'numeric', month: 'long' }) + ' à ' + hourLabel(st.time);
    var wa = s.whatsapp ? 'https://wa.me/' + s.whatsapp.replace(/\\D/g,'') + '?text=' + encodeURIComponent('Bonjour, je viens de réserver ' + a.serviceName + ' pour ' + when + '.') : null;
    app.innerHTML = header() + '<div class="card done"><div class="big">✅</div><h2 style="margin:8px 0">Rendez-vous réservé</h2>' +
      '<p><b>' + esc(a.serviceName) + '</b><br>' + esc(when) + '</p><p class="hint">' + money(a.price) + ' · à régler sur place</p>' +
      (wa ? '<a class="wa" target="_blank" rel="noopener" href="' + wa + '">💬 Écrire à la boutique</a>' : '') +
      '<button class="cta" id="again" style="background:#fff;color:var(--ink);border:1px solid var(--line)">Prendre un autre rendez-vous</button></div>';
    document.getElementById('again').addEventListener('click', function(){ st.service = null; st.day = null; st.time = null; render(); });
  }

  api('').then(function(d){
    st.data = d;
    var c = d.shop.brandColor;
    if (c && /^#[0-9A-F]{6}$/.test(c)) {
      var root = document.documentElement.style;
      root.setProperty('--green', c); root.setProperty('--soft', 'color-mix(in srgb, ' + c + ' 12%, white)');
      root.setProperty('--hero', 'linear-gradient(135deg,' + c + ' 0%, color-mix(in srgb, ' + c + ' 55%, black) 100%)');
    }
    document.title = 'Rendez-vous · ' + d.shop.name;
    render();
  }).catch(function(e){
    app.innerHTML = '<div class="empty"><h2>Réservation indisponible</h2><p>' + esc(e.message) + '</p></div>';
  });
})();
</script>
</body>
</html>`;
}
