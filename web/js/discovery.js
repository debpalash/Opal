'use strict';

// ── AI copilot ──
// /ai/send kicks off generation and returns {ok}; poll GET /ai for
// {generating,phase,messages,results}. `results` are playable picks the model
// resolved — play them straight from the answer.
let aiWatch = null;
function loadAi(){ api('/ai').then(renderAi).catch(()=>{}); }
$('ai-go').onclick = () => askAi();
$('ai-q').addEventListener('keydown', e => { if (e.key === 'Enter') { askAi(); $('ai-q').blur(); } });
$('ai-clear').onclick = () => { api('/ai/clear').then(loadAi).catch(()=>{}); };

function askAi(){
  const q = $('ai-q').value.trim(); if (!q) return;
  $('ai-q').value = '';
  $('ai-hint').innerHTML = '<span class="spin"></span> Thinking…';
  api('/ai/send?q=' + encodeURIComponent(q)).catch(()=>{});
  clearInterval(aiWatch);
  let ticks = 0;
  aiWatch = setInterval(async () => {
    ticks++;
    try {
      const d = await api('/ai');
      renderAi(d);
      if ((!d.generating && ticks > 2) || ticks > 150) {
        clearInterval(aiWatch);
        $('ai-hint').textContent = 'Ask for something to watch — answered by the local model.';
      } else if (d.phase) {
        $('ai-hint').innerHTML = '<span class="spin"></span> ' + esc(d.phase);
      }
    } catch { clearInterval(aiWatch); }
  }, 900);
}

function renderAi(d){
  const msgs = d.messages || [];
  const html = msgs.map(m => `<div class="msg ${m.role === 'user' ? 'me' : 'ai'}">${esc(m.text)}</div>`).join('')
    || '<div class="empty">No conversation yet — ask something.</div>';
  if (html !== lastHtml.ai) {
    lastHtml.ai = html;
    $('ai-log').innerHTML = html;
    $('ai-log').scrollTop = $('ai-log').scrollHeight;
  }
  const rh = (d.results || []).map(r => `
    <div class="result">
      <div class="t">${esc(r.name)}</div>
      <div class="m"><span class="src">${esc(r.detail || '')}</span>
        <button class="play" data-url="${encodeURIComponent(r.url || '')}">Play</button></div>
    </div>`).join('');
  if (rh !== lastHtml.aiRes) {
    lastHtml.aiRes = rh;
    $('ai-results').innerHTML = rh;
    $('ai-results').querySelectorAll('.play').forEach(b => b.onclick = () => {
      const u = b.dataset.url; if (!u) return;
      apiMutation('/load?url=' + u).catch(()=>{}); b.textContent = 'Sent ✓';
    });
  }
}

// ── Live TV ──
// /livetv pages the SQLite channel catalog server-side (~37k rows):
// ?q=&offset= → {total,offset,channels}. Adult channels follow the app's NSFW
// filter, exactly like the desktop tab. Hosted: play the stream URL in the
// browser <video> (HLS plays natively on Safari/iOS); companion: hand to mpv.
let tvOffset = 0, tvTotal = 0, tvQuery = '';
function loadTv(){ if (!$('tv-results').children.length) runTv(true); }
$('tv-go').onclick = () => runTv(true);
$('tv-q').addEventListener('keydown', e => { if (e.key === 'Enter') { runTv(true); $('tv-q').blur(); } });
$('tv-more').onclick = () => runTv(false);

async function runTv(reset){
  if (reset) { tvOffset = 0; tvQuery = $('tv-q').value.trim(); $('tv-results').innerHTML = ''; }
  $('tv-hint').innerHTML = '<span class="spin"></span> Loading channels…';
  try {
    const d = await api('/livetv?q=' + encodeURIComponent(tvQuery) + '&offset=' + tvOffset);
    tvTotal = d.total || 0;
    const got = d.channels || [];
    appendTv(got);
    tvOffset += got.length;
    $('tv-hint').textContent = tvTotal
      ? tvOffset + ' of ' + tvTotal.toLocaleString() + ' channels'
      : 'No channels yet — install a Live TV source in the desktop app.';
    $('tv-more').style.display = (tvOffset < tvTotal && got.length) ? '' : 'none';
  } catch { $('tv-hint').textContent = 'Could not load channels.'; }
}

function appendTv(chans){
  const html = chans.map(c => `
    <div class="result">
      <div class="t">${esc(c.name)}</div>
      <div class="m">
        ${c.country ? `<span class="src">${esc(c.country)}</span>` : ''}
        ${c.quality ? `<span>${esc(c.quality)}</span>` : ''}
        ${c.category ? `<span>${esc(c.category)}</span>` : ''}
        <button class="play" data-url="${encodeURIComponent(c.url)}" data-name="${esc(c.name)}">Watch</button>
      </div>
    </div>`).join('');
  $('tv-results').insertAdjacentHTML('beforeend', html);
  $('tv-results').querySelectorAll('.play:not([data-wired])').forEach(b => {
    b.setAttribute('data-wired', '1');
    b.onclick = () => {
      const url = decodeURIComponent(b.dataset.url);
      if (HOSTED) return openStreamUrl(url, b.dataset.name);
      dispatchPlay(url, b.dataset.name, () => {
        apiMutation('/load?url=' + encodeURIComponent(url)).catch(()=>{}); b.textContent = 'Sent ✓';
      });
    };
  });
}

// Play an external stream URL straight in the browser (Live TV). Distinct from
// openPlayer(), which streams a local downloaded file via /stream.
function openStreamUrl(url, title){
  const v = $('video');
  $('player-title').textContent = title || '';
  [...v.querySelectorAll('track')].forEach(tr => tr.remove());
  v.src = url;
  $('player').classList.add('on');
  v.onerror = () => { $('player-title').textContent = (title || '') + ' — stream not playable in this browser (try Safari for HLS)'; };
  v.play().catch(()=>{});
}

// ── YouTube ──
// /youtube/search triggers a background yt-dlp/InnerTube fetch and returns
// {ok:true}; poll GET /youtube for {items:[{id,title,channel,dur_min,dur_sec,
// views}],loading}. Playback is in-browser via the YouTube embed (works hosted
// AND companion); on a desktop companion we instead hand the URL to mpv (/load).
let ytWatch = null;
const fmtViews = n => { n = +n || 0; return n >= 1e6 ? (n/1e6).toFixed(1)+'M' : n >= 1e3 ? Math.round(n/1e3)+'K' : String(n); };
$('yt-go').onclick = () => runYt();
$('yt-q').addEventListener('keydown', e => { if (e.key === 'Enter') { runYt(); $('yt-q').blur(); } });
function runYt(){
  const q = $('yt-q').value.trim(); if (!q) return;
  $('yt-hint').innerHTML = '<span class="spin"></span> Searching YouTube…';
  $('yt-results').innerHTML = ''; lastHtml.yt = '';
  api('/youtube/search?q=' + encodeURIComponent(q)).catch(()=>{});
  clearInterval(ytWatch);
  let ticks = 0;
  ytWatch = setInterval(async () => {
    ticks++;
    try {
      const d = await api('/youtube');
      renderYt(d.items || []);
      if ((!d.loading && ticks > 2) || ticks > 40) {
        clearInterval(ytWatch);
        $('yt-hint').textContent = (d.items || []).length + ' videos.';
      }
    } catch { clearInterval(ytWatch); }
  }, 900);
}
function renderYt(items){
  const html = items.map(v => `
    <div class="result">
      <div class="t">${esc(v.title)}</div>
      <div class="m">
        <span class="src">${esc(v.channel || '')}</span>
        ${(v.dur_min || v.dur_sec) ? `<span>${v.dur_min}:${String(v.dur_sec).padStart(2,'0')}</span>` : ''}
        ${v.views ? `<span>${fmtViews(v.views)} views</span>` : ''}
        <button class="play" data-id="${esc(v.id)}" data-title="${esc(v.title)}">Play</button>
      </div>
    </div>`).join('') || '<div class="empty">No results yet</div>';
  if (html === lastHtml.yt) return;
  lastHtml.yt = html;
  $('yt-results').innerHTML = html;
  $('yt-results').querySelectorAll('.play').forEach(b => b.onclick = () => {
    if (HOSTED || PLAY_HERE) return openYtEmbed(b.dataset.id, b.dataset.title);
    apiMutation('/load?url=' + encodeURIComponent('https://www.youtube.com/watch?v=' + b.dataset.id)).catch(()=>{});
    b.textContent = 'Sent ✓';
  });
}
function openYtEmbed(id, title){
  $('yt-embed-title').textContent = title || '';
  $('yt-frame').src = 'https://www.youtube-nocookie.com/embed/' + encodeURIComponent(id) + '?autoplay=1';
  $('yt-embed').classList.add('on');
}
$('yt-embed-close').onclick = () => { $('yt-frame').src = ''; $('yt-embed').classList.remove('on'); };

// ── Podcasts ──
// Server routes are async: /podcasts/search & /podcasts/episodes trigger
// background work and return {ok:true}; poll GET /podcasts for
// {results,episodes,selected,loading,episodes_loading}.
let podWatch = null;
async function loadPodcasts(){
  try { renderPodcasts(await api('/podcasts')); } catch {}
}
function renderPodcasts(d){ renderPodResults(d.results || []); renderPodEpisodes(d.episodes || []); }
$('pod-go').onclick = () => runPodcasts();
$('pod-q').addEventListener('keydown', e => { if (e.key === 'Enter') { runPodcasts(); $('pod-q').blur(); } });
function runPodcasts(){
  const q = $('pod-q').value.trim(); if (!q) return;
  $('pod-hint').innerHTML = '<span class="spin"></span> Searching podcasts…';
  $('pod-results').innerHTML = ''; lastHtml.podResults = ''; $('pod-episodes').innerHTML = '';
  api('/podcasts/search?q=' + encodeURIComponent(q)).catch(()=>{});
  clearInterval(podWatch);
  let ticks = 0;
  podWatch = setInterval(async () => {
    ticks++;
    try {
      const d = await api('/podcasts');
      renderPodResults(d.results || []);
      if ((!d.loading && ticks > 2) || ticks > 40) {
        clearInterval(podWatch);
        $('pod-hint').textContent = (d.results || []).length + ' shows — tap one for episodes.';
      }
    } catch { clearInterval(podWatch); }
  }, 900);
}
function renderPodResults(rs){
  const html = rs.map((r, i) => `
    <div class="result pod">
      ${r.art
        ? `<img class="thumb" loading="lazy" src="${BASE}/api/podcasts/poster?idx=${i}">`
        : '<div class="thumb"></div>'}
      <div class="body">
        <div class="t">${esc(r.name)}</div>
        <div class="m"><button class="play" data-idx="${i}">Episodes ⭢</button></div>
      </div>
    </div>`).join('') || '<div class="empty">No results yet</div>';
  if (html === lastHtml.podResults) return;
  lastHtml.podResults = html;
  $('pod-results').innerHTML = html;
  $('pod-results').querySelectorAll('.play').forEach(b => b.onclick = () => loadPodEpisodes(+b.dataset.idx));
}
function loadPodEpisodes(idx){
  $('pod-episodes').innerHTML = '<div class="empty"><span class="spin"></span></div>';
  api('/podcasts/episodes?idx=' + idx).catch(()=>{});
  let tries = 0;
  const t = setInterval(async () => {
    tries++;
    try {
      const d = await api('/podcasts');
      if ((d.episodes || []).length || tries > 20) { clearInterval(t); renderPodEpisodes(d.episodes || []); }
    } catch { clearInterval(t); }
  }, 700);
}
function renderPodEpisodes(eps){
  $('pod-episodes').innerHTML = eps.length
    ? '<div class="sect">Episodes</div>' + eps.map((e, i) => `
      <div class="result">
        <div class="t">${esc(e.title)}</div>
        <div class="m"><span class="src">${esc([e.date, e.duration].filter(Boolean).join(' · '))}</span>
          <button class="play" data-ep="${i}">▶ Play</button></div>
      </div>`).join('')
    : '<div class="empty">No episodes</div>';
  $('pod-episodes').querySelectorAll('.play').forEach(b => b.onclick = () => {
    api('/podcasts/play?idx=' + encodeURIComponent(b.dataset.ep)).catch(()=>{});
    b.textContent = '▶';
  });
}

// ── Jellyfin ──
// GET /jellyfin -> {connected,loading,error?,libraries:[{id,name,type}],items:[{id,name,type,year,folder,runtime}]}.
// /jellyfin/{login,libraries,browse,search,play,play_audio,disconnect} trigger async work.
let jfWatch = null;
let jfLibTries = 0;          // bounded retry counter for empty-library polling
const JF_LIB_MAX = 8;        // stop after this many tries so we never hammer forever
async function loadJellyfin(){
  try { renderJellyfin(await api('/jellyfin')); } catch {}
}
function renderJellyfin(d){
  const conn = !!d.connected;
  $('jf-login').style.display = conn ? 'none' : 'block';
  $('jf-connected').style.display = conn ? 'block' : 'none';
  $('jf-hint').textContent = !conn && d.error ? d.error : '';
  if (conn) {
    renderJfLibraries(d.libraries || []);
    renderJfItems(d.items || []);
    if ((d.libraries || []).length) {
      jfLibTries = 0; // got libraries — done retrying
    } else if (document.getElementById('page-jf').classList.contains('on') && jfLibTries < JF_LIB_MAX) {
      // Libraries still empty: kick the background fetch ONCE (first retry only),
      // then re-poll — bounded by JF_LIB_MAX and only while the Jellyfin tab is
      // active. Stops when capped or the page is hidden.
      if (jfLibTries === 0) api('/jellyfin/libraries').catch(()=>{});
      jfLibTries++;
      setTimeout(loadJellyfin, 900);
    }
  }
}
function isJfAudio(t){ return t === 'Audio'; }
function renderJfLibraries(libs){
  $('jf-libs').innerHTML = libs.map(l => `<button data-id="${esc(l.id)}">${esc(l.name)}</button>`).join('');
  $('jf-libs').querySelectorAll('button').forEach(b => b.onclick = () => jfBrowse(b.dataset.id));
}
function renderJfItems(items){
  // Poster cards (image + title). Items without a Primary image (it.image
  // false) fall back to the placeholder <img> tile — graceful, still labelled.
  $('jf-items').innerHTML = items.length
    ? '<div class="grid">' + items.map(it => {
        const meta = [it.type, it.year || '', it.runtime ? fmt(it.runtime) : ''].filter(Boolean).join(' · ');
        return `<div class="card" data-id="${esc(it.id)}" data-folder="${it.folder}" data-type="${esc(it.type || '')}">
          ${it.image ? `<img loading="lazy" src="${BASE}/api/jellyfin/poster?id=${encodeURIComponent(it.id)}">` : '<img>'}
          <div class="cap">${esc(it.name)}<br><span class="rt">${esc(meta)}</span></div>
        </div>`;
      }).join('') + '</div>'
    : '<div class="empty">Nothing here</div>';
  $('jf-items').querySelectorAll('.card').forEach(el => el.onclick = () => {
    const id = el.dataset.id;
    if (el.dataset.folder === 'true') { jfBrowse(id); return; }
    const ep = isJfAudio(el.dataset.type) ? '/jellyfin/play_audio?id=' : '/jellyfin/play?id=';
    api(ep + encodeURIComponent(id)).catch(()=>{});
    el.style.opacity = '.55';
  });
}
function jfPollItems(){
  clearInterval(jfWatch);
  let tries = 0;
  jfWatch = setInterval(async () => {
    tries++;
    try {
      const d = await api('/jellyfin');
      if (!d.loading || tries > 15) { clearInterval(jfWatch); renderJfItems(d.items || []); }
    } catch { clearInterval(jfWatch); }
  }, 700);
}
function jfBrowse(id){
  $('jf-items').innerHTML = '<div class="empty"><span class="spin"></span></div>';
  api('/jellyfin/browse?id=' + encodeURIComponent(id)).catch(()=>{});
  jfPollItems();
}
$('jf-connect').onclick = () => {
  const s = $('jf-server').value.trim(), u = $('jf-user').value.trim(), p = $('jf-pass').value;
  if (!s || !u) { $('jf-hint').textContent = 'Enter server URL and username'; return; }
  $('jf-hint').innerHTML = '<span class="spin"></span> Connecting…';
  jfLibTries = 0; // fresh connection: allow the bounded library retry again
  api('/jellyfin/login?server=' + encodeURIComponent(s) + '&user=' + encodeURIComponent(u) + '&pass=' + encodeURIComponent(p)).catch(()=>{});
  clearInterval(jfWatch);
  let tries = 0;
  jfWatch = setInterval(async () => {
    tries++;
    try {
      const d = await api('/jellyfin');
      if (!d.loading && (d.connected || d.error || tries > 20)) {
        clearInterval(jfWatch);
        if (d.connected) { $('jf-pass').value = ''; }
        else { $('jf-hint').textContent = d.error || 'Connection failed'; }
        renderJellyfin(d);
      }
    } catch { clearInterval(jfWatch); }
  }, 900);
};
$('jf-search-go').onclick = () => {
  const q = $('jf-search').value.trim(); if (!q) return;
  $('jf-items').innerHTML = '<div class="empty"><span class="spin"></span></div>';
  api('/jellyfin/search?q=' + encodeURIComponent(q)).catch(()=>{});
  jfPollItems();
};
$('jf-search').addEventListener('keydown', e => { if (e.key === 'Enter') { $('jf-search-go').click(); $('jf-search').blur(); } });
$('jf-disconnect').onclick = async () => { try { await api('/jellyfin/disconnect'); } catch {} loadJellyfin(); };

// ── RSS ──
// GET /rss -> {feeds:[name], items:[{title,seeds,peers,size,magnet}], fetching}.
// /rss/refresh?idx=N re-fetches feed N; items carry a magnet -> /load like Search.
// The API sends sizes as a BYTE COUNT, sometimes as a numeric string and
// sometimes as -1 for "the source did not say". Coerce and reject the
// non-values here rather than at each call site — the search results list
// rendered `r.size` straight through and showed rows reading "69026891608".
function fmtSize(b){
  const n0 = typeof b === 'number' ? b : parseFloat(b);
  if (!Number.isFinite(n0) || n0 <= 0) return '';
  const u = ['B','KB','MB','GB','TB']; let i = 0, n = n0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return (n >= 10 || i === 0 ? Math.round(n) : n.toFixed(1)) + ' ' + u[i];
}
async function loadRss(){
  $('rss-hint').innerHTML = '<span class="spin"></span> Loading feeds…';
  try {
    const d = await api('/rss');
    renderRssFeeds(d.feeds || []);
    renderRssItems(d.items || [], d.fetching);
    $('rss-hint').textContent = (d.feeds || []).length
      ? 'Tap a feed to refresh — tap Play to send to the desktop.'
      : 'No RSS feeds configured on the desktop.';
  } catch { $('rss-hint').textContent = '—'; }
}
function renderRssFeeds(feeds){
  $('rss-feeds').innerHTML = feeds.map((f, i) => `<button data-idx="${i}">${esc(f)}</button>`).join('');
  $('rss-feeds').querySelectorAll('button').forEach(b => b.onclick = () => refreshFeed(+b.dataset.idx, b));
}
function refreshFeed(idx, btn){
  document.querySelectorAll('#rss-feeds button').forEach(x => x.classList.toggle('on', x === btn));
  $('rss-hint').innerHTML = '<span class="spin"></span> Refreshing…';
  api('/rss/refresh?idx=' + idx).catch(()=>{});
  let tries = 0;
  const t = setInterval(async () => {
    tries++;
    try {
      const d = await api('/rss');
      renderRssItems(d.items || [], d.fetching);
      if (!d.fetching || tries > 15) {
        clearInterval(t);
        $('rss-hint').textContent = (d.items || []).length + ' items — tap Play to send to the desktop.';
      }
    } catch { clearInterval(t); }
  }, 900);
}
function renderRssItems(items, fetching){
  const html = items.slice(0, 80).map(it => `
    <div class="result">
      <div class="t">${esc(it.title)}</div>
      <div class="m">
        ${it.seeds ? `<span>▲ ${esc(String(it.seeds))}</span>` : ''}
        ${it.size ? `<span>${fmtSize(it.size)}</span>` : ''}
        <button class="play" data-url="${encodeURIComponent(it.magnet || '')}">Play</button>
      </div>
    </div>`).join('') || (fetching ? '<div class="empty"><span class="spin"></span></div>' : '<div class="empty">No items — refresh a feed</div>');
  if (html === lastHtml.rssItems) return;
  lastHtml.rssItems = html;
  $('rss-items').innerHTML = html;
  $('rss-items').querySelectorAll('.play').forEach(b => b.onclick = () => {
    const u = b.dataset.url; if (!u) return;
    b.textContent = 'Sent ✓';
    apiMutation('/load?url=' + u).catch(()=>{});
  });
}
