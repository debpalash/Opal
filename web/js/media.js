'use strict';

// ── Anime ──
// Server routes are async: /anime/search & /anime/episodes trigger background
// work and return {ok:true}; poll GET /anime for {results,episodes,selected,loading}.
let animeWatch = null;
async function loadAnime(){
  try { renderAnime(await api('/anime')); } catch {}
}
function renderAnime(d){ renderAnimeResults(d.results || []); renderAnimeEpisodes(d.episodes || []); }
$('anime-go').onclick = () => runAnime();
$('anime-q').addEventListener('keydown', e => { if (e.key === 'Enter') { runAnime(); $('anime-q').blur(); } });
function runAnime(){
  const q = $('anime-q').value.trim(); if (!q) return;
  $('anime-hint').innerHTML = '<span class="spin"></span> Searching anime…';
  $('anime-results').innerHTML = ''; lastHtml.animeResults = ''; $('anime-episodes').innerHTML = '';
  api('/anime/search?q=' + encodeURIComponent(q)).catch(()=>{});
  clearInterval(animeWatch);
  let ticks = 0;
  animeWatch = setInterval(async () => {
    ticks++;
    try {
      const d = await api('/anime');
      renderAnimeResults(d.results || []);
      if ((!d.loading && ticks > 2) || ticks > 40) {
        clearInterval(animeWatch);
        $('anime-hint').textContent = (d.results || []).length + ' titles — tap one for episodes.';
      }
    } catch { clearInterval(animeWatch); }
  }, 900);
}
function renderAnimeResults(rs){
  const html = rs.map((r, i) => `
    <div class="result">
      <div class="t">${esc(r.name)}</div>
      <div class="m"><span class="src">${r.episodes || 0} eps</span>
        <button class="play" data-idx="${i}">Episodes ⭢</button></div>
    </div>`).join('') || '<div class="empty">No results yet</div>';
  if (html === lastHtml.animeResults) return;
  lastHtml.animeResults = html;
  $('anime-results').innerHTML = html;
  $('anime-results').querySelectorAll('.play').forEach(b => b.onclick = () => loadAnimeEpisodes(+b.dataset.idx));
}
function loadAnimeEpisodes(idx){
  $('anime-episodes').innerHTML = '<div class="empty"><span class="spin"></span></div>';
  api('/anime/episodes?idx=' + idx).catch(()=>{});
  let tries = 0;
  const t = setInterval(async () => {
    tries++;
    try {
      const d = await api('/anime');
      if ((d.episodes || []).length || tries > 15) { clearInterval(t); renderAnimeEpisodes(d.episodes || []); }
    } catch { clearInterval(t); }
  }, 700);
}
function renderAnimeEpisodes(eps){
  $('anime-episodes').innerHTML = eps.length
    ? '<div class="sect">Episodes</div><div class="ep-grid">' +
      eps.map(e => `<button class="ep-btn" data-ep="${esc(String(e))}">${esc(String(e))}</button>`).join('') + '</div>'
    : '';
  $('anime-episodes').querySelectorAll('.ep-btn').forEach(b => b.onclick = () => {
    api('/anime/play?ep=' + encodeURIComponent(b.dataset.ep)).catch(()=>{});
    b.textContent = '▶';
  });
}

// ── Music ──
// /music/search kicks off an async fetch; poll GET /music for {loading,songs}.
// Each song carries a direct stream url: hosted plays it in the browser,
// companion hands the index to the desktop player.
let muWatch = null;
function loadMusic(){ api('/music').then(d => renderMusic(d.songs || [])).catch(()=>{}); }
$('mu-go').onclick = () => runMusic();
$('mu-q').addEventListener('keydown', e => { if (e.key === 'Enter') { runMusic(); $('mu-q').blur(); } });
function runMusic(){
  const q = $('mu-q').value.trim(); if (!q) return;
  $('mu-hint').innerHTML = '<span class="spin"></span> Searching music…';
  $('mu-results').innerHTML = ''; lastHtml.music = '';
  api('/music/search?q=' + encodeURIComponent(q)).catch(()=>{});
  clearInterval(muWatch);
  let ticks = 0;
  muWatch = setInterval(async () => {
    ticks++;
    try {
      const d = await api('/music');
      renderMusic(d.songs || []);
      if ((!d.loading && ticks > 2) || ticks > 40) {
        clearInterval(muWatch);
        $('mu-hint').textContent = (d.songs || []).length + ' songs.';
      }
    } catch { clearInterval(muWatch); }
  }, 900);
}
function renderMusic(songs){
  const html = songs.map((s, i) => `
    <div class="result">
      <div class="t">${esc(s.title)}</div>
      <div class="m"><span class="src">${esc(s.artist || '')}</span>
        <button class="play" data-i="${i}" data-url="${encodeURIComponent(s.url || '')}">Play</button></div>
    </div>`).join('') || '<div class="empty">No songs yet</div>';
  if (html === lastHtml.music) return;
  lastHtml.music = html;
  $('mu-results').innerHTML = html;
  $('mu-results').querySelectorAll('.play').forEach(b => b.onclick = () => {
    const u = decodeURIComponent(b.dataset.url || '');
    const t = b.parentElement.parentElement.querySelector('.t').textContent;
    if (HOSTED && u) return openStreamUrl(u, t);
    dispatchPlay(u, t, () => { api('/music/play?idx=' + b.dataset.i).catch(()=>{}); b.textContent = 'Sent ✓'; });
  });
}

// ── Radio ──
// GET /radio seeds the popular list on first open; /radio/search filters.
let raWatch = null;
// Parity-tier-2 poll handles. `cxPages` is separate from `cxWatch`: the reader
// keeps polling page progress while the search listing sits idle behind it.
let cxWatch = null, cxPages = null, nvWatch = null, drWatch = null, vnWatch = null;
let absWatch = null, opWatch = null, plWatch = null;
// Which search row the open novel came from — /novels has no server-side back.
let novelIdx = 0;

// ── Comics: search → reader ──
// Pages come from /api/comics/page?i=N, which takes the token in the query
// because <img> cannot send an Authorization header (same as /poster).
function loadComics(){ pollComics(); }
function runComics(){
  const q = $('cx-q').value.trim(); if (!q) return;
  $('cx-hint').innerHTML = '<span class="spin"></span> Searching…';
  api('/comics/search?q=' + encodeURIComponent(q)).catch(()=>{});
  pollComics();
}
function pollComics(){
  clearInterval(cxWatch);
  let ticks = 0;
  cxWatch = setInterval(async () => {
    ticks++;
    try {
      const d = await api('/comics/results');
      renderComics(d.results || []);
      if ((!d.loading && ticks > 1) || ticks > 40) {
        clearInterval(cxWatch);
        $('cx-hint').textContent = (d.results || []).length + ' results.';
      }
    } catch { clearInterval(cxWatch); }
  }, 900);
}
function renderComics(rows){
  const html = rows.map((r, i) => `
    <div class="result">
      <div class="t">${esc(r.title)}</div>
      <div class="m"><button class="play" data-cx="${encodeURIComponent(r.url)}">Read</button></div>
    </div>`).join('') || '<div class="empty">No results yet</div>';
  if (html === lastHtml.comics) return;
  lastHtml.comics = html;
  $('cx-results').innerHTML = html;
  $('cx-results').querySelectorAll('button[data-cx]').forEach(b => {
    b.onclick = () => openComic(decodeURIComponent(b.dataset.cx));
  });
}
function openComic(url){
  api('/comics/load?url=' + encodeURIComponent(url)).catch(()=>{});
  $('cx-results').style.display = 'none';
  $('cx-reader').style.display = '';
  $('cx-progress').innerHTML = '<span class="spin"></span> Loading pages…';
  clearInterval(cxPages);
  let ticks = 0;
  cxPages = setInterval(async () => {
    ticks++;
    try {
      const d = await api('/comics');
      // `downloaded` is what says which indices answer 200 — pages arrive out of
      // order across 8 workers, so render only the contiguous prefix.
      $('cx-progress').textContent = d.pages
        ? `${d.title || 'Reading'} — ${d.downloaded}/${d.pages} pages`
        : 'Loading…';
      if (d.pages) {
        $('cx-pages').innerHTML = Array.from({ length: d.downloaded }, (_, i) =>
          `<img class="cx-page" loading="lazy" src="${BASE}/api/comics/page?i=${i}">`).join('');
      }
      if ((d.pages && d.downloaded >= d.pages) || ticks > 90) clearInterval(cxPages);
    } catch { clearInterval(cxPages); }
  }, 1200);
}
function closeComic(){
  clearInterval(cxPages);
  api('/comics/close').catch(()=>{});
  $('cx-pages').innerHTML = '';
  $('cx-reader').style.display = 'none';
  $('cx-results').style.display = '';
}

// ── Novels: search → chapters → reader (one poll drives all three views) ──
function loadNovels(){ pollNovels(); }
function runNovels(){
  const q = $('nv-q').value.trim(); if (!q) return;
  $('nv-hint').innerHTML = '<span class="spin"></span> Searching…';
  api('/novels/search?q=' + encodeURIComponent(q)).catch(()=>{});
  pollNovels();
}
function pollNovels(){
  clearInterval(nvWatch);
  let ticks = 0;
  nvWatch = setInterval(async () => {
    ticks++;
    try {
      const d = await api('/novels');
      renderNovels(d);
      const busy = d.loading || d.chapters_loading || d.text_loading;
      if ((!busy && ticks > 1) || ticks > 60) clearInterval(nvWatch);
    } catch { clearInterval(nvWatch); }
  }, 900);
}
function renderNovels(d){
  const busy = d.loading || d.chapters_loading || d.text_loading;
  $('nv-hint').innerHTML = busy ? '<span class="spin"></span> Loading…'
    : (d.error ? 'Fetch failed — try another source.' : (d.title || 'Search to begin.'));
  $('nv-crumbs').innerHTML = d.view === 'search' ? '' :
    `<button class="more" id="nv-back">‹ ${d.view === 'reader' ? 'Chapters' : 'Results'}</button>`;
  const back = $('nv-back');
  if (back) back.onclick = () => {
    // No server-side "back": re-entering the previous view is just re-issuing
    // the call that produced it.
    if (d.view === 'reader') api('/novels/open?idx=' + novelIdx).catch(()=>{});
    else api('/novels/search?q=' + encodeURIComponent($('nv-q').value.trim())).catch(()=>{});
    pollNovels();
  };
  if (d.view === 'reader') {
    $('nv-results').innerHTML = '';
    $('nv-text').textContent = d.text || '';
    $('nv-text').style.display = '';
    return;
  }
  $('nv-text').style.display = 'none';
  const rows = d.view === 'chapters' ? (d.chapters || []) : (d.results || []);
  const kind = d.view === 'chapters' ? 'chapter' : 'open';
  $('nv-results').innerHTML = rows.map((r, i) => `
    <div class="result">
      <div class="t">${esc(r.title)}</div>
      <div class="m"><button class="play" data-nv="${i}" data-kind="${kind}">${kind === 'open' ? 'Open' : 'Read'}</button></div>
    </div>`).join('') || '<div class="empty">Nothing here</div>';
  $('nv-results').querySelectorAll('button[data-nv]').forEach(b => {
    b.onclick = () => {
      const i = +b.dataset.nv;
      if (b.dataset.kind === 'open') novelIdx = i;
      api('/novels/' + (b.dataset.kind === 'open' ? 'open' : 'chapter') + '?idx=' + i).catch(()=>{});
      pollNovels();
    };
  });
}

// ── Drama (browse-only: drama.zig has no search entry point) ──
function loadDrama(){
  clearInterval(drWatch);
  let ticks = 0;
  drWatch = setInterval(async () => {
    ticks++;
    try {
      const d = await api('/drama');
      if (d.needs_tmdb_key) {
        clearInterval(drWatch);
        $('dr-hint').textContent = 'Add a TMDB API key in Setup — the drama catalog is TMDB-backed.';
        return;
      }
      renderDrama(d.results || []);
      $('dr-more').style.display = (d.results || []).length ? '' : 'none';
      if ((!d.loading && ticks > 1) || ticks > 40) {
        clearInterval(drWatch);
        $('dr-hint').textContent = (d.results || []).length + ' titles.';
      }
    } catch { clearInterval(drWatch); }
  }, 900);
}
function renderDrama(rows){
  const html = rows.map((r, i) => `
    <div class="result">
      <div class="t">${esc(r.name)}</div>
      <div class="m">
        ${r.year ? `<span class="src">${esc(r.year)}</span>` : ''}
        ${r.vote ? `<span>★ ${r.vote}</span>` : ''}
        <button class="play" data-i="${i}">Play</button></div>
    </div>`).join('') || '<div class="empty">No titles yet</div>';
  if (html === lastHtml.drama) return;
  lastHtml.drama = html;
  $('dr-results').innerHTML = html;
  $('dr-results').querySelectorAll('button[data-i]').forEach(b => {
    b.onclick = () => { api('/drama/play?idx=' + b.dataset.i).catch(()=>{}); b.textContent = 'Resolving…'; };
  });
}

// ── VNDB (catalog only — visual novels aren't launchable) ──
function loadVndb(){ pollVndb(); }
function runVndb(){
  const q = $('vn-q').value.trim(); if (!q) return;
  $('vn-hint').innerHTML = '<span class="spin"></span> Searching…';
  api('/vndb/search?q=' + encodeURIComponent(q)).catch(()=>{});
  pollVndb();
}
function pollVndb(){
  clearInterval(vnWatch);
  let ticks = 0;
  vnWatch = setInterval(async () => {
    ticks++;
    try {
      const d = await api('/vndb');
      renderVndb(d.results || []);
      if ((!d.loading && ticks > 1) || ticks > 40) {
        clearInterval(vnWatch);
        $('vn-hint').textContent = (d.results || []).length + (d.popular ? ' popular' : '') + ' titles.';
      }
    } catch { clearInterval(vnWatch); }
  }, 900);
}
function renderVndb(rows){
  const html = rows.map(r => `
    <div class="result">
      <div class="t">${esc(r.title)}</div>
      <div class="m">
        ${r.released ? `<span class="src">${esc(r.released)}</span>` : ''}
        ${r.rating ? `<span>★ ${r.rating}</span>` : ''}
      </div>
      <div class="sub">${esc((r.description || '').slice(0, 220))}</div>
    </div>`).join('') || '<div class="empty">No titles yet</div>';
  if (html === lastHtml.vndb) return;
  lastHtml.vndb = html;
  $('vn-results').innerHTML = html;
}

// ── Audiobookshelf ──
function loadAbs(){ pollAbs(); }
function pollAbs(){
  clearInterval(absWatch);
  let ticks = 0;
  absWatch = setInterval(async () => {
    ticks++;
    try {
      const d = await api('/abs');
      renderAbs(d);
      if ((!d.loading && ticks > 1) || ticks > 40) clearInterval(absWatch);
    } catch { clearInterval(absWatch); }
  }, 900);
}
function renderAbs(d){
  $('abs-login').style.display = d.connected ? 'none' : '';
  if (!d.connected && d.server && !$('abs-server').value) $('abs-server').value = d.server;
  $('abs-hint').innerHTML = d.loading ? '<span class="spin"></span> Loading…'
    : (d.error || (d.connected ? (d.library || 'Pick a library') : 'Sign in to your Audiobookshelf server.'));
  const books = d.view === 'Books';
  $('abs-crumbs').innerHTML = books ? '<button class="more" id="abs-back">‹ Libraries</button>' : '';
  if ($('abs-back')) $('abs-back').onclick = () => { api('/abs/back').catch(()=>{}); pollAbs(); };
  const rows = books ? (d.books || []) : (d.libraries || []);
  $('abs-results').innerHTML = rows.map((r, i) => `
    <div class="result">
      <div class="t">${esc(r.title || r.name)}</div>
      <div class="m">
        ${r.author ? `<span class="src">${esc(r.author)}</span>` : ''}
        ${r.media_type ? `<span class="src">${esc(r.media_type)}</span>` : ''}
        ${r.duration ? `<span>${fmt(r.duration)}</span>` : ''}
        <button class="play" data-i="${i}">${books ? 'Play' : 'Open'}</button></div>
    </div>`).join('') || (d.connected ? '<div class="empty">Nothing here</div>' : '');
  $('abs-results').querySelectorAll('button[data-i]').forEach(b => {
    b.onclick = () => { api('/abs/' + (books ? 'play' : 'open') + '?idx=' + b.dataset.i).catch(()=>{}); pollAbs(); };
  });
}

// ── OPDS catalog ──
function loadOpds(){ pollOpds(); }
function pollOpds(){
  clearInterval(opWatch);
  let ticks = 0;
  opWatch = setInterval(async () => {
    ticks++;
    try {
      const d = await api('/opds');
      renderOpds(d);
      if ((!d.loading && ticks > 1) || ticks > 40) clearInterval(opWatch);
    } catch { clearInterval(opWatch); }
  }, 900);
}
function renderOpds(d){
  $('opds-login').style.display = d.connected ? 'none' : '';
  $('opds-hint').innerHTML = d.loading ? '<span class="spin"></span> Loading…'
    : (d.error ? esc(d.message || 'Connection failed') : (d.connected ? (d.feed || '') : 'Point this at any OPDS catalog (Komga, Kavita, Calibre-Web, LANraragi).'));
  $('opds-crumbs').innerHTML = d.depth > 0 ? '<button class="more" id="opds-back">‹ Back</button>' : '';
  if ($('opds-back')) $('opds-back').onclick = () => { api('/opds/back').catch(()=>{}); pollOpds(); };
  $('opds-results').innerHTML = (d.entries || []).map((e, i) => `
    <div class="result">
      <div class="t">${esc(e.title)}</div>
      <div class="m">
        ${e.nav ? '<span class="src">folder</span>' : ''}
        ${e.streamable ? `<span class="src">${e.pages} pages</span>` : ''}
        <button class="play" data-i="${i}">${e.nav ? 'Open' : 'Read'}</button></div>
    </div>`).join('') || (d.connected ? '<div class="empty">Empty feed</div>' : '');
  $('opds-results').querySelectorAll('button[data-i]').forEach(b => {
    b.onclick = () => { api('/opds/open?idx=' + b.dataset.i).catch(()=>{}); pollOpds(); };
  });
}

// ── Plex (sign-in is Plex's PIN flow — enter the code at plex.tv/link) ──
function loadPlex(){ pollPlex(); }
function pollPlex(){
  clearInterval(plWatch);
  let ticks = 0;
  plWatch = setInterval(async () => {
    ticks++;
    try {
      const d = await api('/plex');
      renderPlex(d);
      // Keep polling through the PIN wait — the desktop does the same.
      const busy = d.loading || d.state === 'awaiting';
      if ((!busy && ticks > 1) || ticks > 120) clearInterval(plWatch);
    } catch { clearInterval(plWatch); }
  }, 1500);
}
function renderPlex(d){
  $('plex-go').style.display = d.connected ? 'none' : '';
  $('plex-out').style.display = d.connected ? '' : 'none';
  $('plex-hint').innerHTML = d.pin
    ? `Enter <b>${esc(d.pin)}</b> at plex.tv/link`
    : (d.loading ? '<span class="spin"></span> Loading…' : esc(d.status || (d.connected ? (d.server || 'Connected') : 'Not connected.')));
  const items = (d.items || []).length > 0;
  $('plex-crumbs').innerHTML = items ? '<button class="more" id="plex-back">‹ Sections</button>' : '';
  if ($('plex-back')) $('plex-back').onclick = () => { api('/plex/sections').catch(()=>{}); pollPlex(); };
  const rows = items ? d.items : (d.sections || []);
  $('plex-results').innerHTML = rows.map((r, i) => `
    <div class="result">
      <div class="t">${esc(r.title)}</div>
      <div class="m">
        ${r.year ? `<span class="src">${esc(r.year)}</span>` : ''}
        <button class="play" data-i="${i}">${items ? 'Play' : 'Open'}</button></div>
    </div>`).join('') || (d.connected ? '<div class="empty">Nothing here</div>' : '');
  $('plex-results').querySelectorAll('button[data-i]').forEach(b => {
    b.onclick = () => { api('/plex/' + (items ? 'play' : 'open') + '?idx=' + b.dataset.i).catch(()=>{}); pollPlex(); };
  });
}

// ── Server logs ──
// The headless box's most useful tab: `docker logs` only carries stdout, while
// scraper/mpv/worker output lives in the in-app ring.
let logErrorsOnly = false;
async function loadLogs(){
  $('lg-hint').innerHTML = '<span class="spin"></span> Loading…';
  try {
    const d = await api('/logs?limit=300' + (logErrorsOnly ? '&errors=1' : ''));
    const rows = d.entries || [];
    $('lg-results').innerHTML = rows.slice().reverse().map(e => `
      <div class="result${e.error ? ' err' : ''}">
        <div class="m"><span class="src">${esc(e.level)}</span><span class="src">${esc(e.prefix)}</span></div>
        <div class="t mono">${esc(e.text)}</div>
      </div>`).join('') || '<div class="empty">No log entries</div>';
    $('lg-hint').textContent = rows.length + (logErrorsOnly ? ' errors.' : ' entries (newest first).');
  } catch { $('lg-hint').textContent = 'Could not load logs.'; }
}

function loadRadio(){
  api('/radio').then(d => {
    renderRadio(d.stations || []);
    if (d.loading) pollRadio();
    else $('ra-hint').textContent = (d.stations || []).length + ' stations.';
  }).catch(()=>{});
}
$('ra-go').onclick = () => runRadio();
$('ra-q').addEventListener('keydown', e => { if (e.key === 'Enter') { runRadio(); $('ra-q').blur(); } });

// ── Parity tier 2 controls ──
const onGo = (btn, input, fn) => {
  $(btn).onclick = () => fn();
  $(input).addEventListener('keydown', e => { if (e.key === 'Enter') { fn(); $(input).blur(); } });
};
onGo('cx-go', 'cx-q', runComics);
onGo('nv-go', 'nv-q', runNovels);
onGo('vn-go', 'vn-q', runVndb);
$('cx-close').onclick = () => closeComic();
$('dr-more').onclick = () => { api('/drama/more').catch(()=>{}); loadDrama(); };
$('abs-go').onclick = () => {
  // Credentials go in the query here; the server reads them the same way the
  // desktop settings form does. Serve the web UI over TLS or Tailscale
  // (deploy/) — that is what keeps them off the wire in the clear.
  api('/abs/login?server=' + encodeURIComponent($('abs-server').value.trim())
    + '&user=' + encodeURIComponent($('abs-user').value)
    + '&pass=' + encodeURIComponent($('abs-pass').value)).catch(()=>{});
  $('abs-pass').value = '';
  pollAbs();
};
$('opds-go').onclick = () => {
  api('/opds/connect?server=' + encodeURIComponent($('opds-server').value.trim())
    + '&user=' + encodeURIComponent($('opds-user').value)
    + '&pass=' + encodeURIComponent($('opds-pass').value)).catch(()=>{});
  $('opds-pass').value = '';
  pollOpds();
};
$('plex-go').onclick = () => { api('/plex/connect').catch(()=>{}); pollPlex(); };
$('plex-out').onclick = () => { api('/plex/disconnect').catch(()=>{}); pollPlex(); };
$('lg-refresh').onclick = () => loadLogs();
$('lg-errors').onclick = () => {
  logErrorsOnly = !logErrorsOnly;
  $('lg-errors').classList.toggle('on', logErrorsOnly);
  loadLogs();
};
$('lg-clear').onclick = () => { api('/logs/clear').catch(()=>{}); loadLogs(); };
function runRadio(){
  const q = $('ra-q').value.trim(); if (!q) return;
  $('ra-hint').innerHTML = '<span class="spin"></span> Searching stations…';
  api('/radio/search?q=' + encodeURIComponent(q)).catch(()=>{});
  pollRadio();
}
function pollRadio(){
  clearInterval(raWatch);
  let ticks = 0;
  raWatch = setInterval(async () => {
    ticks++;
    try {
      const d = await api('/radio');
      renderRadio(d.stations || []);
      if ((!d.loading && ticks > 2) || ticks > 40) {
        clearInterval(raWatch);
        $('ra-hint').textContent = (d.stations || []).length + ' stations.';
      }
    } catch { clearInterval(raWatch); }
  }, 900);
}
function renderRadio(sts){
  const html = sts.map((s, i) => `
    <div class="result">
      <div class="t">${esc(s.name)}</div>
      <div class="m">
        ${s.country ? `<span class="src">${esc(s.country)}</span>` : ''}
        ${s.tags ? `<span>${esc((s.tags || '').split(',').slice(0,2).join(', '))}</span>` : ''}
        <button class="play" data-i="${i}" data-url="${encodeURIComponent(s.url || '')}">Listen</button></div>
    </div>`).join('') || '<div class="empty">No stations yet</div>';
  if (html === lastHtml.radio) return;
  lastHtml.radio = html;
  $('ra-results').innerHTML = html;
  $('ra-results').querySelectorAll('.play').forEach(b => b.onclick = () => {
    const u = decodeURIComponent(b.dataset.url || '');
    const t = b.parentElement.parentElement.querySelector('.t').textContent;
    if (HOSTED && u) return openStreamUrl(u, t);
    dispatchPlay(u, t, () => { api('/radio/play?idx=' + b.dataset.i).catch(()=>{}); b.textContent = 'Sent ✓'; });
  });
}
