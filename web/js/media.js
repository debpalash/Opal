'use strict';

const mediaIcon = name => {
  const path = name === 'play'
    ? '<path d="M8 5v14l11-7z"/>'
    : '<circle cx="12" cy="12" r="9"/><path d="M12 11v6M12 7h.01"/>';
  return `<svg aria-hidden="true" viewBox="0 0 24 24">${path}</svg>`;
};

// ── Anime ──
// Server routes are async: /anime/search & /anime/episodes trigger background
// work and return {ok:true}; poll GET /anime for {results,episodes,selected,loading}.
let animeWatch = null;
let animeBrowseGeneration = 0;
let animeEpisodeWatch = null;
let animeEpisodeGeneration = 0;
let animePlaybackWatch = null;
async function loadAnime(generation = animeBrowseGeneration, polling = false){
  try {
    const data = await api('/anime');
    if (generation !== animeBrowseGeneration) return data;
    renderAnime(data);
    $('anime-more').style.display = data.has_more ? '' : 'none';
    if (data.loading && !polling) pollAnime(generation);
    return data;
  } catch { if (generation === animeBrowseGeneration) failBrowse('anime-results', 'anime-hint', 'Could not load anime. Try again.'); }
}
function renderAnime(d){ renderAnimeResults(d.results || [], d.loading); renderAnimeEpisodes(d.episodes || [], d); }
$('anime-go').onclick = () => runAnime();
$('anime-q').addEventListener('keydown', e => { if (e.key === 'Enter') { runAnime(); $('anime-q').blur(); } });
async function runAnime(){
  const q = $('anime-q').value.trim(); if (!q) return;
  const generation = ++animeBrowseGeneration;
  clearInterval(animeEpisodeWatch); ++animeEpisodeGeneration;
  clearInterval(animePlaybackWatch); clearInterval(animeWatch);
  $('anime-hint').textContent = 'Searching anime…';
  renderAnimeResults([], true); $('anime-episodes').innerHTML = ''; lastHtml.animeEpisodes = '';
  $('anime-more').style.display = 'none';
  try {
    await api('/anime/search?q=' + encodeURIComponent(q));
    if (generation === animeBrowseGeneration) pollAnime(generation);
  } catch { if (generation === animeBrowseGeneration) failBrowse('anime-results', 'anime-hint', 'Could not search anime. Try again.'); }
}
function pollAnime(generation){
  clearInterval(animeWatch);
  let ticks = 0;
  animeWatch = settledInterval(async () => {
    const d = await loadAnime(generation, true);
    if (generation !== animeBrowseGeneration) return;
    if (!d?.loading || ++ticks > BROWSE_POLL_LIMIT) {
      clearInterval(animeWatch);
      if (d?.loading) failBrowse('anime-results', 'anime-hint', 'Still loading. Search again to retry.');
      else if (d) $('anime-hint').textContent = (d.results || []).length + ' titles — choose one for episodes.';
    }
  }, BROWSE_POLL_MS, true);
}
function renderAnimeResults(rs, loading = false){
  setBrowseBusy('anime-results', loading);
  const html = rs.map((r, i) => `
    <div class="card ${r.poster ? '' : 'poster-missing'}">
      ${r.poster ? `<img src="${esc(r.poster)}" alt="" loading="lazy" decoding="async">` : ''}
      <div class="jf-card-actions">
        <button class="anime-details" data-details="${i}" aria-label="Details">${mediaIcon('info')}</button>
        <button class="play" data-idx="${i}" aria-label="Episodes">${mediaIcon('play')}</button>
      </div>
      <div class="cap" title="${esc(r.name)}">${esc(r.name)}</div>
      <div class="browse-card-meta">
        <span>${esc([r.type, r.year || ''].filter(Boolean).join(' · '))}</span>
        ${r.score ? `<span class="rt">★ ${Number(r.score).toFixed(1)}</span>` : ''}
      </div>
    </div>`).join('') || (loading ? browseLoadingHtml('poster') : '<div class="empty">No results yet</div>');
  if (html === lastHtml.animeResults) return;
  lastHtml.animeResults = html;
  $('anime-results').innerHTML = html;
  $('anime-results').querySelectorAll('.play').forEach(b => b.onclick = () => loadAnimeEpisodes(+b.dataset.idx));
  $('anime-results').querySelectorAll('.anime-details').forEach(button => {
    const anime = rs[Number(button.dataset.details)] || {};
    button.onclick = () => openSourceDetails('Anime', {
      ...anime, title:anime.name, type:anime.type || 'Anime', overview:anime.overview || '',
      meta:[anime.year || '', anime.episodes ? `${anime.episodes} episodes` : 'Episode count unavailable', anime.score ? `Rating ${anime.score}` : ''].filter(Boolean).join(' · '),
      artUrl:anime.poster || '',
      index:Number(button.dataset.details),
    }, button);
  });
}
async function loadAnimeEpisodes(idx){
  clearInterval(animeWatch); ++animeBrowseGeneration;
  clearInterval(animeEpisodeWatch);
  clearInterval(animePlaybackWatch);
  const generation = ++animeEpisodeGeneration;
  $('anime-episodes').innerHTML = '<div class="empty"><span class="spin"></span></div>';
  lastHtml.animeEpisodes = '';
  try { await api('/anime/episodes?idx=' + idx); }
  catch { $('anime-episodes').textContent = 'Could not load episodes. Try again.'; return; }
  if (generation !== animeEpisodeGeneration) return;
  let tries = 0;
  animeEpisodeWatch = settledInterval(async () => {
    if (generation !== animeEpisodeGeneration) return;
    try {
      const d = await api('/anime');
      if (generation !== animeEpisodeGeneration) return;
      if (d.selected !== idx) { clearInterval(animeEpisodeWatch); return; }
      renderAnimeEpisodes(d.episodes || [], d);
      if (!d.episodes_loading || ++tries > 120) clearInterval(animeEpisodeWatch);
    } catch { clearInterval(animeEpisodeWatch); }
  }, 700);
}
function renderAnimeEpisodes(eps, data = {}){
  const status = data.episodes_loading ? '<div class="empty"><span class="spin"></span> Loading episodes…</div>'
    : data.episodes_failed ? '<div class="empty">Episode details unavailable. Select the title to retry.</div>' : '';
  const playback = data.stream_loading ? '<div class="empty">Finding a stream… <button id="anime-cancel">Cancel</button></div>'
    : data.stream_failed ? '<div class="empty">No playable source found. Check installed anime sources or try Search.</div>' : '';
  const html = status + playback + (eps.length
    ? '<div class="sect">Episodes</div><div class="ep-grid">' +
      eps.map(e => {
        const busy = data.stream_loading && Number(e) === data.stream_episode;
        return `<button class="ep-btn" data-ep="${esc(String(e))}"${busy ? ' disabled aria-busy="true"' : ''}>${busy ? '<span class="spin"></span> ' : ''}${esc(String(e))}</button>`;
      }).join('') + '</div>'
    : data.selected != null && !data.episodes_loading && !data.episodes_failed ? '<div class="empty">No episodes announced yet</div>' : '');
  if (lastHtml.animeEpisodes === html) return;
  lastHtml.animeEpisodes = html;
  $('anime-episodes').innerHTML = html;
  const cancel = $('anime-cancel');
  if (cancel) cancel.onclick = async () => { await api('/anime/cancel'); clearInterval(animePlaybackWatch); loadAnime(); };
  $('anime-episodes').querySelectorAll('.ep-btn').forEach(b => b.onclick = async () => {
    b.disabled = true;
    b.setAttribute('aria-busy', 'true');
    b.innerHTML = '<span class="spin"></span> ' + esc(b.dataset.ep);
    try { await api('/anime/play?ep=' + encodeURIComponent(b.dataset.ep)); }
    catch {
      b.disabled = false; b.removeAttribute('aria-busy'); b.textContent = b.dataset.ep;
      toast('Could not start this episode. Try again.');
      return;
    }
    clearInterval(animePlaybackWatch);
    let ticks = 0;
    animePlaybackWatch = settledInterval(async () => {
      const d = await loadAnime();
      if ((d && !d.stream_loading) || ++ticks > 180) clearInterval(animePlaybackWatch);
    }, 700);
    loadAnime();
  });
}

// ── Music ──
// /music/search kicks off an async fetch; poll GET /music for {loading,songs}.
// Each song carries a direct stream url: hosted plays it in the browser,
// companion hands the index to the desktop player.
let muWatch = null;
let musicGeneration = 0;
function loadMusic(){
  const gen = ++musicGeneration;
  api('/music').then(d => {
    if (gen !== musicGeneration || currentPage !== 'music') return;
    $('mu-source').value = String(d.source || 0); renderMusic(d.songs || [], d.loading);
    if (d.loading) pollMusic(gen);
  }).catch(()=>{});
}
$('mu-source').onchange = async () => {
  const gen = ++musicGeneration;
  clearInterval(muWatch);
  try { await api('/music/source?id=' + encodeURIComponent($('mu-source').value)); }
  catch { $('mu-hint').textContent = 'Could not switch music source.'; return; }
  if (gen !== musicGeneration || currentPage !== 'music') return;
  $('mu-results').innerHTML = ''; lastHtml.music = '';
  if ($('mu-q').value.trim() || $('mu-source').value === '4') runMusic();
};
$('mu-go').onclick = () => runMusic();
$('mu-q').addEventListener('keydown', e => { if (e.key === 'Enter') { runMusic(); $('mu-q').blur(); } });
async function runMusic(){
  const q = $('mu-q').value.trim(); if (!q && $('mu-source').value !== '4') return;
  const gen = ++musicGeneration;
  $('mu-hint').innerHTML = '<span class="spin"></span> Searching music…';
  renderMusic([], true);
  clearInterval(muWatch);
  try { await api('/music/search?q=' + encodeURIComponent(q)); }
  catch { if (gen === musicGeneration) failBrowse('mu-results', 'mu-hint', 'Could not search music. Try again.'); return; }
  if (gen !== musicGeneration || currentPage !== 'music') return;
  pollMusic(gen);
}
function pollMusic(gen){
  clearInterval(muWatch);
  let ticks = 0;
  muWatch = settledInterval(async () => {
    ticks++;
    try {
      const d = await api('/music');
      if (gen !== musicGeneration || currentPage !== 'music') return;
      renderMusic(d.songs || [], d.loading);
      if (!d.loading || ticks > 120) {
        clearInterval(muWatch);
        if (d.loading) failBrowse('mu-results', 'mu-hint', 'Still loading. Search again to retry.');
        else $('mu-hint').textContent = (d.songs || []).length + ' songs.';
      }
    } catch { if (gen === musicGeneration) { clearInterval(muWatch); failBrowse('mu-results', 'mu-hint', 'Could not load music. Try again.'); } }
  }, BROWSE_POLL_MS, true);
}
function renderMusic(songs, loading = false){
  setBrowseBusy('mu-results', loading);
  const html = songs.map((s, i) => `
    <div class="result">
      <div class="t">${esc(s.title)}</div>
      ${s.attribution ? `<div class="m">${esc(s.attribution)}</div>` : ''}
      <div class="m"><span class="src">${esc(s.artist || '')}</span>
        <button class="music-details" data-details="${i}">Details</button>
        ${s.url ? `<button class="queue-btn" data-queue="${i}">Queue</button>` : ''}
        <button class="play" data-destination-verb="Play" data-i="${i}" data-track-id="${encodeURIComponent(s.id || '')}" data-source="${Number(s.source)}" data-url="${encodeURIComponent(s.url || '')}">${destinationActionLabel('Play')}</button></div>
    </div>`).join('') || (loading ? browseLoadingHtml('row') : '<div class="empty">No songs yet</div>');
  if (html === lastHtml.music) return;
  lastHtml.music = html;
  $('mu-results').innerHTML = html;
  $('mu-results').querySelectorAll('.play').forEach(b => b.onclick = () => {
    const u = decodeURIComponent(b.dataset.url || '');
    const t = b.parentElement.parentElement.querySelector('.t').textContent;
    if (HOSTED && u) return openStreamUrl(u, t);
    dispatchPlay(u, t, () => { api('/music/play?source=' + b.dataset.source + '&id=' + b.dataset.trackId).then(() => { b.textContent = 'Sent ✓'; }).catch(() => { b.textContent = 'Refresh tracks'; }); });
  });
  $('mu-results').querySelectorAll('[data-queue]').forEach(button => {
    const song = songs[Number(button.dataset.queue)] || {};
    button.onclick = () => queueMedia(song.url || '', song.title || '', button);
  });
  $('mu-results').querySelectorAll('.music-details').forEach(button => {
    const song = songs[Number(button.dataset.details)] || {};
    button.onclick = () => openSourceDetails('Music', {
      ...song, type:'Song', meta:song.artist || '', artUrl:song.cover || '', overview:song.attribution || '',
      index:Number(button.dataset.details),
    }, button);
  });
}

// ── Radio ──
// GET /radio seeds the popular list on first open; /radio/search filters.
let raWatch = null;
// Parity-tier-2 poll handles. `cxPages` is separate from `cxWatch`: the reader
// keeps polling page progress while the search listing sits idle behind it.
let comicGeneration = 0, comicSearchGeneration = 0, radioGeneration = 0, novelGeneration = 0;
let cxWatch = null, cxPages = null, nvWatch = null, drWatch = null, vnWatch = null;
let absWatch = null, opWatch = null, plWatch = null;
// Which search row the open novel came from — /novels has no server-side back.
let novelIdx = 0;

// ── Comics: search → reader ──
// Pages come from /api/comics/page?i=N, which takes the token in the query
// because <img> cannot send an Authorization header (same as /poster).
function renderComicSources(d){
  const picker = $('cx-source'); if (!picker) return;
  const rows = [{id:'all',name:'All sources'}];
  if (d.xkcd_installed) rows.push({id:'xkcd',name:'xkcd · archive / number'});
  if (d.smbc_installed) rows.push({id:'smbc',name:'SMBC · recent comics'});
  const markup = rows.map(r => `<option value="${r.id}">${esc(r.name)}</option>`).join('');
  if (picker.innerHTML !== markup) picker.innerHTML = markup;
  picker.value = rows.some(r => r.id === d.source) ? d.source : 'all';
  picker.hidden = rows.length === 1;
}
async function refreshComics(generation = comicSearchGeneration){
  const d = await api('/comics/results');
  if (generation !== comicSearchGeneration) return d;
  renderComicSources(d);
  renderComics(d.results || [], d.loading);
  $('cx-more').style.display = d.has_more ? '' : 'none';
  $('cx-hint').textContent = d.loading ? 'Loading comics…' : `${(d.results || []).length} results.`;
  return d;
}
function loadComics(){ pollComics(++comicSearchGeneration); }
async function runComics(){
  const q = $('cx-q').value.trim();
  const source = $('cx-source')?.value || 'all';
  if (!q && source === 'all') return;
  const generation = ++comicSearchGeneration;
  clearInterval(cxWatch);
  $('cx-hint').textContent = 'Searching…';
  renderComics([], true);
  try {
    await api('/comics/search?q=' + encodeURIComponent(q) + '&source=' + encodeURIComponent(source));
    if (generation === comicSearchGeneration) pollComics(generation);
  } catch { if (generation === comicSearchGeneration) failBrowse('cx-results', 'cx-hint', 'Could not search comics. Try again.'); }
}
function pollComics(generation){
  clearInterval(cxWatch);
  let ticks = 0;
  cxWatch = settledInterval(async () => {
    try {
      const d = await refreshComics(generation);
      if (generation !== comicSearchGeneration) return;
      if (!d.loading || ++ticks > BROWSE_POLL_LIMIT) {
        clearInterval(cxWatch);
        if (d.loading) failBrowse('cx-results', 'cx-hint', 'Still loading. Search again to retry.');
      }
    } catch { if (generation === comicSearchGeneration) { clearInterval(cxWatch); $('cx-hint').textContent = 'Could not load comics. Try again.'; } }
  }, BROWSE_POLL_MS, true);
}
function renderComics(rows, loading = false){
  setBrowseBusy('cx-results', loading);
  const html = rows.map((r, i) => `
    <div class="card ${r.cover ? '' : 'poster-missing'}">
      ${r.cover ? `<img src="${esc(r.cover)}" alt="" loading="lazy" decoding="async">` : ''}
      <div class="jf-card-actions">
        <button class="comic-details" data-details="${i}" aria-label="Details">${mediaIcon('info')}</button>
        <button class="play" data-cx="${encodeURIComponent(r.url)}" aria-label="Read ${esc(r.title)}">Read</button>
      </div>
      <div class="cap" title="${esc(r.title)}">${esc(r.title)}</div>
    </div>`).join('') || (loading ? browseLoadingHtml('poster') : '<div class="empty">No comics found. Try another title or source.</div>');
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
function renderComicChapters(d){
  let controls = $('cx-chapter-controls');
  if (!controls) {
    controls = document.createElement('div');
    controls.id = 'cx-chapter-controls';
    controls.className = 'm';
    $('cx-pages').before(controls);
  }
  const chapters = d.chapters || [];
  const html = `${d.prev_url ? '<button class="more" data-comic-prev>Previous chapter</button>' : ''}
    ${chapters.length ? `<label>Chapter <select data-comic-chapter aria-label="Choose chapter">${chapters.map(row => `<option value="${esc(row.url)}"${row.selected ? ' selected' : ''}>${esc(row.title)}</option>`).join('')}</select></label>` : ''}
    ${d.next_url ? '<button class="more" data-comic-next>Next chapter</button>' : ''}`;
  if (controls.dataset.signature === html) return;
  controls.dataset.signature = html;
  controls.innerHTML = html;
  const previous = controls.querySelector('[data-comic-prev]');
  const next = controls.querySelector('[data-comic-next]');
  const select = controls.querySelector('[data-comic-chapter]');
  if (previous) previous.onclick = () => openComic(d.prev_url);
  if (next) next.onclick = () => openComic(d.next_url);
  if (select) select.onchange = () => openComic(select.value);
}

async function openComic(url){
  const generation = ++comicGeneration;
  clearInterval(cxPages);
  $('cx-pages').innerHTML = '';
  if ($('cx-chapter-controls')) { $('cx-chapter-controls').innerHTML = ''; delete $('cx-chapter-controls').dataset.signature; }
  try { await api('/comics/load?url=' + encodeURIComponent(url)); }
  catch { if (generation === comicGeneration) $('cx-progress').textContent = 'Could not open comic. Try again.'; return; }
  if (generation !== comicGeneration) return;
  $('cx-results').style.display = 'none';
  $('cx-more').style.display = 'none';
  $('cx-reader').style.display = '';
  $('cx-progress').innerHTML = '<span class="spin"></span> Loading pages…';
  clearInterval(cxPages);
  let ticks = 0;
  cxPages = settledInterval(async () => {
    ticks++;
    try {
      const d = await api('/comics');
      if (generation !== comicGeneration) return;
      // Download workers finish out of order; only request actual ready pages
      // and keep their nodes in reading order as earlier pages arrive.
      $('cx-progress').textContent = d.loading ? 'Loading chapter…' : d.pages
        ? `${d.title || 'Reading'} — ${d.downloaded}/${d.pages} pages`
        : 'Loading…';
      if (!d.loading) renderComicChapters(d);
      if (d.pages && !d.loading) {
        // Preserve already loaded image nodes while later pages arrive.
        const pages = $('cx-pages');
        const ready = d.ready_pages || Array.from({length:d.downloaded}, (_, i) => i);
        for (const i of ready) {
          if (pages.querySelector(`[data-page="${i}"]`)) continue;
          const image = document.createElement('img');
          image.className = 'cx-page';
          image.dataset.page = i;
          image.loading = 'lazy';
          image.alt = `Page ${i + 1}`;
          image.src = `${BASE}/api/comics/page?i=${i}&reader=${generation}`;
          const following = [...pages.querySelectorAll('.cx-page')].find(node => Number(node.dataset.page) > i);
          pages.insertBefore(image, following || null);
        }
      }
      if ((d.pages && !d.loading && d.downloaded >= d.pages) || (!d.loading && !d.pages) || ticks > 90) {
        clearInterval(cxPages);
        if (!d.pages) $('cx-progress').textContent = 'No readable pages found. Try another source or issue.';
        else if (d.downloaded < d.pages) $('cx-progress').textContent = `${d.title || 'Reading'} — ${d.downloaded}/${d.pages} pages loaded. Some pages could not load; try reopening this chapter.`;
      }
    } catch { clearInterval(cxPages); }
  }, 1200);
}
function closeComic(){
  ++comicGeneration;
  clearInterval(cxPages);
  api('/comics/close').catch(()=>{});
  $('cx-pages').innerHTML = '';
  $('cx-reader').style.display = 'none';
  $('cx-results').style.display = '';
  refreshComics().catch(()=>{});
}

// ── Novels: search → chapters → reader (one poll drives all three views) ──
function loadNovels(){ pollNovels(); }
function runNovels(){
  const q = $('nv-q').value.trim(); if (!q) return;
  $('nv-hint').textContent = 'Searching…';
  renderNovels({view:'search', results:[], loading:true});
  novelAction('/novels/search?q=' + encodeURIComponent(q));
}
async function novelAction(path){
  const generation = ++novelGeneration;
  clearInterval(nvWatch);
  try {
    await api(path);
    if (generation === novelGeneration) pollNovels();
  } catch {
    if (generation === novelGeneration) $('nv-hint').textContent = 'Could not load novels. Try again.';
  }
}
function pollNovels(){
  const generation = ++novelGeneration;
  clearInterval(nvWatch);
  let ticks = 0;
  nvWatch = settledInterval(async () => {
    ticks++;
    try {
      const d = await api('/novels');
      if (generation !== novelGeneration) return;
      renderNovels(d);
      const busy = d.loading || d.chapters_loading || d.text_loading || d.loading_more;
      if (!busy || ticks > BROWSE_POLL_LIMIT) { clearInterval(nvWatch); if (busy) failBrowse('nv-results', 'nv-hint', 'Still loading. Try again.'); }
    } catch {
      if (generation === novelGeneration) {
        clearInterval(nvWatch);
        $('nv-hint').textContent = 'Could not load novels. Try again.';
      }
    }
  }, BROWSE_POLL_MS, true);
}
function renderNovels(d){
  const busy = d.loading || d.chapters_loading || d.text_loading || d.loading_more;
  setBrowseBusy('nv-results', busy);
  let more = $('nv-more');
  if (!more) {
    more = document.createElement('button');
    more.id = 'nv-more'; more.className = 'more'; more.textContent = 'Load more';
    $('nv-results').after(more);
    more.onclick = () => novelAction('/novels/more');
  }
  more.hidden = d.view !== 'search' || !d.has_more;
  more.disabled = busy;
  $('nv-hint').innerHTML = busy ? '<span class="spin"></span> Loading…'
    : (d.error ? 'Fetch failed — try another source.' : esc(d.title || 'Search to begin.'));
  $('nv-crumbs').innerHTML = d.view === 'search' ? '' :
    `<button class="more" id="nv-back">‹ ${d.view === 'reader' ? 'Chapters' : 'Results'}</button>`;
  const back = $('nv-back');
  if (back) back.onclick = () => novelAction('/novels/back');
  const chapterAction = (path, ordinal) => novelAction('/novels/' + path + '?ordinal=' + ordinal + '&generation=' + d.chapter_generation);
  if (d.view === 'chapters') {
    const offset = d.chapter_offset || 0;
    $('nv-crumbs').insertAdjacentHTML('beforeend', '<button class="more" id="nv-resume">Resume reading</button>');
    $('nv-resume').onclick = () => novelAction('/novels/resume?generation=' + d.chapter_generation);
    $('nv-crumbs').insertAdjacentHTML('beforeend', `${offset ? '<button class="more" id="nv-window-prev">Previous chapters</button>' : ''}<span> ${offset + 1}–${offset + (d.chapters || []).length} of ${d.chapter_total || 0}${d.chapter_has_more ? '+' : ''} </span>${d.chapter_has_more ? '<button class="more" id="nv-window-next">Next chapters</button>' : ''}`);
    if ($('nv-window-prev')) $('nv-window-prev').onclick = () => chapterAction('window', Math.max(0, offset - 400));
    if ($('nv-window-next')) $('nv-window-next').onclick = () => chapterAction('window', offset + 400);
  }
  if (d.view === 'reader') {
    $('nv-crumbs').insertAdjacentHTML('beforeend', `${d.current_chapter > 0 ? '<button class="more" id="nv-reader-prev">Previous chapter</button>' : ''}${d.current_chapter + 1 < d.chapter_total || d.chapter_has_more ? '<button class="more" id="nv-reader-next">Next chapter</button>' : ''}`);
    if ($('nv-reader-prev')) $('nv-reader-prev').onclick = () => chapterAction('chapter', d.current_chapter - 1);
    if ($('nv-reader-next')) $('nv-reader-next').onclick = () => chapterAction('chapter', d.current_chapter + 1);
    $('nv-results').innerHTML = '';
    $('nv-text').textContent = d.text || '';
    $('nv-text').style.display = '';
    return;
  }
  $('nv-text').style.display = 'none';
  const rows = d.view === 'chapters' ? (d.chapters || []) : (d.results || []);
  const kind = d.view === 'chapters' ? 'chapter' : 'open';
  const target = $('nv-results');
  const html = rows.map((r, i) => `
    <div class="result">
      ${unifiedArtwork(r.cover) ? `<img class="thumb" src="${esc(unifiedArtwork(r.cover))}" alt="" loading="lazy" referrerpolicy="no-referrer">` : ''}
      <div class="t">${esc(r.title)}</div>
      ${r.author || r.year ? `<div class="m">${esc([r.author, r.year || ''].filter(Boolean).join(' · '))}</div>` : ''}
      ${r.overview ? `<div class="m" title="${esc(r.overview)}">${esc(r.overview.slice(0, 180))}${r.overview.length > 180 ? '…' : ''}</div>` : ''}
      <div class="m"><button class="novel-details" data-details="${i}" data-kind="${kind}">Details</button>
        <button class="play" data-nv="${i}" data-kind="${kind}">${kind === 'open' ? 'Open' : 'Read'}</button></div>
    </div>`).join('') || (busy ? browseLoadingHtml('row') : '<div class="empty">Nothing here</div>');
  if (!setSafeHtml(target, html)) return;
  target.querySelectorAll('button[data-nv]').forEach(b => {
    b.onclick = () => {
      const i = +b.dataset.nv;
      if (b.dataset.kind === 'open') novelIdx = i;
      if (b.dataset.kind === 'open') novelAction('/novels/open?idx=' + i);
      else chapterAction('chapter', (d.chapter_offset || 0) + i);
    };
  });
  target.querySelectorAll('.novel-details').forEach(button => {
    const row = rows[Number(button.dataset.details)] || {};
    button.onclick = () => openSourceDetails('Novel', {
      ...row, name:row.title, artUrl:row.cover || '', author:row.author || '', overview:row.overview || '', year:row.year || 0, type:button.dataset.kind === 'chapter' ? 'Chapter' : 'Novel',
      kind:button.dataset.kind === 'chapter' ? 'chapter' : 'novel', index:Number(button.dataset.details),
    }, button);
  });
}

// ── Drama (keyless: TVmaze on-air feed + title search; TMDB discover when a key is set) ──
let dramaGeneration = 0;
let dramaSource = 'tvmaze';
// TMDB rows carry a "/abc.jpg" path, TVmaze rows a full https image URL.
function dramaPoster(path, size){
  if (!path) return '';
  return /^https:\/\//.test(path) ? path : `https://image.tmdb.org/t/p/${size}${path}`;
}
async function refreshDrama(generation = dramaGeneration){
  const d = await api('/drama');
  if (generation !== dramaGeneration) return d;
  dramaSource = d.source || 'tvmaze';
  renderDrama(d.results || [], d.loading);
  $('dr-more').style.display = d.has_more ? '' : 'none';
  return d;
}
function loadDrama(){ pollDrama(++dramaGeneration); }
function pollDrama(generation){
  clearInterval(drWatch);
  let ticks = 0;
  const tick = async () => {
    ticks++;
    try {
      const d = await refreshDrama(generation);
      if (generation !== dramaGeneration) return;
      if (!d.loading || ticks > 120) {
        clearInterval(drWatch);
        const n = (d.results || []).length;
        if (d.loading) failBrowse('dr-results', 'dr-hint', 'Still loading. Try again.');
        else if (d.failed && !n) failBrowse('dr-results', 'dr-hint', 'Could not load Asian dramas. Check your connection and try again.');
        else if (d.search) $('dr-hint').textContent = n ? n + ' matching titles.' : 'No Korean, Japanese, Chinese or Thai drama matches that title.';
        else $('dr-hint').textContent = n + (d.source === 'tvmaze' ? ' titles on air this week.' : ' titles.');
      }
    } catch { if (generation === dramaGeneration) { clearInterval(drWatch); failBrowse('dr-results', 'dr-hint', 'Could not load Asian dramas. Try again.'); } }
  };
  drWatch = settledInterval(tick, BROWSE_POLL_MS, true);
}
async function runDrama(){
  const q = $('dr-q').value.trim();
  const generation = ++dramaGeneration;
  clearInterval(drWatch);
  $('dr-hint').textContent = q ? 'Searching…' : 'Loading…';
  lastHtml.drama = '';
  renderDrama([], true);
  try {
    await api('/drama/search?q=' + encodeURIComponent(q));
    if (generation === dramaGeneration) pollDrama(generation);
  } catch { if (generation === dramaGeneration) failBrowse('dr-results', 'dr-hint', 'Could not search Asian dramas. Try again.'); }
}
async function showDramaEpisodes(index, target){
  target.style.whiteSpace = 'pre-line'; target.style.maxHeight = '40vh'; target.style.overflow = 'auto';
  const base = target.dataset.base || '';
  for (let tick = 0; tick < 40; tick++) {
    const d = await api('/drama/episodes?idx=' + encodeURIComponent(index));
    if (d.state === 'ready') {
      target.textContent = (base ? base + '\n\n' : '') + (d.results.length
        ? d.results.map(e => `S${e.season} ${e.number ? 'E' + String(e.number).padStart(2, '0') : 'Special'}  ${e.name}${e.airdate ? '  (' + e.airdate + ')' : ''}`).join('\n')
        : 'No episodes listed yet.');
      return;
    }
    if (d.state === 'failed') { target.textContent = (base ? base + '\n\n' : '') + 'Could not load the episode list.'; return; }
    target.textContent = (base ? base + '\n\n' : '') + 'Loading episodes…';
    await new Promise(resolve => setTimeout(resolve, 500));
  }
}
function renderDrama(rows, loading = false){
  setBrowseBusy('dr-results', loading);
  const html = rows.map((r, i) => `
    <div class="card ${r.poster_path ? '' : 'poster-missing'}">
      ${r.poster_path ? `<img src="${esc(dramaPoster(r.poster_path, 'w342'))}" alt="" loading="lazy" decoding="async">` : ''}
      <div class="jf-card-actions">
        <button class="drama-details" data-details="${i}" aria-label="Details">${mediaIcon('info')}</button>
        <button class="play" data-i="${i}" aria-label="Play on Opal" title="Play on Opal">${mediaIcon('play')}</button>
      </div>
      <div class="cap" title="${esc(r.name)}">${esc(r.name)}</div>
      <div class="browse-card-meta">
        <span>${esc(r.year || 'TV series')}</span>
        ${r.vote ? `<span class="rt">★ ${Number(r.vote).toFixed(1)}</span>` : ''}
      </div>
    </div>`).join('') || (loading ? browseLoadingHtml('poster') : '<div class="empty">No titles yet</div>');
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
      artUrl:dramaPoster(drama.poster_path, 'w500'), index:Number(button.dataset.details), episodes:dramaSource === 'tvmaze',
    }, button);
  });
}

// ── VNDB (catalog only — visual novels aren't launchable) ──
let vndbGeneration = 0;
function loadVndb(){ pollVndb(++vndbGeneration); }
async function runVndb(){
  const q = $('vn-q').value.trim(); if (!q) return;
  const generation = ++vndbGeneration;
  clearInterval(vnWatch);
  $('vn-hint').textContent = 'Searching…';
  renderVndb([], true);
  try {
    await api('/vndb/search?q=' + encodeURIComponent(q));
    if (generation === vndbGeneration) pollVndb(generation);
  } catch { if (generation === vndbGeneration) failBrowse('vn-results', 'vn-hint', 'Could not search visual novels. Try again.'); }
}
function pollVndb(generation = vndbGeneration){
  clearInterval(vnWatch);
  let ticks = 0;
  vnWatch = settledInterval(async () => {
    try {
      const d = await api('/vndb');
      if (generation !== vndbGeneration) return;
      renderVndb(d.results || [], d.loading);
      if (!d.loading || ++ticks > 120) {
        clearInterval(vnWatch);
        if (d.loading) failBrowse('vn-results', 'vn-hint', 'Still loading. Search again to retry.');
        else $('vn-hint').textContent = (d.results || []).length + (d.popular ? ' popular' : '') + ' titles.';
      }
    } catch { if (generation === vndbGeneration) { clearInterval(vnWatch); failBrowse('vn-results', 'vn-hint', 'Could not load visual novels. Try again.'); } }
  }, BROWSE_POLL_MS, true);
}
function renderVndb(rows, loading = false){
  setBrowseBusy('vn-results', loading);
  const html = rows.map((r, i) => `
    <div class="result">
      ${r.cover ? `<img class="thumb" src="${esc(r.cover)}" alt="" loading="lazy">` : ''}
      <div class="t">${esc(r.title)}</div>
      <div class="m">
        ${r.released ? `<span class="src">${esc(r.released)}</span>` : ''}
        ${r.rating ? `<span>★ ${r.rating}</span>` : ''}
        <button class="vndb-details" data-details="${i}">Details</button>
      </div>
      <div class="sub">${esc((r.description || '').slice(0, 220))}</div>
    </div>`).join('') || (loading ? browseLoadingHtml('row') : '<div class="empty">No titles yet</div>');
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
let absRestoreRequested = false;
function loadAbs(){ absRestoreRequested = false; pollAbs(); }
function pollAbs(){
  clearInterval(absWatch);
  let ticks = 0;
  const tick = async () => {
    ticks++;
    try {
      const d = await api('/abs');
      renderAbs(d);
      if (!d.loading && !d.loading_more && !d.audio?.loading && ticks > 1) clearInterval(absWatch);
    } catch (error) { clearInterval(absWatch); $('abs-hint').textContent = error?.message || 'Could not refresh Audiobookshelf.'; }
  };
  absWatch = settledInterval(tick, 900, true);
}
function renderAbs(d){
  $('abs-login').style.display = d.connected ? 'none' : '';
  $('abs-session').hidden = !d.connected;
  if (!d.connected && d.server && !$('abs-server').value) $('abs-server').value = d.server;
  $('abs-hint').innerHTML = d.loading || d.audio?.loading ? '<span class="spin"></span> Loading…'
    : esc(d.error || (d.connected ? (d.library || 'Pick a library') : 'Sign in to your Audiobookshelf server.'));
  if (d.connected && d.audio?.visible) {
    const audio = d.audio, tracks = audio.tracks || [], target = $('abs-results');
    $('abs-crumbs').innerHTML = '<button class="more" id="abs-audio-back">Back to library</button>';
    $('abs-audio-back').onclick = async () => {
      try { await apiMutation('/abs/audio/close'); pollAbs(); }
      catch (error) { toast(error.message || 'Could not close track selection'); }
    };
    const html = `<div class="hint">${esc(audio.title || 'Audio files')} · ${audio.returned || 0} available of ${audio.total || 0}</div>`
      + (audio.complete_book ? '<div class="hint">Book tracks advance automatically and resume across files.</div><button class="more" id="abs-play-book">Play book from saved position</button>' : '<div class="hint">Choose an individual audio file or podcast episode.</div>')
      + (audio.loading ? '<div class="empty"><span class="spin"></span> Loading audio files…</div>' : tracks.map(track =>
        `<div class="result"><div class="t">${esc(track.title)}</div><div class="m"><span class="src">${track.episode ? 'Podcast episode' : 'Audio track'}</span><button class="play" data-audio="${track.index}">Play on Opal</button></div></div>`).join('')
        || '<div class="empty">No playable audio files found.</div>');
    const changed = setSafeHtml(target, html);
    if ($('abs-play-book')) $('abs-play-book').onclick = async () => {
      try { await apiMutation('/abs/audio/book?generation=' + encodeURIComponent(audio.generation)); toast('Playing book from its saved position'); }
      catch (error) { toast(error.message || 'Could not play the complete book'); }
    };
    if (changed) target.querySelectorAll('button[data-audio]').forEach(button => {
      button.onclick = async () => {
        button.disabled = true;
        try {
          await apiMutation('/abs/audio?idx=' + encodeURIComponent(button.dataset.audio) + '&generation=' + encodeURIComponent(audio.generation));
          button.textContent = 'Sent'; toast('Playing selected audio file on Opal');
        } catch (error) { button.disabled = false; toast(error.message || 'Could not play this audio file'); }
      };
    });
    return;
  }
  const books = d.view === 'Books';
  if (d.connected && !d.loading && !books && !(d.libraries || []).length && !absRestoreRequested) {
    absRestoreRequested = true;
    apiMutation('/abs/libraries').catch(error => { $('abs-hint').textContent = error.message || 'Could not restore libraries.'; });
  }
  $('abs-crumbs').innerHTML = books ? '<button class="more" id="abs-back">‹ Libraries</button>' : '';
  if ($('abs-back')) $('abs-back').onclick = () => { apiMutation('/abs/back').catch(()=>{}); pollAbs(); };
  const rows = books ? (d.books || []) : (d.libraries || []);
  const target = $('abs-results');
  const html = (rows.map((r, i) => `
    <div class="result">
      <div class="t">${esc(r.title || r.name)}</div>
      <div class="m">
        ${r.author ? `<span class="src">${esc(r.author)}</span>` : ''}
        ${r.media_type ? `<span class="src">${esc(r.media_type)}</span>` : ''}
        ${r.duration ? `<span>${fmt(r.duration)}</span>` : ''}
        ${books ? `<button class="abs-details" data-details="${i}">Details</button>` : ''}
        <button class="play" data-i="${i}">${books ? 'Open audio' : 'Open'}</button></div>
    </div>`).join('') || (d.connected ? '<div class="empty">Nothing here</div>' : ''))
    + (books && d.has_more ? `<button class="more" id="abs-more"${d.loading_more ? ' disabled' : ''}>${d.loading_more ? 'Loading…' : 'Load more'}</button>` : '');
  if (!setSafeHtml(target, html)) return;
  if ($('abs-more')) $('abs-more').onclick = async () => {
    try { await apiMutation('/abs/more'); pollAbs(); }
    catch (error) { toast(error.message || 'Could not load more books'); }
  };
  target.querySelectorAll('button[data-i]').forEach(b => {
    b.onclick = async () => {
      try { await apiMutation('/abs/' + (books ? 'play' : 'open') + '?idx=' + b.dataset.i); pollAbs(); }
      catch (error) { toast(error.message || 'Could not open this item'); }
    };
  });
  target.querySelectorAll('.abs-details').forEach(button => {
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
let opdsRestoreRequested = false;
function loadOpds(){ opdsRestoreRequested = false; pollOpds(); }
function pollOpds(){
  clearInterval(opWatch);
  let ticks = 0;
  const tick = async () => {
    ticks++;
    try {
      const d = await api('/opds');
      renderOpds(d);
      if (!d.loading || ticks > 120) clearInterval(opWatch);
    } catch { clearInterval(opWatch); }
  };
  opWatch = settledInterval(tick, BROWSE_POLL_MS, true);
}
function renderOpds(d){
  setBrowseBusy('opds-results', d.loading);
  $('opds-login').style.display = d.connected ? 'none' : '';
  $('opds-session').hidden = !d.connected;
  if (!d.connected && d.server && !$('opds-server').value) $('opds-server').value = d.server;
  if (d.connected && !d.loading && !(d.entries || []).length && !opdsRestoreRequested) {
    opdsRestoreRequested = true;
    apiMutation('/opds/connect').catch(error => { $('opds-hint').textContent = error.message || 'Could not restore catalog.'; });
  }
  $('opds-hint').innerHTML = d.loading ? '<span class="spin"></span> Loading…'
    : (d.error ? esc(d.message || 'Connection failed') : (d.connected ? (d.feed || '') : 'Point this at any OPDS catalog (Komga, Kavita, Calibre-Web, LANraragi).'));
  $('opds-crumbs').innerHTML = d.depth > 0 ? '<button class="more" id="opds-back">‹ Back</button>' : d.discovery ? `<span class="src">Discover</span>${(d.categories || []).map(c => `<button class="more" data-opds-category="${Number(c.index)}">${esc(c.title)}</button>`).join('')}` : '';
  $('opds-crumbs').querySelectorAll('[data-opds-category]').forEach(button => button.onclick = async () => {
    try { await apiMutation('/opds/category?idx=' + button.dataset.opdsCategory); pollOpds(); }
    catch { $('opds-hint').textContent = 'Could not load this collection. Try again.'; }
  });
  if ($('opds-back')) $('opds-back').onclick = () => { apiMutation('/opds/back').catch(()=>{}); pollOpds(); };
  const target = $('opds-results');
  const html = (d.entries || []).map((e, i) => `
    <div class="result">
      ${unifiedArtwork(e.cover) ? `<img class="thumb" src="${esc(unifiedArtwork(e.cover))}" alt="" loading="lazy" decoding="async">` : ''}
      <div class="t">${esc(e.title)}</div>
      ${e.author ? `<div class="m">${esc(e.author)}</div>` : ''}
      <div class="m">
        ${e.gutenberg ? '<span class="src">Project Gutenberg</span>' : e.nav ? '<span class="src">folder</span>' : ''}
        ${e.streamable ? `<span class="src">${e.pages} pages</span>` : ''}
        <button class="opds-details" data-details="${i}">Details</button>
        <button class="play" data-i="${i}">${e.gutenberg || !e.nav ? 'Read' : 'Open'}</button></div>
    </div>`).join('') || (d.loading ? browseLoadingHtml('row') : d.connected ? '<div class="empty">Empty feed</div>' : '');
  if (!setSafeHtml(target, html)) return;
  target.querySelectorAll('button[data-i]').forEach(b => {
    b.onclick = async () => {
      try {
        await apiMutation('/opds/open?idx=' + b.dataset.i + (Number.isSafeInteger(d.generation) ? '&generation=' + d.generation : ''));
        if ((d.entries || [])[Number(b.dataset.i)]?.gutenberg) openPage('novels');
        else pollOpds();
      } catch { $('opds-hint').textContent = 'Could not open this book. Try again.'; }
    };
  });
  target.querySelectorAll('.opds-details').forEach(button => {
    const entry = (d.entries || [])[Number(button.dataset.details)] || {};
    button.onclick = () => openSourceDetails('OPDS', {
      ...entry, name:entry.title, type:entry.gutenberg ? 'Book' : entry.nav ? 'Collection' : (entry.type || 'Publication'),
      meta:entry.streamable ? `${entry.pages} pages` : '', index:Number(button.dataset.details),
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
function pollPlex(){
  clearInterval(plWatch);
  let ticks = 0;
  plWatch = settledInterval(async () => {
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
    : (d.sections || []).map((section, i) => `<button class="more${i === d.active_section ? ' on' : ''}" data-plex-section="${esc(section.key || '')}">${esc(section.title)}</button>`).join('');
  if ($('plex-back')) $('plex-back').onclick = () => { apiMutation('/plex/back').catch(()=>{}); pollPlex(); };
  $('plex-crumbs').querySelectorAll('[data-plex-section]').forEach(button => {
    button.onclick = () => { apiMutation('/plex/open?key=' + encodeURIComponent(button.dataset.plexSection)).catch(()=>{}); pollPlex(); };
  });
  const rows = browsing ? (d.items || []) : (d.sections || []);
  const target = $('plex-results');
  const html = rows.map((r, i) => `
    <div class="result">
      ${r.cover ? `<img class="thumb" src="${esc(r.cover)}" alt="" loading="lazy">` : ''}
      <div class="t">${esc(r.title)}</div>
      <div class="m">
        ${r.year ? `<span class="src">${esc(r.year)}</span>` : ''}
        ${browsing && r.type ? `<span class="src">${esc(r.type)}</span>` : ''}
        ${browsing && r.duration ? `<span class="src">${r.played ? 'Watched' : (r.progress ? `${fmt(r.progress)} / ${fmt(r.duration)}` : fmt(r.duration))}</span>` : ''}
        ${browsing && !r.folder ? `<button class="plex-favorite" data-id="${esc(r.id || '')}" data-enabled="${!r.favorite}" aria-label="${r.favorite ? 'Remove favorite' : 'Add favorite'}" title="${r.favorite ? 'Remove favorite' : 'Add favorite'}">${r.favorite ? '&#9733;' : '&#9734;'}</button>` : ''}
        ${browsing && !r.folder ? `<button class="plex-watched" data-id="${esc(r.id || '')}" data-enabled="${!r.played}" aria-label="${r.played ? 'Mark unwatched' : 'Mark watched'}" title="${r.played ? 'Mark unwatched' : 'Mark watched'}">${r.played ? '&#10003;' : '&#9675;'}</button>` : ''}
        ${browsing && !r.folder ? `<select class="plex-rating" data-id="${esc(r.id || '')}" aria-label="Rate ${esc(r.title)}">${plexRatingOptions(r.rating)}</select>` : ''}
        ${browsing ? `<button class="plex-details" data-i="${i}">Details</button>` : ''}
        <button class="play" data-i="${i}" data-id="${browsing ? esc(r.id || '') : ''}">${browsing ? (r.folder ? 'Open' : (r.progress && !r.played ? 'Resume on Opal' : 'Play on Opal')) : 'Open'}</button></div>
      ${items && r.duration && r.progress ? `<div class="plex-progress"><i style="width:${Math.min(100,Math.round(r.progress/r.duration*100))}%"></i></div>` : ''}
    </div>`).join('') || (d.connected ? '<div class="empty">Nothing here</div>' : '');
  if (!setSafeHtml(target, html)) return;
  target.querySelectorAll('button[data-i]').forEach(b => {
    b.onclick = () => {
      const row = rows[Number(b.dataset.i)] || {};
      const request = browsing
        ? apiMutation('/plex/' + (row.folder ? 'open_item' : 'play') + '?id=' + encodeURIComponent(b.dataset.id))
        : apiMutation('/plex/open?key=' + encodeURIComponent(row.key || ''));
      request.catch(()=>{}); pollPlex();
    };
  });
  target.querySelectorAll('.plex-watched').forEach(button => {
    button.onclick = async () => {
      button.disabled = true;
      try {
        await apiMutation('/plex/action?id=' + encodeURIComponent(button.dataset.id) +
          '&action=played&enabled=' + button.dataset.enabled);
        pollPlex();
      } catch (error) { button.disabled = false; toast(error.message || 'Could not update watched state.'); }
    };
  });
  target.querySelectorAll('.plex-favorite').forEach(button => {
    button.onclick = async () => {
      button.disabled = true;
      try {
        await apiMutation('/plex/action?id=' + encodeURIComponent(button.dataset.id) +
          '&action=favorite&enabled=' + button.dataset.enabled);
        pollPlex();
      } catch (error) { button.disabled = false; toast(error.message || 'Could not update favorite.'); }
    };
  });
  target.querySelectorAll('.plex-rating').forEach(select => {
    select.onchange = async () => {
      select.disabled = true;
      try {
        await apiMutation('/plex/action?id=' + encodeURIComponent(select.dataset.id) +
          '&action=rating&rating=' + encodeURIComponent(select.value));
        pollPlex();
      } catch (error) { select.disabled = false; toast(error.message || 'Could not update rating.'); }
    };
  });
  target.querySelectorAll('.plex-details').forEach(button => {
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
  const perfNode = $('web-perf');
  const verdict = perf.within_budget === null ? 'Measuring budget' : perf.within_budget ? 'Within budget' : 'Over budget';
  perfNode.dataset.state = perf.within_budget === null ? 'measuring' : perf.within_budget ? 'pass' : 'fail';
  perfNode.textContent = `${verdict} · Shell ${metric(perf.shell_ms)} / ${perf.budget.shell_ms} ms · Interaction p95 ${metric(perf.interaction_p95_ms)} / ${perf.budget.interaction_p95_ms} ms (${perf.interaction_count}) · Long task max ${Math.round(perf.long_task_max_ms)} / ${perf.budget.long_task_max_ms} ms`;
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

// ── Parity tier 2 controls ──
const onGo = (btn, input, fn) => {
  $(btn).onclick = () => fn();
  $(input).addEventListener('keydown', e => { if (e.key === 'Enter') { fn(); $(input).blur(); } });
};
onGo('cx-go', 'cx-q', runComics);
onGo('nv-go', 'nv-q', runNovels);
onGo('vn-go', 'vn-q', runVndb);
onGo('dr-go', 'dr-q', runDrama);
$('cx-close').onclick = () => closeComic();
function wireInfiniteBrowse(page, buttonId, morePath, refresh, currentGeneration = () => 0){
  const button = $(buttonId);
  let pending = false;
  const more = async () => {
    if (pending || button.style.display === 'none' || currentPage !== page) return;
    const generation = currentGeneration();
    pending = true; button.disabled = true; button.textContent = 'Loading…';
    try {
      await api(morePath);
      for (let attempt = 0; attempt < 30; attempt++) {
        await new Promise(resolve => setTimeout(resolve, 250));
        if (generation !== currentGeneration() || currentPage !== page) break;
        const data = await refresh(generation);
        if (!data?.loading_more) break;
      }
    }
    catch { toast('Could not load more. Try again.'); }
    finally { pending = false; button.disabled = false; button.textContent = 'Load more'; }
  };
  button.onclick = more;
  if ('IntersectionObserver' in window) {
    const observer = new IntersectionObserver(entries => {
      if (entries.some(entry => entry.isIntersecting)) more();
    }, {rootMargin:'700px 0px'});
    observer.observe(button);
  }
}
wireInfiniteBrowse('drama', 'dr-more', '/drama/more', refreshDrama);
wireInfiniteBrowse('anime', 'anime-more', '/anime/more', loadAnime, () => animeBrowseGeneration);
wireInfiniteBrowse('comics', 'cx-more', '/comics/more', refreshComics, () => comicSearchGeneration);
$('abs-go').onclick = async () => {
  const button = $('abs-go'); button.disabled = true;
  try {
    await apiFormMutation('/abs/login', {
      server:$('abs-server').value.trim(), user:$('abs-user').value, pass:$('abs-pass').value,
    });
    pollAbs();
  } catch (error) { $('abs-hint').textContent = error.message || 'Could not connect.'; }
  finally { $('abs-pass').value = ''; button.disabled = false; }
};
$('abs-out').onclick = async () => { await apiMutation('/abs/logout').catch(error => toast(error.message)); pollAbs(); };
$('abs-edit').onclick = () => $('abs-out').click();
$('opds-go').onclick = async () => {
  const button = $('opds-go'); button.disabled = true;
  try {
    await apiFormMutation('/opds/connect', {
      server:$('opds-server').value.trim(), user:$('opds-user').value, pass:$('opds-pass').value,
    });
    pollOpds();
  } catch (error) { $('opds-hint').textContent = error.message || 'Could not connect.'; }
  finally { $('opds-pass').value = ''; button.disabled = false; }
};
$('opds-out').onclick = async () => { await apiMutation('/opds/disconnect').catch(error => toast(error.message)); pollOpds(); };
$('opds-edit').onclick = () => $('opds-out').click();
$('plex-go').onclick = () => { apiMutation('/plex/connect').catch(()=>{}); pollPlex(); };
$('plex-out').onclick = () => { apiMutation('/plex/disconnect').catch(()=>{}); pollPlex(); };
$('lg-refresh').onclick = () => loadLogs();
$('lg-errors').onclick = () => {
  logErrorsOnly = !logErrorsOnly;
  $('lg-errors').classList.toggle('on', logErrorsOnly);
  loadLogs();
};
$('lg-clear').onclick = () => { api('/logs/clear').catch(()=>{}); loadLogs(); };

// Broken provider artwork retains a visible, sized fallback and its title/actions.
function handlePosterFailure(image){
  if (!image || image.tagName !== 'IMG') return;
  if (image.closest('.result.pod')) {
    const placeholder = document.createElement('div');
    placeholder.className = 'thumb poster-placeholder';
    placeholder.textContent = '♪';
    placeholder.setAttribute('aria-label', 'Artwork unavailable');
    image.replaceWith(placeholder);
    return;
  }
  const card = image.closest('.card');
  if (!card) return;
  image.hidden = true;
  card.classList.add('poster-missing');
}
document.addEventListener('error', event => handlePosterFailure(event.target), true);

if ($('cx-source')) $('cx-source').onchange = () => { runComics(); };
