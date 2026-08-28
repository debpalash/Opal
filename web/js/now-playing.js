'use strict';

// ── Now Playing ──
const fmt = s => { if (!isFinite(s) || s < 0) return '--:--';
  const h = ~~(s/3600), m = ~~((s%3600)/60), ss = ~~(s%60);
  return (h ? h + ':' + String(m).padStart(2,'0') : m) + ':' + String(ss).padStart(2,'0'); };
const PLAY = 'M8 5v14l11-7L8 5z', PAUSE = 'M6 5h4v14H6zM14 5h4v14h-4z';

const mediaKindLabel = kind => ({
  tv:'TV show', movie:'Movie', anime:'Anime', music:'Music', album:'Album',
  podcast:'Podcast', stream:'Live stream',
})[kind] || '';

function setStatusText(id, value){
  const element = $(id), next = value || '';
  if (element.textContent !== next) element.textContent = next;
}

function renderStatusChips(id, chips){
  const container = $(id);
  const signature = chips.map(chip => `${chip.text}:${chip.className || ''}`).join('|');
  if (container.dataset.value === signature) return;
  container.dataset.value = signature;
  container.replaceChildren(...chips.map(chip => {
    const element = document.createElement('span');
    element.className = `np-chip${chip.className ? ' ' + chip.className : ''}`;
    element.textContent = chip.text;
    return element;
  }));
}

function syncNowPlayingArt(active, status){
  const art = $('np-art');
  const key = status.has_art && status.art_key ? String(status.art_key) : '';
  if (!active || !key) {
    if (art.dataset.key) art.removeAttribute('src');
    art.dataset.key = '';
    art.hidden = true;
    return;
  }
  art.classList.toggle('square', ['album', 'music', 'podcast'].includes(status.kind));
  if (art.dataset.key === key) return;
  art.dataset.key = key;
  art.hidden = false;
  art.src = `${BASE}/now-playing/art?k=${encodeURIComponent(key)}`;
}

$('np-art').onload = () => { $('np-art').hidden = false; };
$('np-art').onerror = () => { $('np-art').hidden = true; };

function applyStatus(d){
  $('conn-dot').classList.add('on');
  const active = d.active === true || (d.active == null && d.title && d.title !== 'No media');
  const state = d.recovering ? 'Recovering'
    : d.loading ? 'Loading'
    : d.buffering ? 'Buffering'
    : d.paused ? 'Paused' : 'Playing';
  const duration = Number.isFinite(+d.dur) ? Math.max(0, +d.dur) : 0;
  const position = Number.isFinite(+d.pos) ? Math.max(0, +d.pos) : 0;

  setStatusText('np-title', active ? d.title : 'Nothing playing');
  setStatusText('np-sub', active
    ? (d.subtitle || `${state} on desktop`)
    : 'Play something from Search, or on the desktop.');
  setStatusText('np-overview', active ? d.overview : '');
  $('np-overview').hidden = !active || !d.overview;
  $('page-np').setAttribute('aria-busy', active && (d.loading || d.buffering) ? 'true' : 'false');

  const meta = [];
  if (active) {
    meta.push({text:state, className:`state ${state.toLowerCase()}`});
    const kind = mediaKindLabel(d.kind); if (kind) meta.push({text:kind});
    if (d.year) meta.push({text:String(d.year)});
    if (Number.isFinite(+d.rating) && +d.rating > 0) meta.push({text:`★ ${(+d.rating).toFixed(1)}`});
    if (d.extra) meta.push({text:String(d.extra)});
    if (d.source === 'torrent') meta.push({text:'Torrent'});
  }
  renderStatusChips('np-meta', meta);

  const presence = [];
  if (active && d.casting) presence.push({text:'Casting'});
  if (active && d.party_role === 'host') {
    const peers = Math.max(0, Number(d.party_peers) || 0);
    presence.push({text:`Watch party host · ${peers} peer${peers === 1 ? '' : 's'}`});
  } else if (active && d.party_role === 'client') {
    presence.push({text:'Joined watch party'});
  }
  renderStatusChips('np-presence', presence);
  syncNowPlayingArt(active, d);

  setStatusText('t-pos', fmt(position));
  setStatusText('t-dur', fmt(duration));
  $('i-pp').firstElementChild.setAttribute('d', !active || d.paused ? PLAY : PAUSE);
  if (!seekHeld) $('seek').value = duration > 0 ? position / duration * 100 : 0;
  if (!volHeld && Number.isFinite(+d.vol)) $('vol').value = d.vol;
  $('seek').disabled = !active || duration <= 0;
  $('vol').disabled = !active;
  for (const id of ['b-toggle', 'b-back', 'b-fwd', 'b-mute']) $(id).disabled = !active;
}
// EventSource sends the same-origin HttpOnly session cookie automatically.
let es = null, pollTimer = null;
function startStatus(){
  if (es) { es.close(); es = null; }
  try {
    es = new EventSource(BASE + '/events');
    es.onmessage = e => { try { applyStatus(JSON.parse(e.data)); } catch {} };
    es.onerror = () => { es.close(); es = null; $('conn-dot').classList.remove('on'); poll(); };
  } catch { poll(); }
}
async function poll(){
  clearTimeout(pollTimer);
  try { applyStatus(await api('/status')); } catch { $('conn-dot').classList.remove('on'); }
  pollTimer = setTimeout(poll, 1000); // fallback loop only
}
let seekHeld = false, volHeld = false;
$('seek').addEventListener('pointerdown', () => seekHeld = true);
$('seek').addEventListener('change', () => { api('/seek_pct?v=' + Math.round($('seek').value)).catch(()=>{}); seekHeld = false; });
$('vol').addEventListener('pointerdown', () => volHeld = true);
$('vol').addEventListener('change', () => { api('/volume?v=' + Math.round($('vol').value)).catch(()=>{}); volHeld = false; });
$('b-toggle').onclick = () => api('/toggle').catch(()=>{});
$('b-back').onclick   = () => api('/back').catch(()=>{});
$('b-fwd').onclick    = () => api('/fwd').catch(()=>{});
$('b-mute').onclick   = () => api('/mute').catch(()=>{});
$('b-sub').onclick    = () => api('/next_sub').then(() => toast('Switched subtitle track')).catch(()=>{});
$('b-aud').onclick    = () => api('/next_audio').then(() => toast('Switched audio track')).catch(()=>{});
$('b-fs').onclick     = () => api('/fullscreen').catch(()=>{});
$('b-rotate').onclick = () => api('/rotate').then(() => toast('Rotated picture')).catch(()=>{});
$('b-flip').onclick   = () => api('/flip').then(() => toast('Flipped picture')).catch(()=>{});

// Cast is already a complete remote API; the web page previously left it to
// the browser extension, so phone users could not choose a living-room screen.
let castWatch = null, castPolls = 0;
function setCastOpen(open){
  $('cast-panel').hidden = !open;
  $('b-cast').setAttribute('aria-expanded', open ? 'true' : 'false');
  if (!open) clearTimeout(castWatch);
}
async function loadCastDevices(){
  clearTimeout(castWatch);
  try {
    const d = await api('/cast/devices');
    const devices = d.devices || [];
    $('cast-hint').textContent = d.scanning
      ? 'Scanning your network…'
      : devices.length ? `${devices.length} device${devices.length === 1 ? '' : 's'} found` : 'No cast devices found.';
    $('cast-stop').hidden = !d.casting;
    $('cast-devices').innerHTML = devices.map((x, i) => `
      <button type="button" class="cast-device ${d.active === i ? 'active' : ''}" data-i="${i}"
        aria-pressed="${d.active === i ? 'true' : 'false'}">
        <span>${esc(x.name || 'Cast device')}</span><small>${esc(x.ip || '')}</small>
      </button>`).join('');
    $('cast-devices').querySelectorAll('.cast-device').forEach(b => b.onclick = async () => {
      const device = devices[+b.dataset.i];
      await api('/cast/start?idx=' + b.dataset.i).catch(()=>{});
      toast('Casting to ' + (device?.name || 'device'));
      castPolls = 0; loadCastDevices();
    });
    if (d.scanning && castPolls++ < 20) castWatch = setTimeout(loadCastDevices, 900);
  } catch { $('cast-hint').textContent = 'Could not scan — install catt on the Opal machine.'; }
}
$('b-cast').onclick = () => {
  const open = $('cast-panel').hidden;
  setCastOpen(open);
  if (open) { castPolls = 0; loadCastDevices(); }
};
$('cast-scan').onclick = async () => {
  castPolls = 0; $('cast-hint').textContent = 'Scanning your network…';
  await api('/cast/scan').catch(()=>{}); loadCastDevices();
};
$('cast-stop').onclick = async () => {
  await api('/cast/stop').catch(()=>{}); toast('Casting stopped'); loadCastDevices();
};

// One rich player snapshot powers the whole advanced deck. The server exposes
// bounded typed actions rather than raw mpv commands, so every select/range
// below shares the same validation and state contract as the native controls.
let playerToolsWatch = null;
function setPlayerToolsOpen(open){
  $('player-tools').hidden = !open;
  $('b-player-tools').setAttribute('aria-expanded', open ? 'true' : 'false');
  clearTimeout(playerToolsWatch);
  if (open) loadPlayerTools(true);
}
$('b-player-tools').onclick = () => setPlayerToolsOpen($('player-tools').hidden);
$('player-tools-refresh').onclick = () => loadPlayerTools(true);

const playerNum = (v, fallback=0) => Number.isFinite(+v) ? +v : fallback;
const playerOption = (value, label, current) =>
  `<option value="${esc(String(value))}"${String(value) === String(current) ? ' selected' : ''}>${esc(label)}</option>`;
function playerRange(id, label, action, value, min, max, step, suffix){
  const v = Math.max(min, Math.min(max, playerNum(value)));
  return `<div class="tool"><div class="tool-range-head"><label for="${id}">${label}</label>
      <output for="${id}">${v.toFixed(step < 1 ? 1 : 0)}${suffix || ''}</output></div>
    <input id="${id}" type="range" min="${min}" max="${max}" step="${step}" value="${v}"
      data-player-action="${action}" data-suffix="${esc(suffix || '')}"></div>`;
}
function renderPlayerTools(d){
  const s = d.state || {};
  const chapters = d.chapters || [], audio = d.tracks?.audio || [], subtitles = d.tracks?.subtitles || [];
  const devices = d.audio_devices || [];
  const speedNow = playerNum(s.speed, 1);
  const speeds = [...new Set([.25,.5,.75,1,1.25,1.5,2,3,4,speedNow])].sort((a,b) => a-b);
  const aspectNow = !s.aspect || s.aspect === '-1' || s.aspect === 'no' ? 'auto' : s.aspect;
  $('player-tools-state').textContent = `Playback controls ready${s.title ? ' for ' + s.title : ''}.`;
  $('player-tools-body').innerHTML = `<div class="tool-grid">
    <div class="tool"><label for="tool-speed">Playback speed</label><select id="tool-speed" data-player-action="speed">
      ${speeds.map(v => playerOption(v, `${v}×`, speedNow)).join('')}</select></div>
    <div class="tool"><label for="tool-aspect">Aspect ratio</label><select id="tool-aspect" data-player-action="aspect">
      ${[['auto','Auto'],['16:9','16:9'],['4:3','4:3'],['21:9','21:9']].map(x => playerOption(x[0],x[1],aspectNow)).join('')}</select></div>
    <div class="tool"><label for="tool-repeat">Repeat</label><select id="tool-repeat" data-player-action="repeat">
      ${[['off','Off'],['all','All'],['one','One']].map(x => playerOption(x[0],x[1],s.playlist_repeat || 'off')).join('')}</select></div>
    <div class="tool"><label for="tool-shuffle">Shuffle</label><select id="tool-shuffle" data-player-action="shuffle">
      ${[['false','Off'],['true','On']].map(x => playerOption(x[0],x[1],String(!!s.playlist_shuffle))).join('')}</select></div>
    <div class="tool"><label for="tool-chapter">Chapter</label><select id="tool-chapter" data-player-action="chapter"${chapters.length ? '' : ' disabled'}>
      ${chapters.length ? chapters.map(ch => playerOption(ch.id, `${fmt(ch.time)} · ${ch.title || 'Chapter ' + (+ch.id + 1)}`, s.chapter)).join('') : '<option>No chapters</option>'}</select></div>
    <div class="tool"><label for="tool-audio">Audio track</label><select id="tool-audio" data-player-action="audio-track"${audio.length ? '' : ' disabled'}>
      ${audio.length ? audio.map(t => playerOption(t.id, `${t.label}${t.lang ? ' · ' + t.lang : ''}`, t.selected ? t.id : '')).join('') : '<option>No alternate tracks</option>'}</select></div>
    <div class="tool"><label for="tool-subtitle">Subtitle track</label><select id="tool-subtitle" data-player-action="subtitle-track">
      ${playerOption('off','Off',subtitles.some(t => t.selected) ? '' : 'off')}${subtitles.map(t => playerOption(t.id, `${t.label}${t.lang ? ' · ' + t.lang : ''}`, t.selected ? t.id : '')).join('')}</select></div>
    <div class="tool"><label for="tool-device">Audio output</label><select id="tool-device" data-player-action="audio-device"${devices.length ? '' : ' disabled'}>
      ${devices.length ? devices.map(x => playerOption(x.name,x.label || x.name,x.selected ? x.name : '')).join('') : '<option>No devices reported</option>'}</select></div>
    <div class="tool"><label for="tool-picture">Picture preset</label><select id="tool-picture" data-player-action="picture-preset">
      ${['Auto','Standard','HDR','Cinema','TV Show','Vivid'].map((x,i) => playerOption(i,x,s.picture_preset)).join('')}</select></div>
    <div class="tool"><label for="tool-eq">Audio equalizer</label><select id="tool-eq" data-player-action="equalizer-preset">
      ${['Flat','Bass+','Voice','Cinema','Loud'].map((x,i) => playerOption(i,x,s.equalizer_preset)).join('')}</select></div>
    ${playerRange('tool-sub-delay','Subtitle delay','subtitle-delay',s.subtitle_delay,-10,10,.1,'s')}
    ${playerRange('tool-zoom','Zoom','zoom',s.zoom,-2,2,.1,'')}
    ${playerRange('tool-pan-x','Pan horizontally','pan-x',s.pan_x,-1,1,.05,'')}
    ${playerRange('tool-pan-y','Pan vertically','pan-y',s.pan_y,-1,1,.05,'')}
    ${playerRange('tool-brightness','Brightness','brightness',s.brightness,-100,100,5,'')}
    ${playerRange('tool-contrast','Contrast','contrast',s.contrast,-100,100,5,'')}
    ${playerRange('tool-saturation','Saturation','saturation',s.saturation,-100,100,5,'')}
    ${playerRange('tool-gamma','Gamma','gamma',s.gamma,-100,100,5,'')}
  </div>
  <div class="tool-actions">
    <button type="button" data-player-action="playlist-previous">Previous item</button>
    <button type="button" data-player-action="playlist-next">Next item</button>
    <button type="button" data-player-action="frame-previous">Previous frame</button>
    <button type="button" data-player-action="frame-next">Next frame</button>
    <button type="button" data-player-action="screenshot">Screenshot</button>
    <button type="button" data-player-action="loop-a">Set loop A</button>
    <button type="button" data-player-action="loop-b">Set loop B</button>
    <button type="button" data-player-action="loop-clear">Clear loop</button>
    <button type="button" data-player-action="clip-export">Export A–B clip</button>
    <button type="button" class="danger" data-player-action="close">Close desktop player</button>
  </div>`;
  wirePlayerTools();
}
function wirePlayerTools(){
  $('player-tools-body').querySelectorAll('select[data-player-action]').forEach(el => {
    el.onchange = () => runPlayerAction(el.dataset.playerAction, el.value, el);
  });
  $('player-tools-body').querySelectorAll('input[type=range][data-player-action]').forEach(el => {
    const output = el.closest('.tool').querySelector('output');
    el.oninput = () => { output.textContent = (+el.value).toFixed(+el.step < 1 ? 1 : 0) + (el.dataset.suffix || ''); };
    el.onchange = () => runPlayerAction(el.dataset.playerAction, el.value, el);
  });
  $('player-tools-body').querySelectorAll('button[data-player-action]').forEach(el => {
    el.onclick = () => runPlayerAction(el.dataset.playerAction, el.dataset.value, el);
  });
}
async function runPlayerAction(action, value, control){
  if (control) control.disabled = true;
  $('player-tools-state').textContent = 'Applying playback change…';
  const suffix = '&action=' + encodeURIComponent(action)
    + (value === undefined ? '' : '&value=' + encodeURIComponent(value));
  try {
    await apiMutation('/player/action?' + suffix.slice(1));
    toast('Playback updated');
    await loadPlayerTools(true);
  } catch (e) {
    $('player-tools-state').textContent = e.message || 'Playback change failed.';
    if (control) control.disabled = false;
  }
}
async function loadPlayerTools(force){
  clearTimeout(playerToolsWatch);
  if ($('player-tools').hidden) return;
  try {
    const d = await api('/player');
    if (force || !$('player-tools-body').contains(document.activeElement)) renderPlayerTools(d);
  } catch { $('player-tools-state').textContent = 'No desktop player is available.'; }
  if (!$('player-tools').hidden) playerToolsWatch = setTimeout(() => loadPlayerTools(false), 2500);
}
