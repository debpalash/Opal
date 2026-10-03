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

$('search-cancel').onclick = async () => {
  const generation = unifiedSearchPayload?.generation;
  if (!Number.isInteger(generation)) return;
  const run = unifiedSearchRun;
  $('search-cancel').disabled = true;
  try {
    await apiMutation('/unified_search/cancel?generation=' + generation);
    if (run !== unifiedSearchRun) return;
    clearInterval(searchWatch);
    const stoppedRun = ++unifiedSearchRun;
    stopSearchPreview();
    // Cancellation advances the resolver wave. Refresh opaque action keys and
    // generation instead of leaving every retained card with a stale action.
    try {
      const snapshot = await api('/unified_search');
      if (stoppedRun !== unifiedSearchRun) return;
      if (snapshot.generation !== ((generation + 1) >>> 0)) throw new Error('Search changed in another Opal view. Search again to refresh.');
      renderUnifiedResults(snapshot);
      $('search-hint').textContent += ' Search stopped; loaded titles remain available.';
    } catch (error) {
      if (stoppedRun !== unifiedSearchRun) return;
      if (unifiedSearchPayload?.generation === generation) renderUnifiedResults({...unifiedSearchPayload, loading:false, results:unifiedSearchPayload.results.map(row => ({...row, key:'', queueable:false}))});
      $('search-hint').textContent = error?.message || 'Search stopped. Refresh before opening loaded titles.';
    }
  } catch (error) {
    if (run === unifiedSearchRun) $('search-hint').textContent = error?.message || 'Search changed; refresh before stopping it.';
  } finally { $('search-cancel').disabled = false; }
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
  $('search-cancel').hidden = true;
  renderSearchDetail(null);
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
const searchSavedState = new Map();
function searchSavedId(group){ return /^[a-f0-9]{1,16}$/i.test(group?.row?.work_key || '') ? group.row.work_key.toLowerCase() : ''; }
function updateSearchSaveButton(group, generation){
  const id = searchSavedId(group), button = $('search-save');
  if (!id || !button || selectedSearchWork?.identity !== group.identity || selectedSearchWork?.generation !== generation) return;
  const state = searchSavedState.get(id);
  button.disabled = !state || state.loading || state.saving;
  button.textContent = state?.saving ? 'Saving…' : state?.loading ? 'Checking saved state…' : state?.failed ? 'Retry saved state' : state?.favorite ? 'Saved ✓' : 'Save';
  button.setAttribute('aria-pressed', String(!!state?.favorite));
  button.onclick = () => state?.failed ? loadSearchSaveState(group, generation, true) : toggleSearchSave(group, generation);
}
async function loadSearchSaveState(group, generation, retry = false){
  const id = searchSavedId(group); if (!id) return;
  if (!retry && searchSavedState.has(id)) { updateSearchSaveButton(group, generation); return; }
  if (searchSavedState.size >= 32 && !searchSavedState.has(id)) searchSavedState.delete(searchSavedState.keys().next().value);
  const state = {loading:true,saving:false,favorite:false,failed:false};
  searchSavedState.set(id, state); updateSearchSaveButton(group, generation);
  try {
    const item = await api('/library/item?kind=search&id=' + encodeURIComponent(id));
    if (typeof item.favorite !== 'boolean') throw new Error('Saved state unavailable');
    state.favorite = item.favorite;
  } catch { state.failed = true; }
  state.loading = false;
  if (searchSavedState.get(id) === state) updateSearchSaveButton(group, generation);
}
async function toggleSearchSave(group, generation){
  const id = searchSavedId(group), state = searchSavedState.get(id);
  if (!state || state.loading || state.saving || state.failed) return;
  const enabled = !state.favorite;
  state.saving = true; updateSearchSaveButton(group, generation);
  try {
    await apiMutation('/library/item/action?kind=search&id=' + encodeURIComponent(id) + '&action=favorite&enabled=' + enabled + '&title=' + encodeURIComponent(group.row.title || '') + '&poster=' + encodeURIComponent(unifiedArtwork(group.row.poster_url)));
    state.favorite = enabled;
  } catch { if (selectedSearchWork?.identity === group.identity && selectedSearchWork?.generation === generation) toast('Could not save this title. Try again.'); }
  state.saving = false;
  if (searchSavedState.get(id) === state) updateSearchSaveButton(group, generation);
}
let searchPreviewRun = 0;
let searchPreviewActive = false;
let searchPreviewPending = false;
let searchPreviewMarkup = "";
let selectedSearchGroup = null;
function stopSearchPreview(){
  ++searchPreviewRun;
  searchPreviewActive = false;
  searchPreviewPending = false;
  searchPreviewMarkup = '';
  const slot = $('search-preview-slot');
  if (slot) { slot.replaceChildren(); slot.innerHTML = ''; }
}
function verifiedPreviewEmbed(value){
  try {
    const url = new URL(value);
    const id = url.searchParams.get('v');
    if (url.protocol !== 'https:' || !['youtube.com', 'www.youtube.com'].includes(url.hostname) || url.username || url.password || url.pathname !== '/watch' || !/^[A-Za-z0-9_-]{11}$/.test(id || '')) return '';
    return 'https://www.youtube-nocookie.com/embed/' + id + '?autoplay=1&mute=1&rel=0';
  } catch { return ''; }
}
async function startSearchPreview(row, generation){
  if (!row?.key || row.source !== 'tmdb' || !['movie','tv'].includes(row.media) || !(row.id > 0)) return;
  stopSearchPreview();
  const request = searchPreviewRun;
  searchPreviewPending = true;
  const identity = selectedSearchWork?.identity;
  const slot = $('search-preview-slot');
  slot.innerHTML = searchPreviewMarkup = '<p class="search-preview-status" role="status">Checking for an official trailer…</p>';
  try {
    const preview = await api('/unified_search/preview?generation=' + generation + '&key=' + encodeURIComponent(row.key));
    if (request !== searchPreviewRun || selectedSearchWork?.identity !== identity || selectedSearchWork?.generation !== generation) return;
    const embed = preview.status === 'ready' && preview.generation === generation && Number(preview.catalog_id) === Number(row.id) && String(preview.key) === String(row.key) ? verifiedPreviewEmbed(preview.trailer_url) : '';
    searchPreviewPending = false;
    if (!embed) {
      const label = preview.failure === 'no_credentials' ? 'Trailer preview needs a configured movie catalog connection.' : preview.status === 'failed' ? 'Could not load the trailer. Try again.' : 'No verified official trailer is available for this title.';
      slot.innerHTML = searchPreviewMarkup = `<p class="search-preview-status" role="status">${esc(label)}</p>`;
      return;
    }
    searchPreviewActive = true;
    const controls = document.createElement('div');
    controls.className = 'search-preview-controls';
    const caption = document.createElement('span');
    caption.textContent = 'Official trailer · starts muted';
    const close = document.createElement('button');
    close.textContent = 'Close preview';
    close.onclick = () => { stopSearchPreview(); if (selectedSearchGroup) renderSearchDetail(selectedSearchGroup, generation); };
    controls.replaceChildren(caption, close);
    // Provider markup never bypasses the sanitizer. This one trusted frame is
    // created only after validating typed identity and a canonical video ID.
    const frame = document.createElement('iframe');
    frame.className = 'search-preview-frame';
    frame.setAttribute('src', embed);
    frame.setAttribute('title', 'Official trailer for ' + (preview.title || row.title || 'this title'));
    frame.setAttribute('allow', 'autoplay; encrypted-media; fullscreen');
    frame.setAttribute('referrerpolicy', 'strict-origin-when-cross-origin');
    slot.replaceChildren(controls, frame);
  } catch (error) {
    if (request !== searchPreviewRun || selectedSearchWork?.generation !== generation) return;
    searchPreviewPending = false;
    slot.innerHTML = searchPreviewMarkup = `<p class="search-preview-status" role="status">${esc(error?.message || 'Could not load the trailer. Try again.')}</p>`;
  }
}
let selectedSearchWork = null;
function searchWorkIdentity(row){
  // Only provider-issued typed identity may combine releases/catalog entries.
  if (typeof row.work_key === 'string' && /^[a-z0-9:_-]{1,160}$/i.test(row.work_key)) return 'work:' + row.work_key;
  if (row.source === 'tmdb' && ['movie', 'tv'].includes(row.media) && Number.isSafeInteger(Number(row.id)) && Number(row.id) > 0) return `tmdb:${row.media}:${row.id}`;
  return 'row:' + String(row.source || '') + ':' + String(row.key || '');
}
function groupSearchRows(rows){
  const groups = [], byIdentity = new Map();
  for (const row of rows) {
    const identity = searchWorkIdentity(row);
    // Missing opaque keys never coalesce into an unrelated work.
    let group = row.key ? byIdentity.get(identity) : null;
    if (!group) { group = {identity, rows:[], row, kind:row.work_category === 'videos' ? 'video' : row.work_category && row.work_category !== 'releases' ? row.work_category : unifiedSearchItem(row).kind}; groups.push(group); if (row.key) byIdentity.set(identity, group); }
    group.rows.push(row);
    if ((!unifiedArtwork(group.row.poster_url) && unifiedArtwork(row.poster_url)) || (row.work_representative === true && group.row.work_representative !== true) || (row.source === 'tmdb' && group.row.source !== 'tmdb' && group.row.work_representative !== true)) { group.row = row; group.kind = row.work_category === 'videos' ? 'video' : row.work_category && row.work_category !== 'releases' ? row.work_category : unifiedSearchItem(row).kind; }
  }
  return groups;
}
function searchAspect(kind){
  return ['music', 'podcasts', 'radio'].includes(kind) ? 'square' : ['video', 'live_tv'].includes(kind) ? 'wide' : 'portrait';
}
function searchReleaseMetadata(row){
  const item = unifiedSearchItem(row);
  return [({1:'480p', 2:'720p', 3:'1080p', 4:'4K'})[item.quality], item.size ? fmtSize(item.size) : '', item.torrent ? `${item.seeds} seeds · ${item.leech} peers` : ''].filter(Boolean).join(' · ');
}
function searchRowActions(row, generation, index){
  return `<div class="search-card-actions">${row.queueable ? `<button class="queue-btn" data-i="${index}" data-gen="${generation}">Queue</button>` : ''}<button class="play" data-i="${index}" data-gen="${generation}"${row.key ? '' : ' disabled'}>${unifiedActionLabel(row.source)}</button></div>`;
}
function confidentSearchFeature(groups){
  const query = $('q').value.trim().toLocaleLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
  if (!query) return null;
  const candidates = groups.filter(group => {
    const row = group.row;
    const title = String(row.title || '').toLocaleLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
    return row.source === 'tmdb' && row.id > 0 && ['movie', 'tv'].includes(row.media) && title === query && unifiedArtwork(row.poster_url);
  });
  return candidates.length === 1 ? candidates[0] : null;
}
function searchDetailScrollBehavior(){
  return matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth';
}
function searchCardDetail(row){
  const rating = Number(row.rating), year = String(row.year || '');
  return String(row.detail || '').split(/\s*[·|]\s*/).filter(part => {
    const value = part.trim();
    if (!value || (row.year > 1800 && row.year < 2200 && value === year)) return false;
    if (/^(?:movie|tv|show) details$/i.test(value)) return false;
    if (Number.isFinite(rating) && rating > 0 && /^(?:★\s*)?\d+(?:\.\d+)?(?:\s*\/\s*10)?$/.test(value) && Math.abs(parseFloat(value.replace('★','').trim()) - rating) < .051) return false;
    return true;
  }).join(' · ');
}
function searchCard(group, index, generation, rows){
  const row = group.row, artwork = unifiedArtwork(row.poster_url), rating = Number(row.rating);
  const actionRow = group.actionRow || row;
  const actionIndex = rows.indexOf(actionRow), release = searchReleaseMetadata(actionRow), detail = searchCardDetail(row);
  return `<article class="search-media-card aspect-${searchAspect(group.kind)}">
    <button class="search-card-art" data-work="${index}" aria-label="Explore ${esc(row.title || 'result')}">
      <span class="search-art-placeholder"><span>${esc(searchContentLabels[group.kind] || 'Media')}</span><strong>${esc(row.title || 'Untitled')}</strong></span>${artwork ? `<img src="${esc(artwork)}" alt="" loading="lazy" referrerpolicy="no-referrer">` : ''}
      ${group.rows.length > 1 ? `<span class="search-source-count">${group.rows.length} sources</span>` : ''}
    </button>
    <div class="search-card-copy"><button class="search-card-title" data-work="${index}">${esc(row.title)}</button>
      <div class="search-card-meta">${esc([row.year > 1800 && row.year < 2200 ? row.year : '', row.author || row.provider || row.source || ''].filter(Boolean).join(' · '))}${Number.isFinite(rating) && rating > 0 && rating <= 10 ? ` · ${rating.toFixed(1)}/10` : ''}</div>
      ${release || detail ? `<div class="search-card-release">${esc(release || detail)}</div>` : ''}
      ${searchRowActions(actionRow, generation, actionIndex)}</div>
  </article>`;
}
function renderSearchDetail(group, generation){
  const panel = $('search-detail');
  if (!group) { stopSearchPreview(); panel.hidden = true; panel.innerHTML = ''; selectedSearchWork = null; selectedSearchGroup = null; return; }
  selectedSearchGroup = group;
  if (selectedSearchWork?.identity === group.identity && selectedSearchWork?.generation === generation && (searchPreviewActive || searchPreviewPending)) return;
  if (selectedSearchWork?.identity !== group.identity || selectedSearchWork?.generation !== generation) stopSearchPreview();
  selectedSearchWork = {identity:group.identity, generation};
  const row = group.row, artwork = unifiedArtwork(row.poster_url);
  panel.hidden = false;
  // Remove previous dynamic IDs before the safe HTML adapter checks duplicates.
  panel.replaceChildren();
  panel.innerHTML = `<div class="search-detail-heading"><span>${esc(searchContentLabels[group.kind] || 'Media')}</span><div class="search-detail-tools">${searchSavedId(group) ? '<button id="search-save" aria-pressed="false">Save</button>' : ''}<button id="search-detail-close" aria-label="Close result details">Close ×</button></div></div>
    <div class="search-detail-content">${artwork ? `<img class="search-detail-art" src="${esc(artwork)}" alt="" referrerpolicy="no-referrer">` : ''}<div class="search-detail-copy"><h2>${esc(row.title)}</h2>
      ${row.author ? `<p class="search-detail-author">${esc(row.author)}</p>` : ''}${row.summary ? `<p class="search-detail-summary">${esc(row.summary)}</p>` : '<p class="search-detail-summary">Choose an available source below.</p>'}
      ${row.source === 'tmdb' && row.id > 0 && ['movie','tv'].includes(row.media) ? `<button id="search-preview-start" class="search-preview-start">Preview trailer</button><div id="search-preview-slot">${searchPreviewMarkup}</div>` : ''}
      <h3>Available sources</h3><div class="search-source-options">${group.rows.map((variant, i) => `<div class="search-source-option"><div><strong>${esc(variant.provider || variant.source || 'Source')}</strong><span>${esc(searchReleaseMetadata(variant) || variant.detail || unifiedActionLabel(variant.source))}</span></div><div>${variant.queueable ? `<button data-detail-queue="${i}">Queue</button>` : ''}<button data-detail-play="${i}"${variant.key ? '' : ' disabled'}>${unifiedActionLabel(variant.source)}</button></div></div>`).join('')}</div></div></div>`;
  if (row.source === 'tmdb' && row.id > 0 && ['movie','tv'].includes(row.media)) $('search-preview-start').onclick = () => startSearchPreview(row, generation);
  $('search-detail-close').onclick = () => { renderSearchDetail(null); if (unifiedSearchPayload) renderUnifiedResults(unifiedSearchPayload); $('q').focus(); };
  panel.querySelectorAll('[data-detail-play]').forEach(button => button.onclick = () => runUnifiedAction(group.rows[Number(button.dataset.detailPlay)], generation, 'play', button));
  panel.querySelectorAll('[data-detail-queue]').forEach(button => button.onclick = () => runUnifiedAction(group.rows[Number(button.dataset.detailQueue)], generation, 'queue', button));
  panel.onkeydown = searchDetailEscape;
  loadSearchSaveState(group, generation);
}
function searchDetailEscape(event){ if (event.key === 'Escape') $('search-detail-close').onclick(); }
function renderUnifiedResults(payload){
  if (payload?.error || !Array.isArray(payload?.results)) throw new Error(payload?.error || 'Search returned an invalid response. Try again.');
  unifiedSearchPayload = payload;
  renderSearchSources(payload);
  renderSearchFilterChips();
  $('search-hint').textContent = unifiedResultCount(payload);
  const matched = unifiedResultRows(payload), shown = payload.results, generation = payload.generation || 0;
  const positions = new Map(matched.map((row, i) => [row, i]));
  const groups = groupSearchRows(shown).filter(group => group.rows.some(row => positions.has(row)));
  for (const group of groups) group.actionRow = group.rows.filter(row => positions.has(row)).sort((a,b) => positions.get(a) - positions.get(b))[0];
  groups.sort((a,b) => positions.get(a.actionRow) - positions.get(b.actionRow));
  const featured = confidentSearchFeature(groups);
  const order = ['movies', 'shows', 'anime', 'music', 'comics', 'books', 'podcasts', 'radio', 'live_tv', 'visual_novels', 'video'];
  let html = '';
  if (featured && !selectedSearchWork) {
    const row = featured.row;
    html += `<section class="search-feature">${unifiedArtwork(row.backdrop_url) ? `<img class="search-feature-backdrop" src="${esc(unifiedArtwork(row.backdrop_url))}" alt="" referrerpolicy="no-referrer">` : ''}<img src="${esc(unifiedArtwork(row.poster_url))}" alt="" referrerpolicy="no-referrer"><div><span class="search-feature-kind">${esc(searchContentLabels[featured.kind])}</span><h2>${esc(row.title)}</h2>${row.summary ? `<p>${esc(row.summary)}</p>` : ''}<button class="search-feature-explore" data-work="${groups.indexOf(featured)}">Explore title <span>→</span></button></div></section>`;
  }
  for (const kind of order) {
    const works = groups.filter(group => group.kind === kind && group.rows.some(row => !unifiedSearchItem(row).torrent));
    if (!works.length) continue;
    html += `<section class="search-shelf"><div class="search-shelf-heading"><h2>${esc(searchContentLabels[kind] || 'Video')}</h2><span>${works.length} ${works.length === 1 ? 'title' : 'titles'}</span></div><div class="search-shelf-track${searchFilters().content !== 'all' ? ' search-shelf-grid' : ''}">${works.map(group => searchCard(group, groups.indexOf(group), generation, shown)).join('')}</div></section>`;
  }
  const releases = groups.filter(group => group.rows.every(row => unifiedSearchItem(row).torrent));
  if (releases.length) html += `<details class="search-release-shelf"${searchFilters().availability === 'torrents' ? ' open' : ''}><summary><span>Available releases</span><span>${releases.length} ${releases.length === 1 ? 'release' : 'releases'}</span></summary><div class="search-release-grid">${releases.map(group => searchCard(group, groups.indexOf(group), generation, shown)).join('')}</div></details>`;
  if (!groups.length) html = `<div class="search-discovery-empty">${payload.results.length ? '<h2>No results match these filters</h2><p>Remove a filter to see more of the loaded titles.</p>' : payload.loading ? '<span class="spin"></span><h2>Finding your next title</h2><p>Results appear as your sources respond.</p>' : '<h2>No matches yet</h2><p>Try another title or check Sources in Filters.</p>'}</div>`;
  // Keep selected details current as providers publish, never carry selection to a new wave.
  if (selectedSearchWork) renderSearchDetail(selectedSearchWork.generation === generation ? groups.find(group => group.identity === selectedSearchWork.identity) : null, generation);
  $('search-cancel').hidden = !payload.loading;
  if (html === lastHtml.results) return;
  lastHtml.results = html;
  $('results').innerHTML = html;
  $('results').querySelectorAll('img').forEach(image => image.addEventListener('error', () => { image.hidden = true; }, {once:true}));
  $('results').querySelectorAll('[data-work]').forEach(button => button.onclick = () => {
    renderSearchDetail(groups[Number(button.dataset.work)], generation);
    renderUnifiedResults(payload);
    $('search-detail').scrollIntoView?.({behavior:searchDetailScrollBehavior(), block:'nearest'});
    $('search-detail-close').focus();
  });
  $('results').querySelectorAll('.play').forEach(button => button.onclick = () => runUnifiedAction(shown[Number(button.dataset.i)], Number(button.dataset.gen), 'play', button));
  $('results').querySelectorAll('.queue-btn').forEach(button => button.onclick = () => runUnifiedAction(shown[Number(button.dataset.i)], Number(button.dataset.gen), 'queue', button));
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
