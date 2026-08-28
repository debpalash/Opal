'use strict';

// ── Hosted inline player ──
function openPlayer(rel){
  const v = $('video');
  $('player-title').textContent = rel.split('/').pop();
  v.src = `${BASE}/stream?file=${encodeURIComponent(rel)}`;
  // Sidecar subs: same name, .srt/.vtt
  [...v.querySelectorAll('track')].forEach(tr => tr.remove());
  const base = rel.replace(/\.[^.]+$/, '');
  const tr = document.createElement('track');
  tr.kind = 'subtitles'; tr.label = 'Subtitles'; tr.default = true;
  tr.src = `${BASE}/vtt?file=${encodeURIComponent(base + '.srt')}`;
  v.appendChild(tr);
  $('player').classList.add('on');
}
$('player-close').onclick = () => {
  const v = $('video');
  // Tear down the HLS shim if one is attached, or it keeps fetching segments
  // in the background after the player is closed.
  try { if (v._hls) { v._hls.destroy(); v._hls = null; } } catch {}
  v.pause(); v.removeAttribute('src'); v.load();
  $('player').classList.remove('on');
};

// ── Setup (first-run from the browser — essential for hosted mode) ──
async function loadSetup(){
  try {
    const d = await api('/setup');
    $('setup-sources').textContent = d.has_sources ? 'Sources installed ✓' : 'No sources — search returns nothing until you install some.';
    $('setup-install').disabled = !!d.has_sources;
    $('setup-install').textContent = d.has_sources ? 'Starter sources installed' : 'Install starter sources';
    $('setup-tmdb').textContent = d.has_tmdb ? 'TMDB key set ✓' : 'Powers posters, seasons, trending.';
  } catch {}
  loadSources();
  loadSettings();
  loadPlugins();
  loadTrakt();
  loadSuwayomi();
  loadAbout();
  loadLiveTvSources();
  loadWebUi();
  foldSetup();
  loadParty();
  loadAccess();
}

// ── Playback destination ("Play here" vs the desktop player) ──
// The browser used to be a remote control whenever the desktop app was up:
// every play handed the item to mpv and the page showed nothing. PLAY_HERE
// makes the page a real player when the media is one a browser can decode.
//
// Mirrors services/playback_target_pure.zig — keep the two tables in step.
// Three outcomes, not two: the server transcodes (ffmpeg -> fragmented MP4 at
// /transcode), so an MKV or an H.265 mp4 is a `transcode` candidate rather than
// a refusal. `unsupported` is only for what nothing can play. This page used to
// call every one of those `unsupported`, which meant "Play here" turned away
// almost every real release while a working transcoder sat unused.
let PLAY_HERE = localStorage.getItem('opal_play_here') === '1';
// Set from /api/transcode/available at load: without ffmpeg on the server the
// transcode branch has to degrade to the honest message instead of pointing
// <video> at a 501.
let TRANSCODE_OK = false;
const DIRECT_EXT = ['mp4','m4v','webm','ogv','mp3','m4a','aac','oga','ogg','opus','wav','flac'];
const TRANSCODE_EXT = ['mkv','avi','wmv','flv','vob','rmvb','asf','mpg','mpeg','m2ts','mts','ts','divx','3gp'];
// A disc image is not a stream — ffmpeg cannot read one either, so offering to
// transcode it would fail only after the user had waited.
const NOPLAY_EXT = ['iso'];
const BAD_CODEC = ['x265','h265','hevc','x266','av1','vc1','mpeg2','dts','truehd','eac3','ac3','atmos'];
function classifyPlayable(name){
  if (!name) return 'unsupported';
  const clean = String(name).split(/[?#]/)[0].toLowerCase();
  const ext = clean.includes('.') ? clean.slice(clean.lastIndexOf('.') + 1) : '';
  if (ext === 'm3u8') return 'hls';
  if (NOPLAY_EXT.includes(ext)) return 'unsupported';
  if (TRANSCODE_EXT.includes(ext)) return 'transcode';
  if (DIRECT_EXT.includes(ext))
    return BAD_CODEC.some(m => String(name).toLowerCase().includes(m)) ? 'transcode' : 'direct';
  return /^https?:\/\//i.test(name) ? 'direct' : 'unsupported';
}
function playabilityReason(p){
  if (p === 'hls') return "Live streams play in Safari; other browsers need the desktop app.";
  if (p === 'transcode') return TRANSCODE_OK
    ? "Only files in your library can be transcoded — open this one on the desktop."
    : "This format needs transcoding — install ffmpeg on the Opal machine, or open it on the desktop.";
  return "This format can't play in a browser — open it on the desktop.";
}
// Safari (and iOS) play HLS natively; nothing else does without an MSE shim,
// which we do not bundle.
const NATIVE_HLS = (() => { const v = document.createElement('video');
  return !!(v.canPlayType('application/vnd.apple.mpegurl') || v.canPlayType('application/x-mpegURL')); })();

/// The one entry point every play button goes through.
/// `url` must already be browser-reachable (/stream?file=… or a direct URL).
/// `fallback` runs when we cannot play here (or the user chose the desktop).
// Browser media requests carry the HttpOnly session cookie automatically.
function streamUrl(rel){
  return BASE + '/stream?file=' + encodeURIComponent(rel);
}
function dispatchPlay(url, title, fallback, classifyName){
  if (!PLAY_HERE) return fallback ? fallback() : undefined;
  // Classify the MEDIA NAME, not the URL that wraps it. A /stream URL carries
  // the real filename in a query param, and the parser strips at '?' — so
  // classifying the URL saw "/stream" with no extension, fell through to the
  // "bare http URL" rule, and happily handed <video> an MKV.
  const cls = classifyPlayable(classifyName || url);
  if (cls === 'direct') return openStreamUrl(url, title);
  if (cls === 'hls' && (NATIVE_HLS || window.Hls)) return openHls(url, title);
  if (cls === 'transcode') {
    // The transcoder reads a file from the library by relative path, so it can
    // only help when this play came from a /stream URL — a remote http URL is
    // not something the server has on disk.
    const rel = relFromStreamUrl(url);
    if (TRANSCODE_OK && rel) return openTranscode(rel, title);
  }
  toast(playabilityReason(cls));
  if (fallback) fallback();
}

/// The library-relative path inside a /stream URL, or '' for anything else.
function relFromStreamUrl(url){
  try {
    const u = new URL(url, location.href);
    if (!u.pathname.endsWith('/stream')) return '';
    return u.searchParams.get('file') || '';
  } catch { return ''; }
}

function transcodeUrl(rel, startSecs){
  return BASE + '/transcode?file=' + encodeURIComponent(rel)
       + (startSecs ? '&start=' + Math.floor(startSecs) : '');
}

/// Play a library file through the server-side transcoder.
///
/// The output is a live fragmented MP4: it has no length and no Range support,
/// so <video> cannot seek it the normal way — currentTime is always relative to
/// wherever this encode began. Seeking therefore RESTARTS the encode at the new
/// offset, and `_tcBase` carries how far in that restart was so the UI can show
/// a real position. Without this the scrubber looks broken: it snaps back to 0
/// and refuses to move.
function openTranscode(rel, title, startSecs){
  const v = $('video');
  const base = Math.max(0, Math.floor(startSecs || 0));
  $('player-title').textContent = (title || '') + ' — transcoding';
  [...v.querySelectorAll('track')].forEach(tr => tr.remove());
  try { if (v._hls) { v._hls.destroy(); v._hls = null; } } catch {}
  v._tcRel = rel; v._tcTitle = title || ''; v._tcBase = base;
  v.src = transcodeUrl(rel, base);
  $('player').classList.add('on');
  v.onerror = () => {
    $('player-title').textContent = (title || '') + ' — transcode failed (is ffmpeg installed?)';
  };
  v.play().catch(()=>{});
}

// Seek on a transcoded stream = restart the encode at the target offset.
// Guarded against the seek that our own restart triggers (`_tcSeeking`), which
// would otherwise loop: set src -> seeked -> set src -> ...
(function wireTranscodeSeek(){
  const v = $('video');
  if (!v) return;
  v.addEventListener('seeking', () => {
    if (!v._tcRel || v._tcSeeking) return;
    const target = (v._tcBase || 0) + v.currentTime;
    // A seek inside what the current encode already produced is real seeking —
    // let the element do it rather than paying for a restart.
    if (v.buffered.length && v.currentTime <= v.buffered.end(v.buffered.length - 1)) return;
    v._tcSeeking = true;
    openTranscode(v._tcRel, v._tcTitle, target);
    setTimeout(() => { v._tcSeeking = false; }, 500);
  });
})();

// HLS. Safari demuxes it natively; everything else needs an MSE shim.
// hls.js is vendored under web/vendor/ and loaded by a script tag in the head
// of this file — kept as a separate file, not inlined, because it is 543KB
// uncompressed. Deleting that file degrades this to the honest "needs the
// desktop app" message rather than breaking the page, because the call site
// tests window.Hls first.
function openHls(url, title){
  if (NATIVE_HLS) return openStreamUrl(url, title);
  const v = $('video');
  $('player-title').textContent = title || '';
  [...v.querySelectorAll('track')].forEach(tr => tr.remove());
  try { if (v._hls) { v._hls.destroy(); v._hls = null; } } catch {}
  const h = new window.Hls({ enableWorker: true });
  v._hls = h;
  h.on(window.Hls.Events.ERROR, (_e, data) => {
    if (data && data.fatal) $('player-title').textContent = (title || '') + ' — stream failed';
  });
  h.loadSource(url);
  h.attachMedia(v);
  $('player').classList.add('on');
  v.play().catch(()=>{});
}
function toast(msg){
  let t = $('pt-toast');
  if (!t) {
    t = document.createElement('div'); t.id = 'pt-toast';
    t.setAttribute('role', 'status'); t.setAttribute('aria-live', 'polite');
    document.body.appendChild(t);
  }
  t.textContent = msg; t.className = 'on';
  clearTimeout(toast._h); toast._h = setTimeout(() => t.className = '', 4000);
}
$('dest-toggle').onclick = () => setPlayHere(!PLAY_HERE);
// Wrapping the credential fields in <form> gives password managers something
// to attach to and silences the browser warning; these forward Enter to the
// existing button handlers rather than ever navigating.
[['auth-form', 'pair-btn'], ['acc-pw-form', 'acc-pw-save']].forEach(([f, b]) => {
  const form = $(f);
  if (form) form.addEventListener('submit', e => { e.preventDefault(); $(b).click(); });
});

function setPlayHere(on){
  PLAY_HERE = !!on;
  localStorage.setItem('opal_play_here', PLAY_HERE ? '1' : '0');
  document.querySelectorAll('.dest-btn').forEach(b =>
    b.textContent = PLAY_HERE ? 'Playing here' : 'Playing on desktop');
}

// Is the server able to transcode? Asked once, and only used to choose between
// transcoding and an honest message — never to hide the toggle, since direct
// play works with or without ffmpeg.
api('/transcode/available')
  .then(r => { TRANSCODE_OK = !!(r && r.available); })
  .catch(() => { TRANSCODE_OK = false; });

// ── Home hub ──
// Composes /api/home (counts + continue) with the pre-existing /calendar rail
// rather than re-deriving either. "Continue" comes back in the library's own
// order, so Home and Watching agree on what's next.
let recWatch = null;
function renderRecommendations(d){
  const items = d.items || [];
  $('home-recs-refresh').disabled = !!d.loading;
  $('home-recs-refresh').textContent = d.loading ? 'Refreshing…' : 'Refresh';
  $('home-recs').setAttribute('aria-busy', d.loading ? 'true' : 'false');
  $('home-recs-status').textContent = d.loading
    ? 'Building recommendations.'
    : items.length ? `${items.length} recommendations ready.` : 'No recommendations yet.';
  $('home-recs').innerHTML = items.map((r, i) => `
    <article class="recommend">
      <div class="t">${esc(r.title)}</div>
      <div class="why">${esc(r.reason || 'Recommended from your watch history')}</div>
      <button class="find" data-i="${i}">Find &amp; play</button>
    </article>`).join('') || (d.loading
      ? '<div class="empty"><span class="spin"></span> Building recommendations…</div>'
      : '<div class="empty">Watch a few titles to unlock recommendations.</div>');
  $('home-recs').querySelectorAll('.find').forEach(b => b.onclick = () => {
    const r = items[+b.dataset.i];
    if (r?.title) prefillSearch(normQuery(r.title));
  });
}
async function loadRecommendations(refresh){
  clearTimeout(recWatch);
  try {
    const d = await api('/recommendations' + (refresh ? '?refresh=1' : ''));
    renderRecommendations(d);
    if (d.loading) recWatch = setTimeout(() => loadRecommendations(false), 900);
  } catch {
    $('home-recs-refresh').disabled = false;
    $('home-recs-refresh').textContent = 'Retry';
    $('home-recs').setAttribute('aria-busy', 'false');
    $('home-recs-status').textContent = 'Recommendations are unavailable.';
    $('home-recs').innerHTML = '<div class="empty">Recommendations are unavailable.</div>';
  }
}
$('home-recs-refresh').onclick = () => loadRecommendations(true);

async function loadHome(){
  loadRecommendations(false);
  try {
    const d = await api('/home');
    $('home-metrics').innerHTML = [
      ['Tracked', d.tracked], ['Watching', d.watching],
      ['Caught up', d.caught_up], ['Unstarted', d.unstarted], ['Torrents', d.torrents],
    ].map(([k, v]) => `<div class="metric"><b>${v}</b><span>${k}</span></div>`).join('');
    const cont = d['continue'] || [];
    $('home-continue').innerHTML = cont.map((r, i) => `
      <div class="result" data-i="${i}">
        ${r.poster ? `<img class="poster" src="${esc(r.poster)}" loading="lazy" alt="">` : ''}
        <div class="t">${esc(r.name)}</div>
        <div class="m"><span class="src">${esc(r.kind)}</span>
          ${r.has_next ? `<span>S${String(r.next_season).padStart(2,'0')}E${String(r.next_episode).padStart(2,'0')} next</span>` : '<span>in progress</span>'}</div>
      </div>`).join('') || '<div class="empty">Nothing in progress</div>';
    $('home-continue').querySelectorAll('.result').forEach(el => el.onclick = () => {
      const r = cont[+el.dataset.i];
      if (r && r.kind === 'tv' && r.tmdb_id) openShow(r.tmdb_id, r.name);
      else prefillSearch(normQuery(r.name));
    });
  } catch { $('home-metrics').innerHTML = '<div class="empty">Could not load</div>'; }
  loadCalendarInto('home-cal');
}
