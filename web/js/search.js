'use strict';

// ── Search ──
let searchWatch = null;
$('go').onclick = () => runSearch();
$('q').addEventListener('keydown', e => { if (e.key === 'Enter') { runSearch(); $('q').blur(); } });

function remoteOpenUrl(url, title){
  return api('/open?url=' + encodeURIComponent(url) + (title ? '&title=' + encodeURIComponent(title) : ''));
}
async function queueMedia(url, title, button){
  if (!url) return;
  if (button) { button.disabled = true; button.textContent = 'Adding…'; }
  try {
    await api('/ingest?type=queue&url=' + encodeURIComponent(url)
      + (title ? '&title=' + encodeURIComponent(title) : ''));
    if (button) button.textContent = 'Queued ✓';
    toast('Added to queue');
  } catch {
    if (button) { button.disabled = false; button.textContent = 'Retry queue'; }
    toast('Could not add to queue');
  }
}
function playMediaUrl(url, title, button){
  if (!url) return;
  const fallback = () => remoteOpenUrl(url, title).then(() => {
    if (button) button.textContent = 'Sent ✓';
  }).catch(() => { if (button) button.textContent = 'Retry'; });
  dispatchPlay(url, title || url, fallback, title || url);
}

$('open-media-form').addEventListener('submit', e => {
  e.preventDefault();
  const url = $('open-url').value.trim(), title = $('open-title').value.trim();
  if (!url) { $('open-hint').textContent = 'Paste a URL or magnet first.'; return; }
  $('open-hint').textContent = PLAY_HERE ? 'Opening…' : 'Sending to Opal…';
  playMediaUrl(url, title, $('open-play'));
});
$('open-queue').onclick = async () => {
  const url = $('open-url').value.trim(), title = $('open-title').value.trim();
  if (!url) { $('open-hint').textContent = 'Paste a URL or magnet first.'; return; }
  await queueMedia(url, title, $('open-queue'));
  $('open-hint').textContent = 'Added to the Opal queue.';
};

let unifiedSearchRun = 0;
let unifiedSearchPayload = null;
const searchFilterIds = ['search-content', 'search-availability', 'search-quality', 'search-seeds', 'search-size', 'search-provider'];
const searchFilterDefaults = ['all', 'all', '0', '0', '0', ''];
const searchContentLabels = {all:'Everything', video:'Video', movies:'Movies', shows:'Shows', anime:'Anime', comics:'Comics', books:'Books & audiobooks', music:'Music', podcasts:'Podcasts', radio:'Radio', live_tv:'Live TV', visual_novels:'Visual novels'};
$('search-filters-toggle').onclick = () => {
  const open = $('search-filters').hidden;
  $('search-filters').hidden = !open;
  $('search-filters-toggle').setAttribute('aria-expanded', String(open));
  if (open) $('search-content').focus();
};
$('search-filters').addEventListener('keydown', event => {
  if (event.key !== 'Escape') return;
  $('search-filters').hidden = true;
  $('search-filters-toggle').setAttribute('aria-expanded', 'false');
  $('search-filters-toggle').focus();
});
for (const id of [...searchFilterIds, 'search-sort']) $(id).addEventListener('change', () => {
  renderSearchFilterChips();
  if (unifiedSearchPayload) renderUnifiedResults(unifiedSearchPayload);
});
$('search-retry').onclick = () => runSearch();
$('search-source-settings').onclick = () => openPage('setup');
function searchFilters(){
  const values = searchFilterIds.map((id, i) => $(id).value || searchFilterDefaults[i]);
  const gb = 1024 ** 3;
  const sizes = [[0, 0], [0, gb - 1], [gb, 5 * gb - 1], [5 * gb, 20 * gb - 1], [20 * gb, 0]];
  const size = sizes[Number(values[4])] || sizes[0];
  return {content:values[0], availability:values[1], quality:Number(values[2]) || 0,
    seeds:Number(values[3]) || 0, minSize:size[0], maxSize:size[1], provider:values[5]};
}
function unifiedSearchItem(row){
  const source = row.source || '', kind = row.content_kind || ({tmdb:row.media === 'tv' ? 'shows' : 'movies',
    anime:'anime', comics:'comics', novels:'books', opds:'books', audiobooks:'books', music:'music', podcast:'podcasts', radio:'radio', livetv:'live_tv', vndb:'visual_novels'}[source] || 'video');
  const number = (value, fallback = 0) => Number.isFinite(Number(value)) && Number(value) >= 0 ? Number(value) : fallback;
  return {kind, provider:row.provider || source, torrent:row.torrent ?? source === 'torrent',
    library:row.library ?? ['local', 'jellyfin', 'plex', 'audiobooks', 'opds'].includes(source),
    playable:row.playable ?? ['torrent', 'youtube', 'stremio', 'local', 'jellyfin', 'plex', 'music', 'radio', 'livetv', 'audiobooks'].includes(source),
    quality:number(row.quality), seeds:number(row.seeds), leech:number(row.leech), size:number(row.size_bytes), score:number(row.score, 9999), key:String(row.key || '').padStart(16, '0')};
}
function matchesSearchFilters(item, filters){
  if (filters.content !== 'all' && item.kind !== filters.content &&
      !(filters.content === 'video' && ['video', 'movies', 'shows', 'anime', 'live_tv'].includes(item.kind))) return false;
  if (filters.availability === 'playable' && !item.playable || filters.availability === 'torrents' && !item.torrent || filters.availability === 'library' && !item.library) return false;
  if (filters.provider && item.provider !== filters.provider || item.quality < filters.quality || item.seeds < filters.seeds) return false;
  if ((filters.minSize || filters.maxSize) && !item.size || item.size < filters.minSize || filters.maxSize && item.size > filters.maxSize) return false;
  return true;
}
function unifiedResultRows(payload){
  const filters = searchFilters(), sort = $('search-sort').value || 'relevance';
  const entries = payload.results.map(row => ({row, item:unifiedSearchItem(row)})).filter(({item}) => matchesSearchFilters(item, filters));
  entries.sort((a, b) => {
    const metric = item => ({quality:item.quality, seeds:item.seeds, size:item.size, peers:item.seeds + item.leech,
      health:item.seeds / Math.max(1, item.seeds + item.leech)})[sort] || 0;
    const order = sort === 'relevance' ? a.item.score - b.item.score : metric(b.item) - metric(a.item);
    return order || a.item.score - b.item.score || (a.item.key < b.item.key ? -1 : a.item.key > b.item.key ? 1 : 0);
  });
  return entries.map(({row}) => row);
}
function renderSearchFilterChips(){
  const sizeLabels = ['Any size', 'Under 1 GB', '1–5 GB', '5–20 GB', '20 GB or more'];
  const labels = [searchContentLabels[$('search-content').value],
    {playable:'Playable', torrents:'Torrents', library:'My libraries'}[$('search-availability').value],
    {1:'480p+', 2:'720p+', 3:'1080p+', 4:'4K'}[$('search-quality').value],
    `${$('search-seeds').value}+ seeds`, sizeLabels[Number($('search-size').value)], $('search-provider').value];
  const active = searchFilterIds.map((id, i) => ({id, index:i, value:$(id).value || searchFilterDefaults[i]})).filter(filter => filter.value !== searchFilterDefaults[filter.index]);
  $('search-active-filters').hidden = !active.length;
  const html = active.map(filter => `<button type="button" data-filter="${filter.id}" title="Remove filter">${esc(labels[filter.index] || filter.value)} ×</button>`).join('');
  if ($('search-active-filters').innerHTML === html) return;
  $('search-active-filters').innerHTML = html;
  $('search-active-filters').querySelectorAll('[data-filter]').forEach(button => button.onclick = () => {
    const index = searchFilterIds.indexOf(button.dataset.filter);
    if (index < 0) return;
    $(button.dataset.filter).value = searchFilterDefaults[index];
    renderSearchFilterChips();
    if (unifiedSearchPayload) renderUnifiedResults(unifiedSearchPayload);
  });
}
function renderSearchSources(payload){
  const names = {tmdb:'Movie & show catalog', local:'On disk', torrent:'Torrents', jellyfin:'Jellyfin', youtube:'YouTube', anime:'Anime', comics:'Comics', stremio:'Streams', rss:'RSS', livetv:'Live TV', music:'Music', radio:'Radio', podcast:'Podcasts', novels:'Novels', vndb:'Visual novels', audiobooks:'Audiobooks', opds:'OPDS', plex:'Plex', plugin:'Plugins'};
  const statuses = {idle:'Not queried', done:'Results ready', no_results:'No matches', unavailable:'Needs setup', partial:'Partial results', failed:'Failed', transport_failed:'Network error', parse_failed:'Invalid response', timed_out:'Timed out', searching:'Searching'};
  const sources = Array.isArray(payload.sources) ? payload.sources : [];
  const html = sources.map(source => `<div class="source-state${['failed', 'transport_failed', 'parse_failed', 'timed_out', 'partial'].includes(source.status) ? ' source-attention' : ''}"><span>${esc(names[source.source] || source.source)}</span><span>${esc(source.enabled ? statuses[source.status] || source.status : 'Disabled')}</span></div>`).join('');
  if ($('search-source-status').innerHTML !== html) $('search-source-status').innerHTML = html;
  const selected = $('search-provider').value || '';
  const providers = [...new Set(payload.results.map(row => row.provider || row.source).filter(Boolean))].sort();
  if (selected && !providers.includes(selected)) providers.push(selected);
  const options = '<option value="">All providers</option>' + providers.map(provider => `<option value="${esc(provider)}">${esc(provider)}</option>`).join('');
  if ($('search-provider').innerHTML !== options) $('search-provider').innerHTML = options;
  $('search-provider').value = selected;
}
async function runSearch(){
  const q = $('q').value.trim(); if (!q) return;
  const request = ++unifiedSearchRun;
  clearInterval(searchWatch);
  unifiedSearchPayload = null;
  if (/^(https?:\/\/|magnet:\?)/i.test(q)) {
    $('search-hint').textContent = 'Opening in Opal…';
    try {
      await remoteOpenUrl(q);
      if (request === unifiedSearchRun) $('search-hint').textContent = 'Opened in Opal.';
    } catch (error) {
      if (request === unifiedSearchRun) $('search-hint').textContent = error?.message || 'Could not open this link.';
    }
    return;
  }
  $('search-hint').innerHTML = '<span class="spin"></span> Searching all sources…';
  $('results').innerHTML = ''; lastHtml.results = '';
  let initial;
  try {
    initial = await api('/unified_search?q=' + encodeURIComponent(q));
    if (request !== unifiedSearchRun) return;
    renderUnifiedResults(initial);
    $('search-hint').textContent = unifiedResultCount(initial);
    if (!initial.loading) return;
  } catch (error) {
    if (request === unifiedSearchRun) $('search-hint').textContent = error?.message || 'Search could not start. Try again.';
    return;
  }
  searchWatch = settledInterval(async () => {
    try {
      const d = await api('/unified_search');
      if (request !== unifiedSearchRun) return;
      if (d.generation !== initial.generation) {
        clearInterval(searchWatch);
        $('search-hint').textContent = 'Search changed in another Opal view. Search again to refresh.';
        return;
      }
      renderUnifiedResults(d);
      $('search-hint').textContent = unifiedResultCount(d);
      if (!d.loading) clearInterval(searchWatch);
    } catch (error) {
      if (request !== unifiedSearchRun) return;
      clearInterval(searchWatch);
      $('search-hint').textContent = error?.message || 'Could not refresh search. Loaded results remain available.';
    }
  }, 900);
}
function unifiedResultCount(payload){
  const rows = Array.isArray(payload.results) ? unifiedResultRows(payload) : [];
  const returned = Number.isFinite(payload.returned) ? payload.returned : rows.length;
  const total = Number.isFinite(payload.total) ? payload.total : returned;
  const sources = new Set(rows.map(r => r.source).filter(Boolean));
  const unavailable = (payload.sources || []).filter(s => s.enabled &&
    ['failed', 'transport_failed', 'parse_failed', 'timed_out', 'partial'].includes(s.status));
  let text = rows.length < returned || payload.truncated || total > returned ? `Showing ${rows.length} of ${total} results` : `${rows.length} results`;
  text += ` across ${sources.size} source${sources.size === 1 ? '' : 's'}`;
  if (payload.loading) text += ' · Still searching';
  if (unavailable.length) text += ` · ${unavailable.length} source${unavailable.length === 1 ? ' needs' : 's need'} attention`;
  return text + '.';
}
function unifiedActionLabel(source){
  if (source === 'comics' || source === 'novels' || source === 'opds') return 'Read';
  if (source === 'vndb' || source === 'tmdb') return 'View details';
  if (source === 'audiobooks') return 'Open audio';
  if (source === 'podcast' || source === 'anime') return 'Open';
  return 'Play on Opal';
}
function unifiedArtwork(value){
  if (typeof value !== 'string' || !value) return '';
  try {
    const url = new URL(value);
    return ['https:', 'http:'].includes(url.protocol) && !url.username && !url.password ? url.href : '';
  } catch { return ''; }
}
function renderUnifiedResults(payload){
  if (payload?.error || !Array.isArray(payload?.results)) throw new Error(payload?.error || 'Search returned an invalid response. Try again.');
  unifiedSearchPayload = payload;
  renderSearchSources(payload);
  renderSearchFilterChips();
  $('search-hint').textContent = unifiedResultCount(payload);
  const shown = unifiedResultRows(payload), generation = payload.generation || 0;
  const html = shown.map((r, i) => {
    const artwork = unifiedArtwork(r.poster_url), rating = Number(r.rating);
    const item = unifiedSearchItem(r);
    const release = [({1:'480p', 2:'720p', 3:'1080p', 4:'4K'})[item.quality], item.size ? fmtSize(item.size) : '',
      item.torrent ? `${item.seeds} seeds · ${item.leech} peers` : ''].filter(Boolean).join(' · ');
    return `<div class="result pod unified-result">
      ${artwork ? `<img class="thumb" src="${esc(artwork)}" alt="" loading="lazy" referrerpolicy="no-referrer">` : ''}
      <div class="body"><div class="t">${esc(r.title)}</div>
      <div class="m"><span class="src">${esc(r.provider || (r.source === 'opds' ? 'OPDS' : (r.source || '')))}</span>
        ${r.author ? `<span>${esc(r.author)}</span>` : ''}
        ${release ? `<span>${esc(release)}</span>` : r.detail ? `<span>${esc(r.detail)}</span>` : ''}
        ${Number.isFinite(rating) && rating > 0 && rating <= 10 ? `<span>${rating.toFixed(1)}/10</span>` : ''}
        <span class="actions">
          ${r.queueable ? `<button class="queue-btn" data-i="${i}" data-gen="${generation}">Queue</button>` : ''}
          <button class="play" data-i="${i}" data-gen="${generation}"${r.key ? '' : ' disabled'}>${unifiedActionLabel(r.source)}</button>
        </span>
      </div>${r.summary ? `<div class="sub">${esc(r.summary)}</div>` : ''}</div>
    </div>`;
  }).join('') || `<div class="empty">${payload.results.length ? 'No results match these filters. Remove a filter to see more.' : payload.loading ? 'Searching sources…' : 'No results found. Try another title or check Sources in Filters.'}</div>`;
  if (html === lastHtml.results) return;
  lastHtml.results = html;
  $('results').innerHTML = html;
  $('results').querySelectorAll('.thumb').forEach(image => image.addEventListener('error', () => image.remove(), { once:true }));
  $('results').querySelectorAll('.play').forEach(b =>
    b.onclick = () => runUnifiedAction(shown[+b.dataset.i], +b.dataset.gen, 'play', b));
  $('results').querySelectorAll('.queue-btn').forEach(b =>
    b.onclick = () => runUnifiedAction(shown[+b.dataset.i], +b.dataset.gen, 'queue', b));
}
async function runUnifiedAction(r, generation, action, button){
  if (!r || !r.key) return;
  if (action === 'play' && r.source === 'tmdb' && r.media && r.id) {
    openDetails(r.media === 'tv' ? 'tv' : 'movie', +r.id, r.title || '', r.imdb || '');
    return;
  }
  button.disabled = true;
  button.textContent = action === 'queue' ? 'Adding...' : 'Opening...';
  try {
    await apiMutation('/unified_search/' + action + '?generation=' + generation + '&key=' + encodeURIComponent(r.key));
    button.textContent = action === 'queue' ? 'Queued' : 'Sent';
    toast(action === 'queue' ? 'Added to queue' : 'Opening in Opal');
  } catch (error) {
    button.disabled = false;
    button.textContent = action === 'queue' ? 'Retry queue' : unifiedActionLabel(r.source);
    toast(error?.message || 'Result changed; search again');
  }
}
function runStreamSearch(title){
  if (!title) return;
  $('q').value = title;
  $('search-availability').value = 'torrents';
  renderSearchFilterChips();
  return runSearch();
}

function renderTorrentResults(rs){
  // Sort by seeds, descending. The API returns results in ARRIVAL order — the
  // order engines happened to answer in — so a 0-seed academic torrent that
  // replied first outranked a 6130-seed release that replied second. Seeds are
  // the one signal that says "this will actually download", so they order the
  // list. Ties and unknown counts fall back to arrival order, which keeps the
  // sort stable rather than shuffling equal rows on every repaint.
  const seedsOf = (r) => { const n = parseInt(r.seeds, 10); return Number.isFinite(n) ? n : -1; };
  const ranked = rs.map((r, i) => [r, i])
                   .sort((a, b) => (seedsOf(b[0]) - seedsOf(a[0])) || (a[1] - b[1]))
                   .map(([r]) => r);
  const shown = ranked.slice(0, 60);
  const html = shown.map((r, i) => `
    <div class="result">
      <div class="t">${esc(r.title)}</div>
      <div class="m">
        ${r.seeds ? `<span>▲ ${esc(String(r.seeds))}</span>` : ''}
        ${fmtSize(r.size) ? `<span>${esc(fmtSize(r.size))}</span>` : ''}
        <span class="src">${esc(r.source || '')}</span>
        <span class="actions"><button class="queue-btn" data-i="${i}">Queue</button>
          <button class="play" data-i="${i}">Open on Opal</button></span>
      </div>
    </div>`).join('') || '<div class="empty">No results yet</div>';
  if (html === lastHtml.results) return;
  lastHtml.results = html;
  $('results').innerHTML = html;
  $('results').querySelectorAll('.play').forEach(b => b.onclick = () => {
    const r = shown[+b.dataset.i], u = r && (r.magnet || r.url || '');
    playMediaUrl(u, r?.title || '', b);
  });
  $('results').querySelectorAll('.queue-btn').forEach(b => b.onclick = () => {
    const r = shown[+b.dataset.i], u = r && (r.magnet || r.url || '');
    queueMedia(u, r?.title || '', b);
  });
}
