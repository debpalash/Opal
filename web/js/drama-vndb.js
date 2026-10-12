'use strict';

// Drama and visual-novel browse pages. Loaded after media.js, which owns the
// shared wiring helpers (onGo, wireInfiniteBrowse) and the drWatch/vnWatch handles.

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

// ── Wiring ──
onGo('vn-go', 'vn-q', runVndb);
onGo('dr-go', 'dr-q', runDrama);
wireInfiniteBrowse('drama', 'dr-more', '/drama/more', refreshDrama);
