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

function runSearch(){
  const q = $('q').value.trim(); if (!q) return;
  $('search-hint').innerHTML = '<span class="spin"></span> Searching all sources…';
  $('results').innerHTML = ''; lastHtml.results = '';
  api('/unified_search?q=' + encodeURIComponent(q)).catch(()=>{});
  clearInterval(searchWatch);
  let ticks = 0;
  searchWatch = setInterval(async () => {
    ticks++;
    try {
      const d = await api('/unified_search');
      renderUnifiedResults(d.results || []);
      if ((!d.loading && ticks > 2) || ticks > 40) {
        clearInterval(searchWatch);
        const sources = new Set((d.results || []).map(r => r.source).filter(Boolean));
        $('search-hint').textContent = `${(d.results || []).length} results across ${sources.size} source${sources.size === 1 ? '' : 's'}.`;
      }
    } catch { clearInterval(searchWatch); }
  }, 900);
}

function unifiedActionLabel(action){
  if (action === 'magnet' || action === 'yt_play' || action === 'jf_play') return 'Play';
  if (action === 'jf_browse') return 'Open';
  if (action === 'anime_detail') return 'Episodes';
  if (action === 'tmdb_detail') return 'Details';
  return 'Open';
}
function queueableUnified(r){
  if (r.action === 'magnet') return r.data || '';
  if (r.action === 'yt_play' && r.data) return 'https://www.youtube.com/watch?v=' + r.data;
  return '';
}
function renderUnifiedResults(rs){
  const shown = rs.slice(0, 80);
  const html = shown.map((r, i) => {
    const queueUrl = queueableUnified(r);
    return `<div class="result">
      <div class="t">${esc(r.title)}</div>
      <div class="m"><span class="src">${esc(r.source || '')}</span>
        ${r.detail ? `<span>${esc(r.detail)}</span>` : ''}
        <span class="actions">
          ${queueUrl ? `<button class="queue-btn" data-i="${i}">Queue</button>` : ''}
          <button class="play" data-i="${i}">${unifiedActionLabel(r.action)}</button>
        </span>
      </div>
    </div>`;
  }).join('') || '<div class="empty">No results yet</div>';
  if (html === lastHtml.results) return;
  lastHtml.results = html;
  $('results').innerHTML = html;
  $('results').querySelectorAll('.play').forEach(b => b.onclick = () => runUnifiedAction(shown[+b.dataset.i], b));
  $('results').querySelectorAll('.queue-btn').forEach(b => {
    const r = shown[+b.dataset.i];
    b.onclick = () => queueMedia(queueableUnified(r), r.title, b);
  });
}
function runUnifiedAction(r, button){
  if (!r) return;
  if (r.action === 'magnet') return playMediaUrl(r.data, r.title, button);
  if (r.action === 'yt_play') {
    if ((HOSTED || PLAY_HERE) && r.data) return openYtEmbed(r.data, r.title);
    return playMediaUrl('https://www.youtube.com/watch?v=' + r.data, r.title, button);
  }
  if (r.action === 'anime_detail') {
    openPage('anime', { focus:true }); $('anime-q').value = r.title || ''; runAnime(); return;
  }
  if (r.action === 'jf_browse') {
    openPage('jf', { focus:true }); jfBrowse(r.data); return;
  }
  if (r.action === 'jf_play') {
    api('/jellyfin/play?id=' + encodeURIComponent(r.data || '')).catch(()=>{});
    button.textContent = 'Sent ✓'; return;
  }
  // TMDB is metadata, not a stream: open the unified details panel, where
  // Find streams narrows to playable resolver results. Older rows without a
  // media kind fall straight through to the stream search.
  if (r.action === 'tmdb_detail' && r.media && r.data)
    return openDetails(r.media === 'tv' ? 'tv' : 'movie', +r.data, r.title || '');
  runStreamSearch(r.title || $('q').value.trim());
}

function runStreamSearch(title){
  if (!title) return;
  $('q').value = title;
  $('search-hint').innerHTML = '<span class="spin"></span> Finding playable streams…';
  $('results').innerHTML = ''; lastHtml.results = '';
  api('/search?q=' + encodeURIComponent(title)).catch(()=>{});
  clearInterval(searchWatch);
  let ticks = 0;
  searchWatch = setInterval(async () => {
    ticks++;
    try {
      const d = await api('/search');
      renderTorrentResults(d.results || []);
      if ((!d.searching && ticks > 2) || ticks > 40) {
        clearInterval(searchWatch);
        $('search-hint').textContent = `${(d.results || []).length} playable stream candidates.`;
      }
    } catch { clearInterval(searchWatch); }
  }, 900);
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
          <button class="play" data-i="${i}">Play</button></span>
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

// ── Activity ──
let transferTimer = null;
const refreshTransfers = () => Promise.all([loadTorrents(), loadDownloads()]);
async function pollTransfers(){
  clearTimeout(transferTimer);
  if (!document.getElementById('page-act').classList.contains('on')) return;
  await refreshTransfers();
  transferTimer = setTimeout(pollTransfers, 2000);
}
async function loadTorrents(){
  try {
    const d = await api('/torrents');
    const ts = d.torrents || [];
    const html = ts.map((t, i) => `
      <div class="tor"><div class="n">${esc(t.name)}</div>
        <div class="bar"><i style="width:${t.pct}%"></i></div>
        <div class="m"><span class="transfer-summary">${t.pct}% · ${(t.rate/1024/1024).toFixed(1)} MB/s · ${t.seeds} seeds${t.paused ? ' · paused' : ''}</span>
          <span class="transfer-actions">
            <button type="button" class="primary" data-transfer="torrent" data-id="${t.id ?? i}" data-action="${t.paused ? 'resume' : 'pause'}">${t.paused ? 'Resume' : 'Pause'}</button>
            <button type="button" class="tor-files" data-i="${t.id ?? i}">Files</button>
            <button type="button" class="danger" data-transfer="torrent" data-id="${t.id ?? i}" data-action="cancel" data-name="${encodeURIComponent(t.name || 'torrent')}">Remove</button>
          </span></div>
        <div class="tor-filelist" id="torf-${t.id ?? i}"></div>
      </div>`).join('') || '<div class="empty">Nothing downloading</div>';
    if (html !== lastHtml.torrents) {
      $('torrents').innerHTML = html; lastHtml.torrents = html;
      wireTorrentFiles();
    }
  } catch { $('torrents').innerHTML = '<div class="empty">—</div>'; lastHtml.torrents = '<div class="empty">—</div>'; }
}

const transferMessages = {
  pause:'Transfer paused', resume:'Transfer resumed', cancel:'Transfer removed',
  dismiss:'Transfer dismissed', priority:'File priority updated',
};
async function changeTransfer(button){
  const kind = button.dataset.transfer, action = button.dataset.action;
  const destructive = action === 'cancel' || action === 'dismiss';
  if (destructive) {
    const name = decodeURIComponent(button.dataset.name || 'this transfer');
    const note = kind === 'torrent' || button.dataset.keepsFile === '1'
      ? 'Completed files stay on disk.' : 'Partial data will be deleted.';
    if (!confirm(`Remove “${name}” from Opal? ${note}`)) return;
  }
  const params = new URLSearchParams({action});
  for (const key of ['id','idx','token','file','value']) {
    if (button.dataset[key] != null) params.set(key, button.dataset[key]);
  }
  if (destructive) params.set('confirm', '1');
  button.disabled = true;
  try {
    await apiMutation(`/${kind === 'torrent' ? 'torrents' : 'downloads'}/action?${params}`);
    toast(transferMessages[action] || 'Transfer updated');
    if (kind === 'torrent') lastHtml.torrents = '';
    await refreshTransfers();
  } catch (err) {
    button.disabled = false;
    toast(err.message || 'Could not update transfer');
  }
}
$('page-act').addEventListener('click', e => {
  const button = e.target.closest('button[data-transfer]');
  if (button) changeTransfer(button);
});

// Per-file play for a live torrent. libtorrent writes under the downloads root
// and /stream serves that root with Range, so a file streams as far as it has
// bytes — which is why the progress figure matters here and not just cosmetically.
function wireTorrentFiles(){
  $('torrents').querySelectorAll('.tor-files').forEach(b => b.onclick = async () => {
    const id = b.dataset.i, box = $('torf-' + id);
    if (box.dataset.open === '1') { box.innerHTML = ''; box.dataset.open = '0'; return; }
    box.dataset.open = '1';
    box.innerHTML = '<div class="hint"><span class="spin"></span> Reading files…</div>';
    try {
      const d = await api('/torrent/files?id=' + encodeURIComponent(id));
      const fs = d.files || [];
      box.innerHTML = fs.map((f, j) => `
        <div class="file"><div class="n">${esc(f.name)}</div>
          <div class="qmv">${f.progress}%</div>
          <div class="transfer-actions">
            <button type="button" data-transfer="torrent" data-action="priority" data-id="${id}" data-file="${f.id ?? j}" data-value="0">Skip</button>
            <button type="button" data-transfer="torrent" data-action="priority" data-id="${id}" data-file="${f.id ?? j}" data-value="7">High</button>
            <button type="button" class="play" data-j="${j}">Play</button>
          </div></div>`).join('')
        || '<div class="hint">No files yet — metadata still resolving.</div>';
      box.querySelectorAll('.play').forEach(pb => pb.onclick = () => {
        const f = fs[+pb.dataset.j];
        // Classify on the FILE NAME; the /stream URL hides the extension in a
        // query param (see playback_target_pure).
        dispatchPlay(streamUrl(f.rel), f.name, () => {
          pb.textContent = 'Sent ✓';
          apiMutation('/downloads/play?file=' + encodeURIComponent(f.rel)).catch(()=>{});
        }, f.name);
        if (PLAY_HERE && f.progress < 100 && classifyPlayable(f.name) === 'direct')
          toast(`Streaming at ${f.progress}% — playback may stall past the downloaded part.`);
      });
    } catch { box.innerHTML = '<div class="hint">Could not read the file list.</div>'; }
  });
}

async function loadQueue(){
  try {
    const q = await api('/queue');
    const items = q.items || [];
    const played = items.filter(i => i.played).length;
    $('queue-clear-played').disabled = played === 0;
    $('queue-clear').disabled = items.length === 0;
    $('queue-status').textContent = `${items.length} queue item${items.length === 1 ? '' : 's'}, ${played} played`;
    $('queue').innerHTML = items.map((i, idx) => {
      const title = i.title || i.name || i.url || 'Untitled media';
      const source = i.source || (String(i.url || '').startsWith('magnet:') ? 'Torrent' : 'Media');
      return `<div class="file queue-item${i.played ? ' played' : ''}">
        <div class="n"><div>${esc(title)}</div><div class="file-meta">
          <span class="src">${esc(source)}</span>
          ${i.duration > 0 ? `<span>${fmt(i.duration)}</span>` : ''}
          ${i.played ? '<span>Played</span>' : '<span>Up next</span>'}
        </div></div>
        <div class="queue-actions">
          <button type="button" class="queue-play" data-action="play" data-idx="${idx}" aria-label="Play queue item ${idx + 1}">Play</button>
          <button type="button" data-action="move-up" data-idx="${idx}" aria-label="Move queue item ${idx + 1} up"${idx === 0 ? ' disabled' : ''}>↑</button>
          <button type="button" data-action="move-down" data-idx="${idx}" aria-label="Move queue item ${idx + 1} down"${idx === items.length - 1 ? ' disabled' : ''}>↓</button>
          <button type="button" class="danger" data-action="remove" data-idx="${idx}" aria-label="Remove queue item ${idx + 1}">Remove</button>
        </div>
      </div>`;
    }).join('') || '<div class="empty">Queue is empty</div>';
  } catch {
    $('queue').innerHTML = '<div class="empty">Queue unavailable</div>';
    $('queue-clear-played').disabled = true;
    $('queue-clear').disabled = true;
  }
}

async function changeQueue(action, idx){
  if (action === 'clear' && !confirm('Clear every item from the queue? This cannot be undone.')) return;
  const params = new URLSearchParams({action});
  if (idx != null) params.set('idx', idx);
  if (action === 'clear') params.set('confirm', '1');
  try {
    await apiMutation('/queue/action?' + params);
    toast(action === 'play' ? 'Playing from queue' : action === 'clear' ? 'Queue cleared' : 'Queue updated');
  } catch (err) { toast(err.message || 'Could not update queue'); }
  await loadQueue();
}
$('queue').addEventListener('click', e => {
  const button = e.target.closest('button[data-action]');
  if (button) changeQueue(button.dataset.action, button.dataset.idx);
});
$('queue-clear-played').onclick = () => changeQueue('clear-played');
$('queue-clear').onclick = () => changeQueue('clear');

async function loadDownloads(){
  try {
    const d = await api('/downloads');
    const jobs = d.jobs || [];
    $('download-jobs').innerHTML = jobs.map(job => {
      const status = String(job.status || 'queued');
      const pct = Math.max(0, Math.min(100, Number(job.pct) || 0));
      const active = ['queued','probing','running'].includes(status);
      const toggle = active ? 'pause' : (['paused','failed'].includes(status) ? 'resume' : '');
      const remove = active ? 'cancel' : 'dismiss';
      const meta = [status.replace('_', ' '), job.rate ? fmtSize(job.rate) + '/s' : '',
        job.eta != null ? fmt(job.eta) + ' left' : '', job.segments > 1 ? job.segments + ' connections' : '']
        .filter(Boolean).join(' · ');
      return `<div class="tor"><div class="n">${esc(job.name || 'Download')}</div>
        <div class="bar"><i style="width:${pct}%"></i></div>
        <div class="m"><span class="transfer-summary">${esc(meta)}</span><span class="transfer-actions">
          ${toggle ? `<button type="button" class="primary" data-transfer="download" data-action="${toggle}" data-idx="${job.idx}" data-token="${job.token}">${toggle === 'pause' ? 'Pause' : 'Resume'}</button>` : ''}
          <button type="button" class="danger" data-transfer="download" data-action="${remove}" data-idx="${job.idx}" data-token="${job.token}" data-keeps-file="${status === 'done' ? '1' : '0'}" data-name="${encodeURIComponent(job.name || 'download')}">Remove</button>
        </span></div>${job.error ? `<div class="transfer-error" role="alert">${esc(job.error)}</div>` : ''}</div>`;
    }).join('') || '<div class="empty">No direct downloads</div>';

    const files = d.files || [], cap = 40, shown = files.slice(0, cap);
    $('downloads').innerHTML = shown.map(file => {
      const item = typeof file === 'string' ? {name:file} : file;
      const name = item.name || '';
      const detail = item.is_dir ? 'Folder' : fmtSize(item.size);
      return `<div class="file"><div class="n">${esc(name)}${detail ? `<div class="file-meta">${esc(detail)}</div>` : ''}</div>
        ${item.is_dir ? '' : `<button class="play" data-n="${encodeURIComponent(name)}">Play</button>`}</div>`;
    }).join('') + (files.length > cap
      ? `<div class="empty">${files.length - cap} more not shown — newest ${cap} listed</div>` : '')
      || '<div class="empty">No downloaded files</div>';
    $('downloads').querySelectorAll('.play').forEach(button => button.onclick = () => {
      const rel = decodeURIComponent(button.dataset.n);
      if (HOSTED) return openPlayer(rel);
      dispatchPlay(streamUrl(rel), rel, () => {
        button.textContent = 'Sent ✓';
        apiMutation('/downloads/play?file=' + button.dataset.n).catch(()=>{});
      }, rel);
    });
  } catch {
    $('download-jobs').innerHTML = '<div class="empty">Downloads unavailable</div>';
    $('downloads').innerHTML = '<div class="empty">—</div>';
  }
}

async function loadActivity(){
  await Promise.all([loadQueue(), pollTransfers()]);
  try {
    // /api/history = recent SEARCHES (plain strings) — tap to run again.
    const h = await api('/history');
    $('history').innerHTML = (h.items || []).slice(0, 20).map(q =>
      `<div class="file" data-q="${esc(q)}"><div class="n">${esc(q)}</div><span class="play">Search ⭢</span></div>`).join('')
      || '<div class="empty">No history</div>';
    $('history').querySelectorAll('.file').forEach(el => el.onclick = () => prefillSearch(el.dataset.q));
  } catch { $('history').innerHTML = '<div class="empty">—</div>'; }
}

// ── Movies & TV catalog (TMDB when configured, keyless Cinemeta otherwise) ──
let browseLoaded = false, browseWatch = null, browseGeneration = 0, browseDebounce = null;

function browseType(){ return $('browse-type').value || 'all'; }
function browseFeedLabel(){
  const q = $('browse-q').value.trim();
  if (q) return `Results for “${q}”`;
  const feed = $('browse-category').selectedOptions[0]?.textContent || 'Trending';
  const type = $('browse-type').selectedOptions[0]?.textContent || 'Movies & TV';
  return `${feed} ${type.toLowerCase()}`;
}
function browseEndpoint(){
  const q = $('browse-q').value.trim();
  if (q) return '/tmdb/search?q=' + encodeURIComponent(q) + '&type=' + encodeURIComponent(browseType());
  const params = new URLSearchParams({
    type: browseType(), category: $('browse-category').value, genre: $('browse-genre').value,
  });
  return '/tmdb/trending?' + params;
}
function renderBrowse(items){
  $('browse-grid').innerHTML = items.map(it => `
    <div class="card${it.poster ? '' : ' poster-missing'}" tabindex="0" role="button"
      data-id="${it.id}" data-imdb="${esc(it.imdb || '')}" data-type="${esc(it.type)}" data-title="${esc(it.title)}">
      ${it.poster ? `<img loading="lazy" decoding="async" alt="" src="${BASE}/poster?path=${encodeURIComponent(it.poster)}">` : ''}
      <div class="cap" title="${esc(it.title)}">${esc(it.title)}<br><span class="rt">${it.rating || ''}${it.rating ? '%' : ''} ${esc(it.type === 'tv' ? 'TV' : 'Movie')}</span></div>
    </div>`).join('') || '<div class="empty">No matching movies or shows.</div>';
  $('browse-grid').querySelectorAll('.card').forEach(c => {
    const open = () => openDetails(c.dataset.type === 'tv' ? 'tv' : 'movie', +c.dataset.id, c.dataset.title, c.dataset.imdb);
    c.onclick = open;
    c.onkeydown = e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); open(); } };
    const img = c.querySelector('img');
    if (img) img.addEventListener('error', () => { img.remove(); c.classList.add('poster-missing'); }, { once:true });
  });
}
const browseDelay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function waitForBrowseIdle(generation){
  for (let attempt = 0; attempt < 40; attempt++) {
    if (generation !== browseGeneration) return false;
    try {
      const current = await api('/tmdb');
      if (!current.loading) return true;
    } catch { return false; }
    await browseDelay(200);
  }
  return false;
}
async function loadBrowse(force){
  if (browseLoaded && !force) return;
  clearInterval(browseWatch);
  const generation = ++browseGeneration;
  browseLoaded = false;
  $('browse-hint').innerHTML = '<span class="spin"></span> Loading ' + esc(browseFeedLabel().toLowerCase()) + '…';
  $('browse-grid').innerHTML = '';
  try {
    if (!await waitForBrowseIdle(generation) || generation !== browseGeneration) return;
    await api(browseEndpoint());
  }
  catch { $('browse-hint').textContent = 'Could not start the catalog request.'; return; }

  let tries = 0;
  browseWatch = setInterval(async () => {
    if (generation !== browseGeneration) return clearInterval(browseWatch);
    tries++;
    try {
      const d = await api('/tmdb');
      // Do not paint the previous desktop/web query while the replacement is
      // still in flight. The pending result swap is atomic on the app thread.
      if (!d.loading || tries > 24) {
        clearInterval(browseWatch);
        const items = d.items || [];
        browseLoaded = true;
        renderBrowse(items);
        $('browse-hint').textContent = items.length
          ? `${browseFeedLabel()} · ${items.length} titles${d.has_key ? '' : ' · keyless catalog'}`
          : `No results for ${browseFeedLabel().toLowerCase()}.`;
      }
    } catch {
      clearInterval(browseWatch);
      $('browse-hint').textContent = 'Catalog temporarily unavailable. Try again.';
    }
  }, 500);
}

$('browse-search').addEventListener('submit', e => { e.preventDefault(); loadBrowse(true); });
$('browse-q').addEventListener('input', () => {
  clearTimeout(browseDebounce);
  browseDebounce = setTimeout(() => loadBrowse(true), 450);
});
$('browse-apply').onclick = () => {
  $('browse-q').value = '';
  $('browse-filters').open = false;
  loadBrowse(true);
};

// ── TV show drill-down ──
function normQuery(title){
  // Mirror of tmdb_pure.streamQueryTitle: lowercase, strip punctuation,
  // drop a trailing 2/4-digit year token.
  let t = title.toLowerCase().replace(/[^a-z0-9\- ]+/g, ' ').replace(/\s+/g, ' ').trim();
  return t.replace(/ (\d{2}|\d{4})$/, '');
}
function prefillSearch(q){
  document.querySelector('nav [data-page=search]').click();
  $('q').value = q;
  runSearch();
}
let showId = 0, showTitle = '', showSeason = 0, showImdb = '', showCinemetaVideos = null;

// One panel serves movie and TV details; every entry point (Browse, unified
// search, Watching, calendar) funnels through openDetails so metadata,
// overview, and the action row can never diverge between media kinds.
function resetDetailsPanel(title){
  $('show-title').textContent = title;
  $('show-meta').innerHTML = '<span class="spin"></span> Loading…';
  $('show-overview').hidden = true; $('show-overview').textContent = '';
  $('show-actions').innerHTML = '';
  $('show-latest').style.display = 'none'; $('show-latest').innerHTML = '';
  $('season-chips').innerHTML = ''; $('episodes').innerHTML = '';
  $('show-page').classList.add('on');
}
function renderOverview(text){
  if (!text) return;
  $('show-overview').textContent = text;
  $('show-overview').hidden = false;
}
const detailsMeta = parts => parts.filter(Boolean).join(' · ');
const ratingLabel = v => v > 0 ? '★ ' + Number(v).toFixed(1) : '';

function openDetails(kind, id, title, imdb){
  if (kind === 'movie') return openMovie(id, title);
  return openShow(id, title, imdb || '');
}

async function openMovie(id, title){
  resetDetailsPanel(title);
  // The stream hunt works even when TMDB metadata does not, so the action row
  // renders before the fetch instead of behind it.
  $('show-actions').innerHTML = '<button type="button" id="show-find">▶ Find streams</button>';
  $('show-find').onclick = () => { $('show-page').classList.remove('on'); prefillSearch(normQuery(title)); };
  try {
    const d = await api('/movie?id=' + id);
    if (d.error) { $('show-meta').textContent = 'Details unavailable — you can still find streams.'; return; }
    if (d.title) $('show-title').textContent = d.title;
    $('show-meta').textContent = detailsMeta([
      (d.release_date || '').slice(0, 4),
      d.runtime ? d.runtime + ' min' : '',
      ratingLabel(d.vote_average),
      (d.genres || []).slice(0, 3).map(g => g.name).join(', '),
    ]) || 'Movie';
    renderOverview(d.overview);
  } catch { $('show-meta').textContent = 'Details unavailable — you can still find streams.'; }
}

async function openShow(id, title, imdb){
  showId = id; showTitle = title; showImdb = imdb; showCinemetaVideos = null;
  resetDetailsPanel(title);
  try {
    const d = await api('/tv?id=' + id + (showImdb ? '&imdb=' + encodeURIComponent(showImdb) : ''));
    const meta = d.meta || d;
    if (d.meta) showCinemetaVideos = d.meta.videos || [];
    const seasons = d.meta ? cinemetaSeasons(showCinemetaVideos) : (d.seasons || []).filter(x => x.season_number >= 1);
    $('show-meta').textContent = detailsMeta([
      (meta.first_air_date || meta.year || '').slice(0, 4),
      seasons.length + ' seasons',
      ratingLabel(meta.vote_average || meta.imdbRating),
      (meta.genres || meta.genre || []).slice(0, 3).map(g => g.name || g).join(', '),
    ]);
    renderOverview(meta.overview || meta.description);
    $('season-chips').innerHTML = seasons.map((x, i) =>
      `<button data-sn="${x.season_number}" class="${i === 0 ? 'on' : ''}">S${x.season_number}</button>`).join('');
    $('season-chips').querySelectorAll('button').forEach(b => b.onclick = () => {
      $('season-chips').querySelectorAll('button').forEach(x => x.classList.toggle('on', x === b));
      loadSeason(+b.dataset.sn);
    });
    if (seasons.length) loadSeason(seasons[0].season_number);
  } catch { $('show-meta').textContent = 'Failed to load'; }
  loadLatest(id);
}

function cinemetaSeasons(videos){
  const counts = new Map();
  (videos || []).forEach(e => {
    const season = +e.season || 0, episode = +e.episode || 0;
    if (season >= 1) counts.set(season, Math.max(counts.get(season) || 0, episode));
  });
  return [...counts].sort((a,b) => a[0] - b[0]).map(([season_number, episode_count]) => ({season_number, episode_count}));
}

// ── Play-latest row (top of the show page) ──
// The most recently AIRED episode plus whether it has been watched. Distinct
// from "next up": once you are caught up there is no next episode, but the
// latest drop still exists and you still want to know you have seen it.
// Hidden entirely when the server has no aired frontier — offering a play
// button for an episode nobody can confirm exists is worse than no button.
async function loadLatest(id){
  const el = $('show-latest');
  el.style.display = 'none'; el.innerHTML = '';
  try {
    const d = await api('/tv/recent?id=' + id);
    if (!d || !d.found) return;
    const q = normQuery(showTitle) + ' s' + String(d.season).padStart(2,'0') + 'e' + String(d.episode).padStart(2,'0');
    el.innerHTML = `<button class="latest-btn" data-q="${esc(q)}">▶ Play ${esc(d.label.split(' · ')[0])}</button>
      <button class="latest-badge ${d.watched ? 'seen' : ''}" aria-pressed="${d.watched}">${d.watched ? '✓ Watched' : 'Mark watched'}</button>`;
    el.style.display = '';
    // Same destination as the per-episode "Find ⭢" button — one search path,
    // so the top button can never resolve differently from the list below it.
    el.querySelector('.latest-btn').onclick = () => {
      $('show-page').classList.remove('on');
      prefillSearch(q);
    };
    el.querySelector('.latest-badge').onclick = async b => {
      b.currentTarget.disabled = true;
      try {
        await apiMutation('/library/action?action=watched&kind=tv&id=' + id
          + '&season=' + d.season + '&episode=' + d.episode + '&value=' + !d.watched);
        await loadLatest(id);
        if (showSeason === d.season) await loadSeason(showSeason);
      } catch (err) { toast(err.message || 'Could not update watched state.'); }
    };
  } catch {}
}
async function loadSeason(sn){
  showSeason = sn;
  $('episodes').innerHTML = '<div class="empty"><span class="spin"></span></div>';
  try {
    const [d, seenData] = await Promise.all([
      showCinemetaVideos ? Promise.resolve({episodes: showCinemetaVideos.filter(e => +e.season === sn).map(e => ({
        episode_number:+e.episode || 0, name:e.title || `Episode ${e.episode}`,
        overview:e.overview || '', air_date:(e.released || '').slice(0,10),
      }))}) : api('/tv?id=' + showId + '&season=' + sn + (showImdb ? '&imdb=' + encodeURIComponent(showImdb) : '')),
      api('/library/watched?kind=tv&id=' + showId + '&season=' + sn).catch(() => ({episodes:[]})),
    ]);
    const seen = new Set(seenData.episodes || []);
    $('episodes').innerHTML = (d.episodes || []).map(e => `
      <div class="ep"><div class="h">
        <span>E${String(e.episode_number).padStart(2,'0')} · ${esc(e.name || '')}</span>
        <div class="ep-actions">
          <button class="watched-toggle ${seen.has(e.episode_number) ? 'seen' : ''}" data-action="watched"
            data-season="${sn}" data-episode="${e.episode_number}" data-value="${!seen.has(e.episode_number)}"
            aria-pressed="${seen.has(e.episode_number)}">${seen.has(e.episode_number) ? '✓ Watched' : 'Mark watched'}</button>
          <button class="find" data-action="find" data-q="${esc(normQuery(showTitle))} s${String(sn).padStart(2,'0')}e${String(e.episode_number).padStart(2,'0')}">Find ⭢</button>
        </div>
      </div>
      <div class="o">${esc((e.overview || '').slice(0, 160))}${e.air_date ? ' · ' + esc(e.air_date) : ''}</div></div>`).join('')
      || '<div class="empty">No episodes</div>';
  } catch { $('episodes').innerHTML = '<div class="empty">Failed</div>'; }
}
$('episodes').addEventListener('click', async e => {
  const button = e.target.closest('button[data-action]'); if (!button) return;
  if (button.dataset.action === 'find') {
    $('show-page').classList.remove('on'); prefillSearch(button.dataset.q); return;
  }
  button.disabled = true;
  try {
    await apiMutation('/library/action?action=watched&kind=tv&id=' + showId
      + '&season=' + button.dataset.season + '&episode=' + button.dataset.episode
      + '&value=' + button.dataset.value);
    await Promise.all([loadSeason(showSeason), loadLatest(showId)]);
  } catch (err) { button.disabled = false; toast(err.message || 'Could not update watched state.'); }
});
$('show-back').onclick = () => $('show-page').classList.remove('on');

// ── Coming up rail ──
// The coming-up rail already renders into #cal for the Playing page. Home
// mirrors that markup rather than re-fetching /calendar and re-deriving the
// countdown labels — two derivations of the same rail is how they drift.
async function loadCalendarInto(targetId){
  await loadCalendar();
  const src = $('cal'), dst = $(targetId);
  if (!src || !dst) return;
  dst.innerHTML = src.innerHTML;
  dst.querySelectorAll('.c').forEach(c => c.onclick = () => openShow(+c.dataset.id, c.dataset.n));
}
async function loadCalendar(){
  try {
    const d = await api('/calendar');
    const es = d.entries || [];
    $('cal-head').style.display = es.length ? 'block' : 'none';
    $('cal').innerHTML = es.map(e => {
      const lab = e.available
        ? `S${String(e.last_season).padStart(2,'0')}E${String(e.last_episode).padStart(2,'0')} available · ${e.seeds} seeds`
        : e.next_season > 0
          ? `S${String(e.next_season).padStart(2,'0')}E${String(e.next_episode).padStart(2,'0')} ${cd(e.next_air)}`
          : `S${String(e.last_season).padStart(2,'0')}E${String(e.last_episode).padStart(2,'0')} out — unwatched`;
      return `<div class="c" data-id="${e.tmdb_id}" data-n="${esc(e.name)}">
        <div class="n">${esc(e.name)}</div><div class="s ${e.available ? 'avail' : ''}">${lab}</div></div>`;
    }).join('');
    $('cal').querySelectorAll('.c').forEach(c => c.onclick = () => openShow(+c.dataset.id, c.dataset.n));
  } catch {}
}
function cd(air){
  const diff = air - Math.floor(Date.now() / 1000);
  if (diff <= -86400) return 'aired';
  if (diff <= 0) return 'today';
  const dd = Math.floor(diff / 86400);
  return dd >= 1 ? `in ${dd}d` : `in ${Math.floor(diff / 3600)}h`;
}
