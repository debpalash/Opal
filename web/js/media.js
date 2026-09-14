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
        <button class="anime-details" data-details="${i}">Details</button>
        <button class="play" data-idx="${i}">Episodes ⭢</button></div>
    </div>`).join('') || '<div class="empty">No results yet</div>';
  if (html === lastHtml.animeResults) return;
  lastHtml.animeResults = html;
  $('anime-results').innerHTML = html;
  $('anime-results').querySelectorAll('.play').forEach(b => b.onclick = () => loadAnimeEpisodes(+b.dataset.idx));
  $('anime-results').querySelectorAll('.anime-details').forEach(button => {
    const anime = rs[Number(button.dataset.details)] || {};
    button.onclick = () => openSourceDetails('Anime', {
      ...anime, title:anime.name, type:'Anime', meta:`${anime.episodes || 0} episodes`,
      index:Number(button.dataset.details),
    }, button);
  });
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
        <button class="music-details" data-details="${i}">Details</button>
        ${s.url ? `<button class="queue-btn" data-queue="${i}">Queue</button>` : ''}
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
  $('mu-results').querySelectorAll('[data-queue]').forEach(button => {
    const song = songs[Number(button.dataset.queue)] || {};
    button.onclick = () => queueMedia(song.url || '', song.title || '', button);
  });
  $('mu-results').querySelectorAll('.music-details').forEach(button => {
    const song = songs[Number(button.dataset.details)] || {};
    button.onclick = () => openSourceDetails('Music', {
      ...song, type:'Song', meta:song.artist || '', artUrl:song.cover || '',
      index:Number(button.dataset.details),
    }, button);
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
      <div class="m"><button class="comic-details" data-details="${i}">Details</button>
        <button class="play" data-cx="${encodeURIComponent(r.url)}">Read</button></div>
    </div>`).join('') || '<div class="empty">No results yet</div>';
  if (html === lastHtml.comics) return;
  lastHtml.comics = html;
  $('cx-results').innerHTML = html;
  $('cx-results').querySelectorAll('button[data-cx]').forEach(b => {
    b.onclick = () => openComic(decodeURIComponent(b.dataset.cx));
  });
  $('cx-results').querySelectorAll('.comic-details').forEach(button => {
    const comic = rows[Number(button.dataset.details)] || {};
    button.onclick = () => openSourceDetails('Comic', {
      ...comic, name:comic.title, type:'Comic', artUrl:comic.cover || '', url:comic.url,
    }, button);
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
      <div class="m"><button class="novel-details" data-details="${i}" data-kind="${kind}">Details</button>
        <button class="play" data-nv="${i}" data-kind="${kind}">${kind === 'open' ? 'Open' : 'Read'}</button></div>
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
        <button class="drama-details" data-details="${i}">Details</button>
        <button class="play" data-i="${i}">Play</button></div>
    </div>`).join('') || '<div class="empty">No titles yet</div>';
  if (html === lastHtml.drama) return;
  lastHtml.drama = html;
  $('dr-results').innerHTML = html;
  $('dr-results').querySelectorAll('button[data-i]').forEach(b => {
    b.onclick = () => { api('/drama/play?idx=' + b.dataset.i).catch(()=>{}); b.textContent = 'Resolving…'; };
  });
  $('dr-results').querySelectorAll('.drama-details').forEach(button => {
    const drama = rows[Number(button.dataset.details)] || {};
    button.onclick = () => openSourceDetails('Drama', {
      ...drama, type:'TV series', meta:[drama.year, drama.vote ? `Rating ${drama.vote}` : ''].filter(Boolean).join(' · '),
      artUrl:drama.poster_path ? `https://image.tmdb.org/t/p/w500${drama.poster_path}` : '', index:Number(button.dataset.details),
    }, button);
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
  const html = rows.map((r, i) => `
    <div class="result">
      <div class="t">${esc(r.title)}</div>
      <div class="m">
        ${r.released ? `<span class="src">${esc(r.released)}</span>` : ''}
        ${r.rating ? `<span>★ ${r.rating}</span>` : ''}
        <button class="vndb-details" data-details="${i}">Details</button>
      </div>
      <div class="sub">${esc((r.description || '').slice(0, 220))}</div>
    </div>`).join('') || '<div class="empty">No titles yet</div>';
  if (html === lastHtml.vndb) return;
  lastHtml.vndb = html;
  $('vn-results').innerHTML = html;
  $('vn-results').querySelectorAll('.vndb-details').forEach(button => {
    const novel = rows[Number(button.dataset.details)] || {};
    button.onclick = () => openSourceDetails('Visual novel', {
      ...novel, name:novel.title, type:'Visual novel', overview:novel.description || '',
      meta:[novel.released, novel.rating ? `Rating ${novel.rating}` : ''].filter(Boolean).join(' · '), artUrl:novel.image || '',
    }, button);
  });
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
        ${books ? `<button class="abs-details" data-details="${i}">Details</button>` : ''}
        <button class="play" data-i="${i}">${books ? 'Play' : 'Open'}</button></div>
    </div>`).join('') || (d.connected ? '<div class="empty">Nothing here</div>' : '');
  $('abs-results').querySelectorAll('button[data-i]').forEach(b => {
    b.onclick = () => { api('/abs/' + (books ? 'play' : 'open') + '?idx=' + b.dataset.i).catch(()=>{}); pollAbs(); };
  });
  $('abs-results').querySelectorAll('.abs-details').forEach(button => {
    button.onclick = () => {
      const book = rows[Number(button.dataset.details)] || {};
      openSourceDetails('Audiobookshelf', {
        ...book, name:book.title, type:'Audiobook',
        meta:[book.author, book.duration ? fmt(book.duration) : ''].filter(Boolean).join(' · '),
        index:Number(button.dataset.details),
      }, button);
    };
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
        <button class="opds-details" data-details="${i}">Details</button>
        <button class="play" data-i="${i}">${e.nav ? 'Open' : 'Read'}</button></div>
    </div>`).join('') || (d.connected ? '<div class="empty">Empty feed</div>' : '');
  $('opds-results').querySelectorAll('button[data-i]').forEach(b => {
    b.onclick = () => { api('/opds/open?idx=' + b.dataset.i).catch(()=>{}); pollOpds(); };
  });
  $('opds-results').querySelectorAll('.opds-details').forEach(button => {
    const entry = (d.entries || [])[Number(button.dataset.details)] || {};
    button.onclick = () => openSourceDetails('OPDS', {
      ...entry, name:entry.title, type:entry.nav ? 'Collection' : (entry.type || 'Publication'),
      meta:entry.streamable ? `${entry.pages} pages` : '', index:Number(button.dataset.details),
    }, button);
  });
  $('nv-results').querySelectorAll('.novel-details').forEach(button => {
    const row = rows[Number(button.dataset.details)] || {};
    button.onclick = () => openSourceDetails('Novel', {
      ...row, name:row.title, type:button.dataset.kind === 'chapter' ? 'Chapter' : 'Novel',
      kind:button.dataset.kind === 'chapter' ? 'chapter' : 'novel', index:Number(button.dataset.details),
    }, button);
  });
}

// ── Plex (sign-in is Plex's PIN flow — enter the code at plex.tv/link) ──
function loadPlex(){ pollPlex(); }
function plexRatingOptions(current){
  const selected = Math.round(Math.max(0, Math.min(10, Number(current) || 0)) * 2) / 2;
  return Array.from({length:21}, (_, i) => {
    const value = i / 2;
    const label = value === 0 ? 'Unrated' : `Rating ${value.toFixed(1)}`;
    return `<option value="${value}"${value === selected ? ' selected' : ''}>${label}</option>`;
  }).join('');
}
let sourceDetailsReturnFocus = null;
function closeSourceDetails(){
  const dialog = $('source-details');
  if (dialog.open) dialog.close();
}
function detailAction(label, run, primary){
  const button = document.createElement('button');
  button.type = 'button'; button.textContent = label;
  if (primary) button.className = 'primary';
  button.onclick = async () => {
    button.disabled = true;
    try { await run(); } catch (error) {
      button.disabled = false; toast(error.message || 'Action failed');
    }
  };
  return button;
}
function sourceArtUrl(value){
  if (!value) return '';
  try {
    const url = new URL(value, location.href);
    return url.protocol === 'http:' || url.protocol === 'https:' ? url.href : '';
  } catch { return ''; }
}
function openSourceDetails(source, item, trigger){
  const dialog = $('source-details'), actions = $('source-details-actions');
  sourceDetailsReturnFocus = trigger || document.activeElement;
  $('source-details-source').textContent = source;
  $('source-details-title').textContent = item.name || item.title || 'Untitled';
  const runtime = Number(item.runtime || item.duration || 0);
  $('source-details-meta').textContent = item.meta || [item.type || '', item.year || '', runtime ? fmt(runtime) : ''].filter(Boolean).join(' · ');
  $('source-details-overview').textContent = item.overview || '';
  const art = $('source-details-art');
  const artUrl = sourceArtUrl(item.artUrl || (source === 'Jellyfin' && item.image
    ? `${BASE}/api/jellyfin/poster?id=${encodeURIComponent(item.id)}` : ''));
  art.hidden = !artUrl; art.src = artUrl; art.alt = artUrl ? `Poster for ${item.name || item.title || 'item'}` : '';
  actions.replaceChildren();
  if (source === 'Jellyfin') {
    const play = async () => {
      if (item.folder) { closeSourceDetails(); jfBrowse(item.id); return; }
      const route = isJfAudio(item.type) ? '/jellyfin/play_audio?id=' : '/jellyfin/play?id=';
      await api(route + encodeURIComponent(item.id)); closeSourceDetails();
    };
    actions.append(detailAction(item.folder ? 'Open' : (item.progress && !item.played ? 'Resume' : 'Play'), play, true));
    if (!item.folder) {
      actions.append(detailAction(item.favorite ? 'Remove favorite' : 'Favorite', async () => {
        await apiMutation('/jellyfin/action?id=' + encodeURIComponent(item.id) + '&action=favorite&enabled=' + !item.favorite);
        closeSourceDetails(); await loadJellyfin(); setTimeout(loadJellyfin, 1200);
      }));
      actions.append(detailAction(item.played ? 'Mark unwatched' : 'Mark watched', async () => {
        await apiMutation('/jellyfin/action?id=' + encodeURIComponent(item.id) + '&action=played&enabled=' + !item.played);
        closeSourceDetails(); await loadJellyfin(); setTimeout(loadJellyfin, 1200);
      }));
    }
  } else if (source === 'Plex') {
    actions.append(detailAction(item.folder ? 'Open' : (item.progress && !item.played ? 'Resume' : 'Play'), async () => {
      await apiMutation('/plex/' + (item.folder ? 'open_item' : 'play') + '?id=' + encodeURIComponent(item.id));
      closeSourceDetails(); pollPlex();
    }, true));
    if (!item.folder) {
      actions.append(detailAction(item.favorite ? 'Remove favorite' : 'Favorite', async () => {
        await apiMutation('/plex/action?id=' + encodeURIComponent(item.id) + '&action=favorite&enabled=' + !item.favorite);
        closeSourceDetails(); pollPlex();
      }));
      actions.append(detailAction(item.played ? 'Mark unwatched' : 'Mark watched', async () => {
        await apiMutation('/plex/action?id=' + encodeURIComponent(item.id) + '&action=played&enabled=' + !item.played);
        closeSourceDetails(); pollPlex();
      }));
      const rating = document.createElement('select');
      rating.className = 'plex-rating'; rating.dataset.id = item.id;
      rating.setAttribute('aria-label', `Rate ${item.title || 'item'}`);
      rating.innerHTML = plexRatingOptions(item.rating);
      rating.onchange = async () => {
        rating.disabled = true;
        try {
          await apiMutation('/plex/action?id=' + encodeURIComponent(item.id) + '&action=rating&rating=' + encodeURIComponent(rating.value));
          closeSourceDetails(); pollPlex();
        } catch (error) { rating.disabled = false; toast(error.message || 'Could not update rating.'); }
      };
      actions.append(rating);
    }
  } else if (source === 'Audiobookshelf') {
    actions.append(detailAction('Play', async () => {
      await api('/abs/play?idx=' + encodeURIComponent(item.index)); closeSourceDetails(); pollAbs();
    }, true));
  } else if (source === 'OPDS') {
    actions.append(detailAction(item.nav ? 'Open' : 'Read', async () => {
      await api('/opds/open?idx=' + encodeURIComponent(item.index)); closeSourceDetails(); pollOpds();
    }, true));
  } else if (source === 'Podcast') {
    actions.append(detailAction(item.kind === 'show' ? 'View episodes' : 'Play', async () => {
      closeSourceDetails();
      if (item.kind === 'show') loadPodEpisodes(item.index);
      else await api('/podcasts/play?idx=' + encodeURIComponent(item.index));
    }, true));
  } else if (source === 'Music') {
    actions.append(detailAction('Play', async () => {
      closeSourceDetails();
      dispatchPlay(item.url || '', item.title || '', () => api('/music/play?idx=' + encodeURIComponent(item.index)));
    }, true));
    if (item.url) actions.append(detailAction('Queue', async () => {
      await queueMedia(item.url, item.title || ''); closeSourceDetails();
    }));
  } else if (source === 'Radio') {
    actions.append(detailAction('Listen', async () => {
      closeSourceDetails();
      dispatchPlay(item.url || '', item.name || '', () => api('/radio/play?idx=' + encodeURIComponent(item.index)));
    }, true));
    if (item.url) actions.append(detailAction('Queue', async () => {
      await queueMedia(item.url, item.name || ''); closeSourceDetails();
    }));
  } else if (source === 'Anime') {
    actions.append(detailAction('View episodes', () => {
      closeSourceDetails(); loadAnimeEpisodes(item.index);
    }, true));
  } else if (source === 'Live TV') {
    actions.append(detailAction('Watch', () => {
      closeSourceDetails(); dispatchPlay(item.url || '', item.name || '', () =>
        apiMutation('/load?url=' + encodeURIComponent(item.url || '')));
    }, true));
    if (item.url) actions.append(detailAction('Queue', async () => {
      await queueMedia(item.url, item.name || ''); closeSourceDetails();
    }));
  } else if (source === 'YouTube') {
    const url = 'https://www.youtube.com/watch?v=' + (item.id || '');
    actions.append(detailAction('Play', () => {
      closeSourceDetails();
      if (HOSTED || PLAY_HERE) openYtEmbed(item.id, item.title || '');
      else return apiMutation('/load?url=' + encodeURIComponent(url));
    }, true));
    if (item.id) actions.append(detailAction('Queue', async () => {
      await queueMedia(url, item.title || ''); closeSourceDetails();
    }));
  } else if (source === 'Comic') {
    actions.append(detailAction('Read', () => { closeSourceDetails(); openComic(item.url); }, true));
  } else if (source === 'Novel') {
    actions.append(detailAction(item.kind === 'chapter' ? 'Read' : 'Open', async () => {
      if (item.kind !== 'chapter') novelIdx = item.index;
      await api('/novels/' + (item.kind === 'chapter' ? 'chapter' : 'open') + '?idx=' + encodeURIComponent(item.index));
      closeSourceDetails(); pollNovels();
    }, true));
  } else if (source === 'Drama') {
    actions.append(detailAction('Find streams', async () => {
      await api('/drama/play?idx=' + encodeURIComponent(item.index)); closeSourceDetails();
    }, true));
  } else if (source === 'RSS') {
    actions.append(detailAction('Play', async () => {
      await apiMutation('/load?url=' + encodeURIComponent(item.url)); closeSourceDetails();
    }, true));
  }
  if (!dialog.open) dialog.showModal();
}
$('source-details-close').onclick = closeSourceDetails;
$('source-details').addEventListener('click', event => { if (event.target === $('source-details')) closeSourceDetails(); });
$('source-details').addEventListener('close', () => {
  $('source-details-art').removeAttribute('src');
  if (sourceDetailsReturnFocus && sourceDetailsReturnFocus.isConnected) sourceDetailsReturnFocus.focus();
  sourceDetailsReturnFocus = null;
});
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
  const browsing = (d.depth || 0) > 0 || items;
  $('plex-crumbs').innerHTML = (d.depth || 0) > 0
    ? '<button class="more" id="plex-back">‹ Back</button>'
    : (d.sections || []).map((section, i) => `<button class="more${i === d.active_section ? ' on' : ''}" data-plex-section="${i}">${esc(section.title)}</button>`).join('');
  if ($('plex-back')) $('plex-back').onclick = () => { apiMutation('/plex/back').catch(()=>{}); pollPlex(); };
  $('plex-crumbs').querySelectorAll('[data-plex-section]').forEach(button => {
    button.onclick = () => { apiMutation('/plex/open?idx=' + button.dataset.plexSection).catch(()=>{}); pollPlex(); };
  });
  const rows = browsing ? (d.items || []) : (d.sections || []);
  $('plex-results').innerHTML = rows.map((r, i) => `
    <div class="result">
      <div class="t">${esc(r.title)}</div>
      <div class="m">
        ${r.year ? `<span class="src">${esc(r.year)}</span>` : ''}
        ${browsing && r.type ? `<span class="src">${esc(r.type)}</span>` : ''}
        ${browsing && r.duration ? `<span class="src">${r.played ? 'Watched' : (r.progress ? `${fmt(r.progress)} / ${fmt(r.duration)}` : fmt(r.duration))}</span>` : ''}
        ${browsing && !r.folder ? `<button class="plex-favorite" data-id="${esc(r.id || '')}" data-enabled="${!r.favorite}" aria-label="${r.favorite ? 'Remove favorite' : 'Add favorite'}" title="${r.favorite ? 'Remove favorite' : 'Add favorite'}">${r.favorite ? '&#9733;' : '&#9734;'}</button>` : ''}
        ${browsing && !r.folder ? `<button class="plex-watched" data-id="${esc(r.id || '')}" data-enabled="${!r.played}" aria-label="${r.played ? 'Mark unwatched' : 'Mark watched'}" title="${r.played ? 'Mark unwatched' : 'Mark watched'}">${r.played ? '&#10003;' : '&#9675;'}</button>` : ''}
        ${browsing && !r.folder ? `<select class="plex-rating" data-id="${esc(r.id || '')}" aria-label="Rate ${esc(r.title)}">${plexRatingOptions(r.rating)}</select>` : ''}
        ${browsing ? `<button class="plex-details" data-i="${i}">Details</button>` : ''}
        <button class="play" data-i="${i}" data-id="${browsing ? esc(r.id || '') : ''}">${browsing ? (r.folder ? 'Open' : (r.progress && !r.played ? 'Resume' : 'Play')) : 'Open'}</button></div>
      ${items && r.duration && r.progress ? `<div class="plex-progress"><i style="width:${Math.min(100,Math.round(r.progress/r.duration*100))}%"></i></div>` : ''}
    </div>`).join('') || (d.connected ? '<div class="empty">Nothing here</div>' : '');
  $('plex-results').querySelectorAll('button[data-i]').forEach(b => {
    b.onclick = () => {
      const row = rows[Number(b.dataset.i)] || {};
      const request = browsing
        ? apiMutation('/plex/' + (row.folder ? 'open_item' : 'play') + '?id=' + encodeURIComponent(b.dataset.id))
        : apiMutation('/plex/open?idx=' + b.dataset.i);
      request.catch(()=>{}); pollPlex();
    };
  });
  $('plex-results').querySelectorAll('.plex-watched').forEach(button => {
    button.onclick = async () => {
      button.disabled = true;
      try {
        await apiMutation('/plex/action?id=' + encodeURIComponent(button.dataset.id) +
          '&action=played&enabled=' + button.dataset.enabled);
        pollPlex();
      } catch (error) { button.disabled = false; toast(error.message || 'Could not update watched state.'); }
    };
  });
  $('plex-results').querySelectorAll('.plex-favorite').forEach(button => {
    button.onclick = async () => {
      button.disabled = true;
      try {
        await apiMutation('/plex/action?id=' + encodeURIComponent(button.dataset.id) +
          '&action=favorite&enabled=' + button.dataset.enabled);
        pollPlex();
      } catch (error) { button.disabled = false; toast(error.message || 'Could not update favorite.'); }
    };
  });
  $('plex-results').querySelectorAll('.plex-rating').forEach(select => {
    select.onchange = async () => {
      select.disabled = true;
      try {
        await apiMutation('/plex/action?id=' + encodeURIComponent(select.dataset.id) +
          '&action=rating&rating=' + encodeURIComponent(select.value));
        pollPlex();
      } catch (error) { select.disabled = false; toast(error.message || 'Could not update rating.'); }
    };
  });
  $('plex-results').querySelectorAll('.plex-details').forEach(button => {
    button.onclick = () => openSourceDetails('Plex', rows[Number(button.dataset.i)] || {}, button);
  });
}

// ── Server logs ──
// The headless box's most useful tab: `docker logs` only carries stdout, while
// scraper/mpv/worker output lives in the in-app ring.
let logErrorsOnly = false;
async function loadLogs(){
  const perf = webPerf.summary();
  const metric = value => value === null ? 'measuring' : `${Math.round(value)} ms`;
  $('web-perf').textContent = `Shell ${metric(perf.shell_ms)} · Interaction p95 ${metric(perf.interaction_p95_ms)} (${perf.interaction_count}) · Long tasks ${perf.long_task_count}, max ${Math.round(perf.long_task_max_ms)} ms`;
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
  apiFormMutation('/abs/login', {
    server:$('abs-server').value.trim(), user:$('abs-user').value, pass:$('abs-pass').value,
  }).catch(()=>{});
  $('abs-pass').value = '';
  pollAbs();
};
$('opds-go').onclick = () => {
  apiFormMutation('/opds/connect', {
    server:$('opds-server').value.trim(), user:$('opds-user').value, pass:$('opds-pass').value,
  }).catch(()=>{});
  $('opds-pass').value = '';
  pollOpds();
};
$('plex-go').onclick = () => { apiMutation('/plex/connect').catch(()=>{}); pollPlex(); };
$('plex-out').onclick = () => { apiMutation('/plex/disconnect').catch(()=>{}); pollPlex(); };
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
        <button class="radio-details" data-details="${i}">Details</button>
        ${s.url ? `<button class="queue-btn" data-queue="${i}">Queue</button>` : ''}
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
  $('ra-results').querySelectorAll('[data-queue]').forEach(button => {
    const station = sts[Number(button.dataset.queue)] || {};
    button.onclick = () => queueMedia(station.url || '', station.name || '', button);
  });
  $('ra-results').querySelectorAll('.radio-details').forEach(button => {
    const station = sts[Number(button.dataset.details)] || {};
    button.onclick = () => openSourceDetails('Radio', {
      ...station, type:'Station', meta:[station.country || '', station.tags || ''].filter(Boolean).join(' · '),
      artUrl:station.favicon || '', index:Number(button.dataset.details),
    }, button);
  });
}
