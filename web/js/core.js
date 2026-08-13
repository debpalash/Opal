'use strict';
const BASE = location.origin.startsWith('http') ? location.origin : 'http://' + location.hostname + ':41595';
let TOKEN = localStorage.getItem('opal_token') || '';

// The desktop opens first-run setup with the one-time capability in a URL
// fragment. Fragments never reach the HTTP server or access logs. Capture it,
// then scrub it from browser history before any navigation or external load.
let SETUP_TOKEN = '';
if (location.hash.startsWith('#setup=')) {
  try {
    const candidate = decodeURIComponent(location.hash.slice('#setup='.length));
    if (/^[0-9a-f]{64}$/.test(candidate)) SETUP_TOKEN = candidate;
  } catch {}
  history.replaceState(null, '', location.pathname + location.search);
}

const $ = id => document.getElementById(id);
function setNetworkState(state){
  const el = $('network-status');
  if (state === true) { el.classList.remove('show'); el.textContent = ''; return; }
  el.textContent = state === 'reconnecting' ? 'Reconnecting…' : 'Offline · navigation only';
  el.classList.add('show');
  if (state === false) $('conn-dot').classList.remove('on');
}
const networkFetch = (url, options) => fetch(url, options).then(
  response => { setNetworkState(true); return response; },
  error => { setNetworkState(false); throw error; },
);
const api = (path) => networkFetch(BASE + '/api' + path, { headers: TOKEN ? { Authorization: 'Bearer ' + TOKEN } : {} })
  .then(r => { if (r.status === 401) { unpair(); throw 0; } return r.json(); });
const apiMutation = (path) => networkFetch(BASE + '/api' + path, {
  method: 'POST', headers: TOKEN ? { Authorization: 'Bearer ' + TOKEN } : {},
}).then(async r => {
  if (r.status === 401) { unpair(); throw new Error('Signed out'); }
  const data = await r.json().catch(() => ({}));
  if (!r.ok || data.ok === false) throw new Error(data.error || 'Request failed');
  return data;
});
// Per-container cache of the last innerHTML we assigned. Renderers that poll
// (search/torrents/anime/podcast/rss) build the HTML string, then only touch
// the DOM when it actually changed — avoids re-parsing identical markup and
// re-requesting <img> sources every tick.
const lastHtml = {};
let currentPage = '';

// ── Installable/offline-safe shell ──
// The service worker caches public UI assets only. Authenticated JSON, media,
// and credentials remain network-only by design (see service-worker.js).
let installPrompt = null;
const installedPwa = matchMedia('(display-mode: standalone)').matches || window.navigator.standalone === true;
function showInstallState(message, canInstall){
  $('pwa-hint').textContent = message;
  $('pwa-install').hidden = !canInstall;
}
window.addEventListener('beforeinstallprompt', event => {
  event.preventDefault(); installPrompt = event;
  showInstallState('Install Opal for a full-screen app and offline-safe navigation.', true);
});
window.addEventListener('appinstalled', () => {
  installPrompt = null; showInstallState('Installed · reconnect to your Opal server for media and account data.', false);
});
$('pwa-install').onclick = async () => {
  if (!installPrompt) return;
  await installPrompt.prompt();
  await installPrompt.userChoice;
  installPrompt = null; $('pwa-install').hidden = true;
};
if (installedPwa) {
  showInstallState('Installed · reconnect to your Opal server for media and account data.', false);
} else if ('serviceWorker' in navigator && window.isSecureContext) {
  navigator.serviceWorker.register('/service-worker.js').then(() => {
    if (!installPrompt) showInstallState('Offline-safe navigation is ready. Install from your browser menu.', false);
  }).catch(() => showInstallState('Offline shell setup failed. Reload while connected to retry.', false));
} else {
  showInstallState('Installation needs HTTPS (or localhost); normal browser access still works.', false);
}
if (!navigator.onLine) setNetworkState(false);
window.addEventListener('offline', () => setNetworkState(false));
window.addEventListener('online', () => {
  setNetworkState('reconnecting');
  if (TOKEN) { poll(); if (currentPage) loadPage(currentPage); }
});

// ── Account auth (identical for headless + desktop-remote; no pairing code) ──
// First run (no accounts) → create the admin; otherwise → sign in. The token is
// a session token stored like before, so the rest of the app is unchanged.
let HOSTED = false;
let authMode = 'login'; // 'register' on first-run

function paired(){
  $('pair-screen').style.display='none';
  api('/host').then(h => {
    HOSTED = !!h.headless;
    // Hosted box has no desktop player chrome to control.
    if (HOSTED) $('np-quick').style.display = 'none';
  }).catch(()=>{});
  setPlayHere(PLAY_HERE);
  // Headless has no desktop player to hand off to, so the choice is moot.
  if (HOSTED) $('dest-row').style.display = 'none';
  loadCalendar();
  startStatus();
}

// Sign out — also the 401 handler in api(). Revokes the session server-side.
function unpair(){
  const t = TOKEN;
  TOKEN=''; localStorage.removeItem('opal_token');
  if (t) fetch(BASE + '/api/auth/logout', { method:'POST', headers:{ Authorization:'Bearer '+t } }).catch(()=>{});
  showAuth();
}

async function showAuth(){
  $('pair-screen').style.display='flex';
  $('pair-err').textContent='';
  try {
    const d = await (await fetch(BASE + '/api/auth/status')).json();
    authMode = d.needs_setup ? 'register' : 'login';
  } catch { authMode = 'login'; }
  const reg = authMode === 'register';
  $('auth-title').textContent = reg ? 'Welcome to Opal' : 'Sign in';
  $('auth-sub').textContent = reg ? 'Create the admin account using the one-time setup code from this Opal device.' : 'Enter your Opal account to continue.';
  $('auth-pass2').style.display = reg ? '' : 'none';
  $('auth-setup').style.display = reg ? '' : 'none';
  if (reg && SETUP_TOKEN) $('auth-setup').value = SETUP_TOKEN;
  $('auth-pass').setAttribute('autocomplete', reg ? 'new-password' : 'current-password');
  $('pair-btn').textContent = reg ? 'Create account' : 'Sign in';
  $('auth-user').value=''; $('auth-pass').value=''; $('auth-pass2').value='';
  setTimeout(() => $('auth-user').focus(), 50);
}

async function submitAuth(){
  const u = $('auth-user').value.trim(), p = $('auth-pass').value, reg = authMode === 'register';
  if (!u || !p) { $('pair-err').textContent = 'Enter a username and password.'; return; }
  if (reg && p.length < 8) { $('pair-err').textContent = 'Password must be at least 8 characters.'; return; }
  if (reg && p !== $('auth-pass2').value) { $('pair-err').textContent = 'Passwords don’t match.'; return; }
  const setup = reg ? $('auth-setup').value.trim() : '';
  if (reg && !/^[0-9a-f]{64}$/.test(setup)) { $('pair-err').textContent = 'Enter the 64-character lowercase setup code shown by Opal.'; return; }
  $('pair-err').textContent=''; $('pair-btn').disabled = true;
  try {
    const body = 'username=' + encodeURIComponent(u) + '&password=' + encodeURIComponent(p);
    const headers = { 'Content-Type':'application/x-www-form-urlencoded' };
    if (reg) headers['X-Opal-Setup-Token'] = setup;
    const r = await fetch(BASE + '/api/auth/' + (reg ? 'register' : 'login'),
      { method:'POST', headers, body });
    const d = await r.json().catch(()=>({}));
    if (r.ok && d.token) { SETUP_TOKEN=''; $('auth-setup').value=''; TOKEN = d.token; localStorage.setItem('opal_token', TOKEN); paired(); }
    else $('pair-err').textContent = r.status === 401 ? 'Wrong username or password.' : (d.error || 'Something went wrong.');
  } catch { $('pair-err').textContent = 'Can’t reach Opal — is the server running?'; }
  finally { $('pair-btn').disabled = false; }
}

$('pair-btn').onclick = submitAuth;
$('auth-user').addEventListener('keydown', e => { if (e.key === 'Enter') { authMode === 'register' ? $('auth-pass').focus() : submitAuth(); } });
$('auth-pass').addEventListener('keydown', e => { if (e.key === 'Enter') submitAuth(); });
$('auth-pass2').addEventListener('keydown', e => { if (e.key === 'Enter') authMode === 'register' ? $('auth-setup').focus() : submitAuth(); });
$('auth-setup').addEventListener('keydown', e => { if (e.key === 'Enter') submitAuth(); });

// ── Adaptive shell + deep-linked pages ──
const appNav = $('app-nav'), navPanel = $('nav-more-panel'), navMore = $('nav-more');
const navPageButtons = [...document.querySelectorAll('#app-nav button[data-page],#nav-more-panel button[data-page]')];
const primaryPages = new Set(['home', 'browse', 'search', 'np']);
const mobileNav = matchMedia('(max-width:899px)');
let navReturnFocus = null;

function closeMore(restoreFocus){
  const wasOpen = appNav.classList.contains('more-open');
  appNav.classList.remove('more-open');
  document.body.classList.remove('nav-open');
  navMore.setAttribute('aria-expanded', 'false');
  navPanel.setAttribute('aria-hidden', mobileNav.matches ? 'true' : 'false');
  navPanel.toggleAttribute('inert', mobileNav.matches);
  $('main-content').removeAttribute('inert');
  if (wasOpen && restoreFocus && navReturnFocus) navReturnFocus.focus();
}
function syncNavClearance(){
  if (!mobileNav.matches) { navPanel.style.removeProperty('--nav-clearance'); return; }
  // One batched interaction-time read: this naturally includes safe-area
  // padding and any font / webview metric differences in the bottom bar.
  const clearance = Math.ceil(appNav.getBoundingClientRect().height) + 8;
  navPanel.style.setProperty('--nav-clearance', clearance + 'px');
}
function openMore(){
  if (!mobileNav.matches) return;
  syncNavClearance();
  navReturnFocus = document.activeElement;
  appNav.classList.add('more-open');
  document.body.classList.add('nav-open');
  navMore.setAttribute('aria-expanded', 'true');
  navPanel.setAttribute('aria-hidden', 'false');
  navPanel.removeAttribute('inert');
  $('main-content').setAttribute('inert', '');
  requestAnimationFrame(() => $('nav-close').focus());
}
function syncNavMode(){
  if (!mobileNav.matches) closeMore(false);
  syncNavClearance();
  navPanel.setAttribute('aria-hidden', mobileNav.matches && !appNav.classList.contains('more-open') ? 'true' : 'false');
  navPanel.toggleAttribute('inert', mobileNav.matches && !appNav.classList.contains('more-open'));
}
mobileNav.addEventListener?.('change', syncNavMode);
window.addEventListener('resize', syncNavClearance, { passive:true });
navMore.onclick = () => appNav.classList.contains('more-open') ? closeMore(true) : openMore();
$('nav-close').onclick = () => closeMore(true);
$('nav-scrim').onclick = () => closeMore(true);

function stopPageWork(){
  // Leaving the current tab: stop any settle watchers still polling a now-hidden
  // page (they otherwise keep hitting the server for ~36s). clearInterval on a
  // null/stale handle is a harmless no-op.
  clearInterval(searchWatch); clearInterval(animeWatch); clearInterval(podWatch); clearInterval(jfWatch); clearInterval(ytWatch); clearInterval(aiWatch); clearInterval(muWatch); clearInterval(raWatch);
  clearInterval(cxWatch); clearInterval(cxPages); clearInterval(nvWatch); clearInterval(drWatch);
  clearInterval(vnWatch); clearInterval(absWatch); clearInterval(opWatch); clearInterval(plWatch);
  clearTimeout(recWatch); clearTimeout(castWatch); clearTimeout(partyWatch); clearTimeout(playerToolsWatch);
  if (currentPage === 'np') { setCastOpen(false); setPlayerToolsOpen(false); }
  jfLibTries = 0;
}

function loadPage(page){
  if (page === 'act') loadActivity();
  if (page === 'browse') loadBrowse();
  if (page === 'home') loadHome();
  if (page === 'watch') loadWatch();
  if (page === 'setup') loadSetup();
  if (page === 'tv') loadTv();
  if (page === 'ai') loadAi();
  if (page === 'music') loadMusic();
  if (page === 'radio') loadRadio();
  if (page === 'anime') loadAnime();
  if (page === 'podcasts') loadPodcasts();
  if (page === 'jf') loadJellyfin();
  if (page === 'rss') loadRss();
  if (page === 'comics') loadComics();
  if (page === 'novels') loadNovels();
  if (page === 'drama') loadDrama();
  if (page === 'vndb') loadVndb();
  if (page === 'abs') loadAbs();
  if (page === 'opds') loadOpds();
  if (page === 'plex') loadPlex();
  if (page === 'logs') loadLogs();
}

function openPage(page, opts){
  const o = opts || {};
  let b = navPageButtons.find(x => x.dataset.page === page);
  if (!b) { page = 'home'; b = navPageButtons.find(x => x.dataset.page === page); }
  closeMore(false);
  if (page === currentPage) return;
  stopPageWork();
  currentPage = page;
  navPageButtons.forEach(x => {
    const on = x === b;
    x.classList.toggle('on', on);
    if (on) x.setAttribute('aria-current', 'page'); else x.removeAttribute('aria-current');
  });
  navMore.classList.toggle('has-active', !primaryPages.has(page));
  document.querySelectorAll('.page').forEach(p => p.classList.toggle('on', p.id === 'page-' + page));
  const label = b.textContent.trim();
  document.title = label + ' — Opal';
  if (o.history !== false && location.hash !== '#' + page) {
    const method = o.replace ? 'replaceState' : 'pushState';
    history[method](null, '', '#' + page);
  }
  window.scrollTo(0, 0);
  if (o.focus) $('main-content').focus({ preventScroll:true });
  loadPage(page);
}

navPageButtons.forEach(b => b.onclick = () => openPage(b.dataset.page, { focus:true }));
const routePage = () => decodeURIComponent(location.hash.slice(1));
const followRoute = () => openPage(routePage(), { history:false });
window.addEventListener('popstate', followRoute);
window.addEventListener('hashchange', followRoute);

// Directional focus for TVs, gamepads that emit arrow keys, and keyboards.
// Geometry is evaluated only on a key press; dynamically-rendered controls
// participate without every page maintaining its own focus map.
const spatialSelector = 'button:not([disabled]),a[href],input:not([disabled]),select:not([disabled]),textarea:not([disabled]),[tabindex]:not([tabindex="-1"])';
function spatialCandidates(){
  return [...document.querySelectorAll(spatialSelector)].filter(el => {
    if (el.closest('[inert],[aria-hidden="true"]')) return false;
    const r = el.getBoundingClientRect(), s = getComputedStyle(el);
    return r.width > 0 && r.height > 0 && r.bottom > 0 && r.right > 0
      && r.top < innerHeight && r.left < innerWidth && s.visibility !== 'hidden' && s.display !== 'none';
  });
}
function moveSpatialFocus(key){
  const candidates = spatialCandidates(); if (!candidates.length) return false;
  let current = document.activeElement;
  if (!candidates.includes(current)) {
    current = document.querySelector('#app-nav [aria-current="page"]') || candidates[0];
    current.focus(); return true;
  }
  const a = current.getBoundingClientRect(), ax = a.left + a.width / 2, ay = a.top + a.height / 2;
  const horizontal = key === 'ArrowLeft' || key === 'ArrowRight';
  const sign = key === 'ArrowLeft' || key === 'ArrowUp' ? -1 : 1;
  let best = null, bestScore = Infinity;
  for (const el of candidates) {
    if (el === current) continue;
    const b = el.getBoundingClientRect(), dx = b.left + b.width / 2 - ax, dy = b.top + b.height / 2 - ay;
    const primary = (horizontal ? dx : dy) * sign;
    if (primary <= 2) continue;
    const cross = Math.abs(horizontal ? dy : dx);
    const overlap = horizontal
      ? Math.max(0, Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top))
      : Math.max(0, Math.min(a.right, b.right) - Math.max(a.left, b.left));
    const score = primary * 10 + cross * (overlap > 0 ? 1 : 3);
    if (score < bestScore) { best = el; bestScore = score; }
  }
  if (!best) return false;
  best.focus({preventScroll:true});
  best.scrollIntoView({block:'nearest', inline:'nearest'});
  return true;
}
document.addEventListener('keydown', e => {
  if (e.key === 'Escape' && appNav.classList.contains('more-open')) { e.preventDefault(); closeMore(true); return; }
  if (e.key === 'Escape' && $('show-page').classList.contains('on')) { e.preventDefault(); $('show-back').click(); return; }
  if (e.key === 'Escape' && $('player').classList.contains('on')) { e.preventDefault(); $('player-close').click(); return; }
  if (e.key === 'Escape' && $('yt-embed').classList.contains('on')) { e.preventDefault(); $('yt-embed-close').click(); return; }
  if (appNav.classList.contains('more-open') && e.key === 'Tab') {
    const focusable = [...navPanel.querySelectorAll('button:not([disabled])')];
    if (!focusable.length) return;
    const first = focusable[0], last = focusable[focusable.length - 1];
    if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
    else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
    return;
  }
  const typing = /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement?.tagName || '')
    || document.activeElement?.isContentEditable;
  if (!typing && !e.altKey && !e.ctrlKey && !e.metaKey && /^Arrow(Left|Right|Up|Down)$/.test(e.key)) {
    if (moveSpatialFocus(e.key)) e.preventDefault();
    return;
  }
  if (!typing && (e.key === '/' || ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k'))) {
    e.preventDefault(); openPage('search', { focus:false }); $('q').focus();
  }
});
