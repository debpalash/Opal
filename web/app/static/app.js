/* ZigZag Web UI — Client-side API bridge */
const API = 'http://' + window.location.hostname + ':9876';

function api(action) {
  return fetch(API + '/api/' + action).then(r => r.json()).catch(() => ({}));
}

function fmt(s) {
  if (!s || s < 0) return '--:--';
  const m = Math.floor(s / 60), ss = Math.floor(s % 60);
  return m + ':' + (ss < 10 ? '0' : '') + ss;
}

// ═══ Status polling ═══
function pollStatus() {
  api('status').then(d => {
    if (!d || d.error) return;

    // Now playing
    const title = document.getElementById('np-title');
    const time = document.getElementById('np-time');
    const progress = document.getElementById('np-progress');
    if (title) title.textContent = d.title || 'Now Playing';
    if (time) time.textContent = fmt(d.pos) + ' / ' + fmt(d.dur) + (d.paused ? ' ⏸' : ' ▶');
    if (progress && d.dur > 0) progress.style.width = ((d.pos / d.dur) * 100) + '%';

    // Stats
    const vol = document.getElementById('stat-vol');
    const pos = document.getElementById('stat-pos');
    const dur = document.getElementById('stat-dur');
    if (vol) vol.textContent = Math.round(d.vol) + '%';
    if (pos) pos.textContent = fmt(d.pos);
    if (dur) dur.textContent = fmt(d.dur);

    // Sliders
    const seekSlider = document.getElementById('seek-slider');
    if (seekSlider && d.dur > 0 && !seekSlider.matches(':active')) {
      seekSlider.value = (d.pos / d.dur) * 100;
    }
    const volSlider = document.getElementById('vol-slider');
    if (volSlider && !volSlider.matches(':active')) {
      volSlider.value = d.vol;
    }
    const volLabel = document.getElementById('vol-label');
    if (volLabel) volLabel.textContent = Math.round(d.vol) + '%';
  });
}

setInterval(pollStatus, 1000);
pollStatus();

// ═══ Player controls ═══
function seekTo(event) {
  const bar = event.currentTarget;
  const rect = bar.getBoundingClientRect();
  const pct = (event.clientX - rect.left) / rect.width;
  api('seek_pct?v=' + Math.round(pct * 100));
}

function seekPercent(pct) {
  api('seek_pct?v=' + pct);
}

function setVolume(v) {
  api('volume?v=' + v);
  const label = document.getElementById('vol-label');
  if (label) label.textContent = v + '%';
}

// ═══ Search ═══
function doSearch() {
  const input = document.getElementById('search-input');
  if (!input || !input.value.trim()) return;
  const q = encodeURIComponent(input.value.trim());
  const body = document.getElementById('results-body');
  if (body) body.innerHTML = '<tr><td colspan="5" style="text-align:center; padding:20px; color:var(--text-dim)">Searching...</td></tr>';
  
  api('search?q=' + q).then(d => {
    if (!body || !d.results) return;
    if (d.results.length === 0) {
      body.innerHTML = '<tr><td colspan="5" style="text-align:center; padding:20px; color:var(--text-dim)">No results found</td></tr>';
      return;
    }
    body.innerHTML = d.results.map((r, i) =>
      '<tr>' +
        '<td>' + escHtml(r.title) + '</td>' +
        '<td class="size">' + (r.size || '-') + '</td>' +
        '<td class="seeds">' + (r.seeds || '-') + '</td>' +
        '<td>' + (r.source || '-') + '</td>' +
        '<td><button class="btn" onclick="playResult(' + i + ')">▶ Play</button></td>' +
      '</tr>'
    ).join('');
    window._searchResults = d.results;
  });
}

function playResult(i) {
  if (window._searchResults && window._searchResults[i]) {
    const r = window._searchResults[i];
    api('load?url=' + encodeURIComponent(r.magnet || r.url));
    showToast('Loading: ' + r.title);
  }
}

// ═══ Queue ═══
function refreshQueue() {
  api('queue').then(d => {
    const list = document.getElementById('queue-list');
    if (!list || !d.items) return;
    if (d.items.length === 0) {
      list.innerHTML = '<div style="color:var(--text-dim); text-align:center; padding:40px">Queue is empty</div>';
      return;
    }
    list.innerHTML = d.items.map((item, i) =>
      '<div class="queue-item">' +
        '<div class="thumb">🎬</div>' +
        '<div class="meta">' +
          '<div class="name">' + escHtml(item.title || item.url) + '</div>' +
          '<div class="detail">' + (item.played ? '✓ Played' : 'Pending') + '</div>' +
        '</div>' +
        '<button class="btn" onclick="api(\'queue/play?id=' + i + '\')">▶</button>' +
      '</div>'
    ).join('');
  });
}

// ═══ Watch Party ═══
function joinParty() {
  const ip = document.getElementById('party-ip');
  if (!ip || !ip.value.trim()) return;
  api('party/join?ip=' + encodeURIComponent(ip.value.trim())).then(() => {
    showToast('Joining party at ' + ip.value);
    const status = document.getElementById('party-status');
    if (status) status.textContent = 'Connected to ' + ip.value;
  });
}

// ═══ Cast ═══
function scanDevices() {
  const list = document.getElementById('cast-devices');
  if (list) list.innerHTML = '<div style="text-align:center; padding:20px; color:var(--text-dim)">Scanning...</div>';
  api('cast/devices').then(d => {
    if (!list || !d.devices) return;
    if (d.devices.length === 0) {
      list.innerHTML = '<div style="text-align:center; padding:20px; color:var(--text-dim)">No devices found</div>';
      return;
    }
    list.innerHTML = d.devices.map((dev, i) =>
      '<div class="queue-item">' +
        '<div class="thumb">📺</div>' +
        '<div class="meta"><div class="name">' + escHtml(dev.name) + '</div></div>' +
        '<button class="btn btn-primary" onclick="api(\'cast/start?id=' + i + '\')">Cast</button>' +
      '</div>'
    ).join('');
  });
}

// ═══ Settings ═══
function toggleSetting(name) {
  api('settings/toggle?key=' + name).then(() => {
    const el = document.getElementById('toggle-' + name.replace('_', ''));
    if (el) el.classList.toggle('active');
  });
}

// ═══ Helpers ═══
function escHtml(s) {
  const d = document.createElement('div');
  d.textContent = s || '';
  return d.innerHTML;
}

function showToast(msg) {
  const t = document.createElement('div');
  t.className = 'toast';
  t.textContent = msg;
  document.body.appendChild(t);
  setTimeout(() => t.remove(), 3000);
}

// ═══ Init ═══
document.addEventListener('DOMContentLoaded', () => {
  // Auto-refresh queue if on queue page
  if (window.location.pathname === '/queue') refreshQueue();
  
  // Search on Enter
  const si = document.getElementById('search-input');
  if (si) si.addEventListener('keydown', e => { if (e.key === 'Enter') doSearch(); });

  // Mobile hamburger
  const burger = document.getElementById('menu-toggle');
  if (burger) burger.addEventListener('click', () => {
    document.getElementById('sidebar').classList.toggle('open');
  });
});
