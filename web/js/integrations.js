'use strict';

// ── Plugins (Setup › Plugins) ──
let pluginSources = [];
let executablePlugins = [];
let pluginPollTimer = 0;
let pluginPollRemaining = 0;
const pluginGroups = [
  ['torrent', 'Torrent indexers'], ['stremio', 'Stremio add-ons'],
  ['anime', 'Anime'], ['comics', 'Comics & Manga'],
  ['metadata', 'Metadata'], ['other', 'Other'],
];
function pluginGroup(kind){
  const value = String(kind || '').toLowerCase();
  if (value === 'torrent' || value === 'stremio' || value === 'anime' || value === 'metadata') return value;
  if (value === 'comics' || value === 'manga') return 'comics';
  return 'other';
}
function renderPlugins(){
  const query = $('plug-filter').value.trim().toLowerCase();
  const installedOnly = $('plug-installed').checked;
  const visible = pluginSources.filter(source => {
    if (installedOnly && !source.installed) return false;
    return !query || `${source.name || ''} ${source.id || ''} ${source.kind || ''}`.toLowerCase().includes(query);
  });
  $('plug-list').innerHTML = pluginGroups.map(([group, label]) => {
    const rows = visible.filter(source => pluginGroup(source.kind) === group)
      .sort((a, b) => String(a.name || a.id).localeCompare(String(b.name || b.id)))
      .map(source => `<div class="file plugin-row">
        <div class="n">${esc(source.name || source.id)}
          <div class="file-meta"><span class="src">${esc(source.kind || 'source')}</span>
            ${source.version ? `<span>v${esc(source.version)}</span>` : ''}
            <span>${source.installed ? 'Installed' : 'Available'}</span></div></div>
        <button type="button" class="plugin-action${source.installed ? ' remove' : ''}"
          data-action="${source.installed ? 'uninstall' : 'install'}"
          data-id="${encodeURIComponent(source.id)}">${source.installed ? 'Uninstall' : 'Install'}</button>
      </div>`).join('');
    return rows ? `<div class="plugin-category">${label}</div>${rows}` : '';
  }).join('') || '<div class="empty">No sources match this filter.</div>';
}
function renderExecutablePlugins(){
  $('plug-exec-list').innerHTML = executablePlugins.map(plugin => {
    const capabilities = [plugin.search && 'Search', plugin.resolve && 'Resolve', plugin.trending && 'Trending'].filter(Boolean);
    const needsApproval = plugin.mode === 'blocked' || (plugin.allow_unsafe && !plugin.trusted);
    const modeLabel = plugin.mode === 'invalid' ? 'Invalid manifest' : plugin.mode === 'blocked' ? 'Blocked' : plugin.mode === 'full-access' ? 'Full user access' : 'Lua sandbox';
    return `<div class="file plugin-row executable-plugin ${plugin.mode === 'blocked' || plugin.mode === 'invalid' ? 'plugin-blocked' : ''}">
      <div class="n">${esc(plugin.name || plugin.id)}
        <div class="file-meta"><span class="src">${esc(modeLabel)}</span>
          ${plugin.version ? `<span>v${esc(plugin.version)}</span>` : ''}<span>${esc(capabilities.join(' · ') || 'No runnable entrypoints')}</span></div>
        ${plugin.description ? `<small>${esc(plugin.description)}</small>` : ''}</div>
      ${plugin.trusted ? `<button type="button" class="plugin-action remove" data-exec-action="revoke-exec" data-id="${encodeURIComponent(plugin.id)}">Revoke access</button>`
        : needsApproval ? `<button type="button" class="plugin-action" data-exec-action="approve-exec" data-id="${encodeURIComponent(plugin.id)}">Review & approve</button>` : ''}
    </div>`;
  }).join('') || '<div class="empty">No executable content plugins installed.</div>';
}
async function loadPlugins(){
  try {
    const d = await api('/plugins');
    pluginSources = Array.isArray(d.sources) ? d.sources : [];
    executablePlugins = Array.isArray(d.executables) ? d.executables : [];
    const installed = pluginSources.filter(source => source.installed).length;
    const state = d.status === 'fetching' ? ' · refreshing catalog…'
      : d.status === 'err' ? ' · refresh failed; cached catalog shown' : '';
    $('plug-hint').textContent = `${installed} of ${pluginSources.length} source plugins installed${state}`;
    if (document.activeElement !== $('plug-repo')) $('plug-repo').value = d.repo || '';
    if (document.activeElement !== $('plug-debrid-provider')) $('plug-debrid-provider').value = d.debrid_provider || '';
    // Credentials are never echoed back — show only whether one is set.
    $('plug-token').placeholder = d.has_token ? 'set — type to replace' : 'not set';
    $('plug-debrid-key').placeholder = d.has_debrid_key ? 'set — type to replace' : 'not set';
    renderPlugins();
    renderExecutablePlugins();
    clearTimeout(pluginPollTimer);
    if (d.status === 'fetching' && pluginPollRemaining > 0) {
      pluginPollRemaining--;
      pluginPollTimer = setTimeout(loadPlugins, 1200);
    } else if (d.status !== 'fetching') {
      pluginPollRemaining = 0;
    }
  } catch { $('plug-hint').textContent = 'Could not load plugins.'; }
}
$('plug-filter').oninput = renderPlugins;
$('plug-installed').onchange = renderPlugins;
async function changePlugin(action, id){
  if (action === 'uninstall' && !confirm('Uninstall this source? Searches will stop using it.')) return;
  const params = new URLSearchParams({action});
  if (id) params.set('id', id);
  if (action === 'uninstall') params.set('confirm', '1');
  $('plug-list').setAttribute('aria-busy', 'true');
  $('plug-hint').textContent = action === 'refresh' ? 'Refreshing source catalog…'
    : action === 'update' ? 'Checking installed source versions…' : `${action === 'install' ? 'Installing' : 'Uninstalling'} source…`;
  try {
    const result = await apiMutation('/plugins?' + params);
    const message = action === 'refresh' ? 'Catalog refresh started'
      : action === 'update' ? (result.result === 'unchanged' ? 'Installed sources are up to date' : 'Installed sources updated')
      : action === 'install' ? (result.result === 'unchanged' ? 'Source already installed' : 'Source installed')
      : 'Source uninstalled';
    toast(message);
    if (action === 'refresh' && result.result === 'accepted') pluginPollRemaining = 12;
    await loadPlugins();
    // Refresh and file-backed installs finish on a worker. Re-read once without
    // inventing browser-only state; the server remains the source of truth.
    if (action !== 'refresh' && result.result === 'accepted') setTimeout(loadPlugins, 1200);
  } catch (error) {
    $('plug-hint').textContent = error.message || 'Could not update source.';
  } finally {
    $('plug-list').setAttribute('aria-busy', 'false');
  }
}
$('plug-refresh').onclick = () => changePlugin('refresh');
$('plug-update').onclick = () => changePlugin('update');
$('plug-list').addEventListener('click', event => {
  const button = event.target.closest('button[data-action][data-id]');
  if (button) changePlugin(button.dataset.action, decodeURIComponent(button.dataset.id));
});
$('plug-exec-list').addEventListener('click', async event => {
  const button = event.target.closest('button[data-exec-action][data-id]');
  if (!button) return;
  const action = button.dataset.execAction;
  const id = decodeURIComponent(button.dataset.id);
  const plugin = executablePlugins.find(item => item.id === id);
  const warning = action === 'approve-exec'
    ? `Approve ${plugin?.name || id}? Native or unsafe plugins run with your user account's file and network access. Approval is revoked automatically when its files change.`
    : `Revoke execution access for ${plugin?.name || id}?`;
  if (!confirm(warning)) return;
  button.disabled = true;
  try {
    await apiMutation('/plugins?' + new URLSearchParams({action, id, confirm:'1'}));
    toast(action === 'approve-exec' ? 'Plugin version approved' : 'Plugin access revoked');
    await loadPlugins();
  } catch (error) {
    toast(error.message || 'Could not change plugin access');
    button.disabled = false;
  }
});
$('plug-save').onclick = async () => {
  // Body, not query string: the token and the debrid key are secrets, and a URL
  // is the one place they would be logged or land in browser history. The
  // server reads the body ahead of the query (credParam).
  const put = async (k, v) => {
    const response = await networkFetch(BASE + '/api/plugins', {
    method: 'POST',
    credentials: 'same-origin',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: 'key=' + encodeURIComponent(k) + '&value=' + encodeURIComponent(v),
    });
    const data = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(data.error || 'Could not save integration');
  };
  try {
    await put('repo', $('plug-repo').value.trim());
    await put('debrid_provider', $('plug-debrid-provider').value.trim());
    // Empty means "leave alone", not "clear" — otherwise opening the page and
    // saving would silently wipe a token you never touched.
    if ($('plug-token').value) await put('token', $('plug-token').value);
    if ($('plug-debrid-key').value) await put('debrid_key', $('plug-debrid-key').value);
    $('plug-token').value = ''; $('plug-debrid-key').value = '';
    $('plug-hint').textContent = 'Integrations saved ✓';
    loadPlugins();
  } catch (error) { $('plug-hint').textContent = error.message || 'Could not save integrations.'; }
};

// ── Trakt (Setup › Plugins › Trakt) ──
// Device auth: the browser never sees the access token. It shows the short code
// trakt.tv/activate asks for and re-polls until the desktop side has the token.
let traktPoll = null;
async function loadTrakt() {
  let d;
  try { d = await api('/trakt'); } catch (e) { $('trakt-hint').textContent = 'Unavailable'; return; }
  $('trakt-id').placeholder = d.has_client_id ? 'set — type to replace' : 'not set';
  $('trakt-secret').placeholder = d.has_client_secret ? 'set — type to replace' : 'not set';
  if (d.connected) {
    const queued = Number(d.queued || 0);
    $('trakt-hint').textContent = (d.scrobbling ? 'Connected — scrobbling' : 'Connected')
      + (queued ? ` · ${queued} queued` : ' · synced');
  } else if (d.pending) {
    $('trakt-hint').textContent = d.user_code
      ? 'Go to trakt.tv/activate and enter ' + d.user_code
      : 'Requesting a code…';
  } else if (d.needs_reauth) {
    $('trakt-hint').textContent = `Authorization revoked — reconnect to send ${Number(d.queued || 0)} queued`;
  } else {
    $('trakt-hint').textContent = 'Not connected.';
  }
  $('trakt-retry').hidden = !d.queued;
  // Only poll while a device auth is in flight, and stop the moment it lands —
  // otherwise the page keeps a timer alive for the whole session.
  if (d.pending && !traktPoll) traktPoll = setInterval(loadTrakt, 3000);
  if (!d.pending && traktPoll) { clearInterval(traktPoll); traktPoll = null; }
}
async function saveTraktDrafts() {
  const put = async (k, v) => {
    const response = await fetch(BASE + '/api/trakt', {
    method: 'POST',
    credentials: 'same-origin',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: 'key=' + encodeURIComponent(k) + '&value=' + encodeURIComponent(v),
    });
    const data = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(data.error || 'Could not save Trakt settings');
  };
  if ($('trakt-id').value) await put('client_id', $('trakt-id').value.trim());
  if ($('trakt-secret').value) await put('client_secret', $('trakt-secret').value);
  $('trakt-id').value = ''; $('trakt-secret').value = '';
}
$('trakt-save').onclick = async () => {
  // Empty means "leave alone", same rule as the integrations block above.
  try {
    await saveTraktDrafts();
    $('trakt-hint').textContent = 'Saved ✓';
    loadTrakt();
  } catch (error) { $('trakt-hint').textContent = error.message; }
};
$('plug-debrid-clear').onclick = async () => {
  if (!confirm('Disconnect debrid and remove its saved API key?')) return;
  try {
    await apiFormMutation('/plugins', {action:'clear-debrid'});
    $('plug-debrid-key').value = '';
    toast('Debrid disconnected');
    await loadPlugins();
  } catch (error) { toast(error.message || 'Could not disconnect debrid'); }
};
$('trakt-connect').onclick = async () => {
  try {
    await saveTraktDrafts();
    const response = await fetch(BASE + '/api/trakt?action=connect',
      { method:'POST', credentials:'same-origin' });
    const data = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(data.error || 'Could not start Trakt authorization');
    loadTrakt();
  } catch (error) { $('trakt-hint').textContent = error.message; }
};
$('trakt-disconnect').onclick = async () => {
  await fetch(BASE + '/api/trakt?action=disconnect',
    { method:'POST', credentials:'same-origin' });
  loadTrakt();
};
$('trakt-retry').onclick = async () => {
  await fetch(BASE + '/api/trakt?action=retry',
    { method:'POST', credentials:'same-origin' });
  loadTrakt();
};

// AniList uses its official desktop/PIN OAuth flow. Credential bytes are only
// ever POSTed; GET returns booleans, queue state and the public authorize URL.
async function syncAccountMutation(params) {
  const response = await fetch(BASE + '/api/sync-accounts', {
    method:'POST', credentials:'same-origin',
    headers:{'Content-Type':'application/x-www-form-urlencoded'},
    body:new URLSearchParams(params),
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(data.error || 'Could not update sync account');
}
async function loadSyncAccounts() {
  let data;
  try { data = await api('/sync-accounts'); }
  catch (_) { $('anilist-hint').textContent = 'Unavailable'; return; }
  const account = data.anilist || {};
  $('anilist-id').placeholder = account.has_client_id ? 'set — type to replace' : 'required';
  $('anilist-token').placeholder = account.connected ? 'set — type to replace' : 'paste token after authorization';
  $('anilist-hint').textContent = account.connected
    ? `Connected${account.queued ? ` · ${account.queued} queued` : ' · synced'}`
    : account.needs_reauth ? `Authorization revoked · reconnect to send ${account.queued || 0} queued`
    : 'Not connected. Save your client ID, authorize, then paste the token.';
  $('anilist-authorize').hidden = !account.authorize_url;
  $('anilist-authorize').href = account.authorize_url || '#';
  $('anilist-retry').hidden = !account.queued || !!account.needs_reauth;
  const simkl = data.simkl || {};
  $('simkl-id').placeholder = simkl.has_client_id ? 'set — type to replace' : 'required';
  $('simkl-hint').textContent = simkl.connected
    ? `Connected${simkl.queued ? ` · ${simkl.queued} queued` : ' · synced'}`
    : simkl.needs_reauth ? `Authorization revoked · reconnect to send ${simkl.queued || 0} queued`
    : simkl.pending ? (simkl.user_code ? `Enter ${simkl.user_code} at simkl.com/pin` : 'Requesting a PIN…')
    : 'Not connected.';
  $('simkl-pin').hidden = !simkl.user_code;
  $('simkl-retry').hidden = !simkl.queued;
  if (simkl.pending) scheduleSyncAccountPoll();
}
let syncAccountPoll = 0;
function scheduleSyncAccountPoll() {
  clearTimeout(syncAccountPoll);
  syncAccountPoll = setTimeout(loadSyncAccounts, 5000);
}
$('anilist-save').onclick = async () => {
  try {
    if ($('anilist-id').value) await syncAccountMutation({provider:'anilist',action:'set',key:'client_id',value:$('anilist-id').value.trim()});
    if ($('anilist-token').value) await syncAccountMutation({provider:'anilist',action:'set',key:'access_token',value:$('anilist-token').value.trim()});
    $('anilist-id').value = ''; $('anilist-token').value = '';
    await loadSyncAccounts();
  } catch (error) { $('anilist-hint').textContent = error.message; }
};
$('anilist-disconnect').onclick = async () => {
  await syncAccountMutation({provider:'anilist',action:'disconnect'});
  loadSyncAccounts();
};
$('anilist-retry').onclick = async () => {
  await syncAccountMutation({provider:'anilist',action:'retry'});
  loadSyncAccounts();
};
$('simkl-save').onclick = async () => {
  try {
    if ($('simkl-id').value) await syncAccountMutation({provider:'simkl',action:'set',key:'client_id',value:$('simkl-id').value.trim()});
    $('simkl-id').value = '';
    await loadSyncAccounts();
  } catch (error) { $('simkl-hint').textContent = error.message; }
};
$('simkl-connect').onclick = async () => {
  try {
    await syncAccountMutation({provider:'simkl',action:'connect'});
    await loadSyncAccounts();
  } catch (error) { $('simkl-hint').textContent = error.message; }
};
$('simkl-disconnect').onclick = async () => {
  await syncAccountMutation({provider:'simkl',action:'disconnect'});
  loadSyncAccounts();
};
$('simkl-retry').onclick = async () => {
  await syncAccountMutation({provider:'simkl',action:'retry'});
  loadSyncAccounts();
};

// ── Suwayomi (Setup › Plugins › Suwayomi) ──
async function loadSuwayomi() {
  let d;
  try { d = await api('/suwayomi'); } catch (e) { $('suwa-hint').textContent = 'Unavailable'; return; }
  $('suwa-hint').textContent = d.status || (d.running ? 'Running' : 'Stopped');
  if (document.activeElement !== $('suwa-base')) $('suwa-base').value = d.base || '';
}
$('suwa-start').onclick = async () => {
  await fetch(BASE + '/api/suwayomi?action=start',
    { method:'POST', credentials:'same-origin' });
  // The server takes a few seconds to come up; re-read rather than guess.
  setTimeout(loadSuwayomi, 1500);
};
$('suwa-stop').onclick = async () => {
  await fetch(BASE + '/api/suwayomi?action=stop',
    { method:'POST', credentials:'same-origin' });
  setTimeout(loadSuwayomi, 500);
};

// ── Setup page folding ──
let setupFolded = false;
function foldSetup(){
  if (setupFolded) return;
  const page = document.getElementById('page-setup');
  if (!page) return;
  setupFolded = true;
  const kids = [...page.children];
  let body = null, first = true, sectionIndex = 0;
  for (const el of kids) {
    if (el.classList.contains('sect')) {
      const head = el;
      const myBody = document.createElement('div');
      myBody.className = 'fold-body';
      myBody.id = `setup-section-${sectionIndex++}`;
      head.classList.add('fold');
      head.after(myBody);
      if (!first) { head.classList.add('shut'); myBody.classList.add('shut'); }
      head.setAttribute('aria-controls', myBody.id);
      head.setAttribute('aria-expanded', first ? 'true' : 'false');
      first = false;
      const toggle = () => {
        head.classList.toggle('shut');
        myBody.classList.toggle('shut');
        head.setAttribute('aria-expanded', head.classList.contains('shut') ? 'false' : 'true');
      };
      head.onclick = toggle;
      wireKeyboardClick(head);
      body = myBody;
      continue;
    }
    if (body) body.append(el);
  }
}

// ── Live TV sources (Setup › Live TV) ──
async function loadLiveTvSources() {
  let d;
  try { d = await api('/livetv/sources'); } catch (e) { $('ltv-hint').textContent = 'Unavailable'; return; }
  $('ltv-hint').textContent = d.ingesting
    ? 'Refreshing channels…'
    : d.total + ' channels in your catalog';
  const custom = d.custom || [];
  $('ltv-custom-list').innerHTML = custom.map(item => `<div class="cfg-row"><span>${esc(item.name)} · ${item.channels || 0} channels${item.adult ? ' · 18+' : ''}</span><span><button type="button" data-ltv-edit="${esc(item.id)}">Edit</button><button type="button" data-ltv-remove="${esc(item.id)}">Remove</button></span></div>`).join('');
  $('ltv-custom-list')._items = custom;
  const list = $('ltv-list');
  list.textContent = '';
  for (const s of d.sources || []) {
    const row = document.createElement('div');
    row.className = 'cfg-row';
    const label = document.createElement('span');
    // textContent, not innerHTML: name/region/note are compiled in, but this
    // list is the kind of thing that grows a user-supplied entry later.
    label.textContent = s.name + ' — ' + s.region
      + (s.channels ? ' (' + s.channels + ')' : '') + (s.note ? ' · ' + s.note : '');
    const btn = document.createElement('button');
    btn.textContent = s.installed ? 'On' : 'Off';
    btn.onclick = async () => {
      btn.disabled = true;
      await api('/livetv/sources?id=' + encodeURIComponent(s.id)
                + '&action=' + (s.installed ? 'remove' : 'install'));
      loadLiveTvSources();
    };
    row.append(label, btn);
    list.append(row);
  }
}
$('ltv-custom-save').onclick = async () => {
  const items = $('ltv-custom-list')._items || [];
  const editing = $('ltv-custom-save').dataset.id || '';
  const used = new Set(items.map(item => item.id));
  let id = editing;
  if (!id) for (let slot = 0; slot < 8; slot++) if (!used.has('iptv-custom-' + slot)) { id = 'iptv-custom-' + slot; break; }
  if (!id) return toast('Remove a custom playlist before adding another');
  try {
    await apiFormMutation('/livetv/sources', {id, action:'save', name:$('ltv-custom-name').value.trim(),
      url:$('ltv-custom').value.trim(), adult:$('ltv-custom-adult').checked ? '1' : '0'});
    $('ltv-custom-name').value = ''; $('ltv-custom').value = ''; $('ltv-custom-adult').checked = false;
    $('ltv-custom-save').dataset.id = ''; $('ltv-custom-save').textContent = 'Add playlist';
    $('ltv-hint').textContent = 'Saved ✓'; await loadLiveTvSources();
  } catch (error) { toast(error.message || 'Could not save playlist'); }
};
$('ltv-custom-list').addEventListener('click', async event => {
  const edit = event.target.closest('[data-ltv-edit]');
  const remove = event.target.closest('[data-ltv-remove]');
  if (edit) {
    const item = ($('ltv-custom-list')._items || []).find(row => row.id === edit.dataset.ltvEdit); if (!item) return;
    $('ltv-custom-name').value = item.name; $('ltv-custom').value = item.url; $('ltv-custom-adult').checked = !!item.adult;
    $('ltv-custom-save').dataset.id = item.id; $('ltv-custom-save').textContent = 'Save changes';
  }
  if (remove && confirm('Remove this playlist? Its channels will leave the catalog.')) {
    try { await apiFormMutation('/livetv/sources', {id:remove.dataset.ltvRemove, action:'remove'}); await loadLiveTvSources(); }
    catch (error) { toast(error.message || 'Could not remove playlist'); }
  }
});
$('ltv-refresh').onclick = async () => {
  await api('/livetv/sources?action=refresh');
  $('ltv-hint').textContent = 'Refreshing…';
  setTimeout(loadLiveTvSources, 2000);
};

// ── Web UI (Setup › Web UI) ──
async function loadWebUi() {
  let d;
  try { d = await api('/webui'); } catch (e) { $('webui-hint').textContent = 'Unavailable'; return; }
  $('webui-hint').textContent = 'Serving on ' + (d.address || '?') + ':' + d.port
    + (d.running ? '' : ' (stopped)');
}
$('webui-off').onclick = async () => {
  // This ends the session making the request, so make that explicit rather than
  // letting the page appear to hang when the connection drops.
  if (!confirm('Turn off remote access? This device will lose its connection, '
             + 'and it can only be switched back on from the desktop app.')) return;
  await api('/webui?action=disable&confirm=1');
  $('webui-hint').textContent = 'Remote access off — re-enable from the desktop app.';
};

// ── About (Setup › About) ──
// Read-only by design: installing a new build from a remote session would be
// installing software on someone else's machine, so the button only re-checks.
async function loadAbout() {
  let d;
  try { d = await api('/about'); } catch (e) { $('about-hint').textContent = 'Unavailable'; return; }
  let t = 'Opal v' + (d.version || '?');
  if (d.checking) t += ' — checking…';
  else if (d.has_update && d.latest) t += ' — v' + d.latest + ' available (update from the desktop app)';
  else if (d.latest) t += ' — up to date';
  if (d.error) t += ' — ' + d.error;
  $('about-hint').textContent = t;
}
$('about-check').onclick = async () => {
  await api('/about?action=check');
  $('about-hint').textContent = 'Checking…';
  setTimeout(loadAbout, 2000);
};

// ── Watch Party (Setup › Watch Party) ──
let partyWatch = null;
function renderParty(d){
  const connected = !!d.connected;
  const peers = Number(d.peers || 0);
  const role = d.role && d.role !== 'none' ? d.role : 'not connected';
  $('party-hint').textContent = connected
    ? `${role} · ${peers} peer${peers === 1 ? '' : 's'}${d.host_ip ? ' · ' + d.host_ip : ''}${d.status ? ' · ' + d.status : ''}`
    : (d.status || 'Not in a watch party.');
  $('party-leave').disabled = !connected;
  $('party-chat').disabled = !connected;
  $('party-chat-form').querySelector('button').disabled = !connected;
  const html = (d.chat || []).map(m => `<div class="party-msg">${esc(String(m))}</div>`).join('')
    || '<div class="empty">No party messages yet.</div>';
  if (html !== lastHtml.partyChat) {
    lastHtml.partyChat = html;
    $('party-log').innerHTML = html;
    $('party-log').scrollTop = $('party-log').scrollHeight;
  }
}
async function loadParty(){
  clearTimeout(partyWatch);
  try { renderParty(await api('/party/status')); }
  catch { $('party-hint').textContent = 'Could not load party status.'; }
  if ($('page-setup').classList.contains('on')) partyWatch = setTimeout(loadParty, 2500);
}
const partyPost = async (path) => {
  const r = await fetch(BASE + '/api' + path,
    { method:'POST', credentials:'same-origin' });
  const d = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(d.error || 'Watch party action failed');
  return d;
};
const partyDo = async (action, extra) => {
  $('party-hint').textContent = action === 'join' ? 'Joining…' : action === 'host' ? 'Starting party…' : 'Leaving…';
  try {
    await partyPost('/party/' + action + (extra || ''));
    await loadParty();
  } catch (e) { $('party-hint').textContent = e.message || 'Watch party action failed.'; }
};
$('party-host').onclick = () => partyDo('host');
$('party-leave').onclick = () => partyDo('leave');
$('party-join').onclick = () => {
  const ip = $('party-ip').value.trim();
  if (!ip) return void ($('party-hint').textContent = 'Enter the host IP.');
  partyDo('join', '?ip=' + encodeURIComponent(ip));
};
$('party-chat-form').addEventListener('submit', async e => {
  e.preventDefault();
  const msg = $('party-chat').value.trim(); if (!msg) return;
  $('party-chat').value = '';
  try { await partyPost('/party/chat?msg=' + encodeURIComponent(msg)); await loadParty(); }
  catch (err) { $('party-hint').textContent = err.message || 'Could not send message.'; }
});

// ── Watching library ──
// Desktop parity for the `.watching` route. /api/library returns rows already
// in the desktop's display order (tv_pure.sortOrder), so the two surfaces agree
// on ordering without the page re-sorting anything.
const watchSaved = (key, allowed, fallback) => {
  try { const value = localStorage.getItem(key); return allowed.includes(value) ? value : fallback; }
  catch { return fallback; }
};
$('suwa-save').onclick = async () => {
  try { await apiFormMutation('/suwayomi', {action:'save', base:$('suwa-base').value.trim()}); toast('Suwayomi server saved'); await loadSuwayomi(); }
  catch (error) { toast(error.message || 'Could not save Suwayomi server'); }
};
$('suwa-disconnect').onclick = async () => {
  if (!confirm('Disconnect Suwayomi? Your manga library remains on its server.')) return;
  try { await apiFormMutation('/suwayomi', {action:'disconnect'}); $('suwa-base').value = ''; toast('Suwayomi disconnected'); await loadSuwayomi(); }
  catch (error) { toast(error.message || 'Could not disconnect Suwayomi'); }
};
const watchFilters = ['all','watching','caught_up','unstarted','completed','dropped'];
const watchKinds = ['all','tv','anime','movie'];
const watchSorts = ['smart','recent','title','progress'];
const watchPageSizes = ['24','48','96'];
let watchRows = null;
let watchTotal = 0, watchCatalogTotal = 0;
let watchFilter = watchSaved('opal.watch.filter', watchFilters, 'all');
let watchKind = watchSaved('opal.watch.kind', watchKinds, 'all');
let watchSort = watchSaved('opal.watch.sort', watchSorts, 'smart');
let watchCompact = watchSaved('opal.watch.density', ['comfortable','compact'], 'comfortable') === 'compact';
let watchPageSize = Number(watchSaved('opal.watch.pageSize', watchPageSizes, '48'));
let watchPage = (() => { try { return Math.min(9, Math.max(1, Number.parseInt(localStorage.getItem('opal.watch.page') || '1', 10) || 1)); } catch { return 1; } })();
let watchSyncing = false;
let watchSyncTimer = null, watchSyncPolls = 0;
async function loadWatch(){
  loadLocalLibrary();
  clearTimeout(watchSyncTimer);
  $('watch-hint').innerHTML = '<span class="spin"></span> Loading…';
  try {
    const query = new URLSearchParams({filter:watchFilter, kind:watchKind, sort:watchSort,
      offset:String((watchPage - 1) * watchPageSize), limit:String(watchPageSize)});
    const d = await api('/library?' + query);
    watchRows = Array.isArray(d.items) ? d.items : [];
    watchTotal = Number.isSafeInteger(d.total) ? d.total : watchRows.length;
    watchCatalogTotal = Number.isSafeInteger(d.catalog_total) ? d.catalog_total : watchTotal;
    const pages = Math.max(1, Math.ceil(watchTotal / watchPageSize));
    if (!watchRows.length && watchTotal > 0 && watchPage > pages) { setWatchPage(pages); return loadWatch(); }
    watchSyncing = !!d.syncing;
    renderWatch();
    if (d.syncing && watchSyncPolls++ < 40 && $('page-watch').classList.contains('on'))
      watchSyncTimer = setTimeout(loadWatch, 1500);
    else if (!d.syncing) watchSyncPolls = 0;
  } catch { $('watch-hint').textContent = 'Could not load the library.'; }
}
function chooseWatchFilter(group, button){
  group.querySelectorAll('button').forEach(x => x.classList.toggle('on', x === button));
}

let localLibraryTimer = 0;
async function loadLocalLibrary(){
  clearTimeout(localLibraryTimer);
  const query = $('local-query').value.trim();
  const duplicates = $('local-duplicates').checked;
  try {
    const data = await api('/local-library?q=' + encodeURIComponent(query) + (duplicates ? '&duplicates=1' : ''));
    const items = data.items || [];
    const roots = data.roots || [];
    $('local-roots').innerHTML = roots.map(root => `<span>${esc(root.name)} <button type="button" data-root-remove="${root.id}" aria-label="Remove ${esc(root.name)}">Ã—</button></span>`).join('');
    $('local-hint').textContent = data.scanning ? 'Refreshing the index in the backgroundâ€¦' :
      `${items.length} indexed file${items.length === 1 ? '' : 's'} shown${duplicates ? ' with likely duplicates' : ''}.`;
    $('local-results').innerHTML = items.map((item, index) => `<div class="file local-media-row" data-i="${index}">
      <div class="n"><input class="local-title" value="${esc(item.title)}" maxlength="255" aria-label="Corrected title">
        <div class="file-meta"><span>${fmtSize(item.size)}</span>${item.copies > 1 ? `<span>${item.copies} likely duplicates</span>` : ''}</div></div>
      <select class="local-kind" aria-label="Media type">
        ${[['','Automatic'],['movie','Movie'],['tv','TV episode'],['music','Music'],['audiobook','Audiobook'],['other','Other']]
          .map(([value,label]) => `<option value="${value}"${item.kind === value ? ' selected' : ''}>${label}</option>`).join('')}
      </select><button type="button" data-local-save>Save metadata</button></div>`).join('') ||
      '<div class="empty">No indexed files match. Scan after changing the download folder.</div>';
    $('local-results')._items = items;
    if (data.scanning && $('page-watch').classList.contains('on')) localLibraryTimer = setTimeout(loadLocalLibrary, 800);
  } catch { $('local-hint').textContent = 'Local library index unavailable.'; }
}
$('local-query').addEventListener('input', () => {
  clearTimeout(localLibraryTimer); localLibraryTimer = setTimeout(loadLocalLibrary, 180);
});
$('local-duplicates').addEventListener('change', loadLocalLibrary);
$('local-scan').onclick = async () => {
  $('local-scan').disabled = true;
  try { await apiMutation('/local-library/action?action=scan'); await loadLocalLibrary(); }
  catch (error) { toast(error.message || 'Could not start library scan'); }
  finally { $('local-scan').disabled = false; }
};
$('local-root-add').onclick = async () => {
  const input = $('local-root'); const path = input.value.trim();
  if (!path) { input.focus(); return; }
  try {
    await apiFormMutation('/local-library/action', {action:'add-root', path});
    input.value = ''; toast('Library folder added'); await loadLocalLibrary();
  } catch (error) { toast(error.message || 'Could not import folder'); }
};
$('local-roots').addEventListener('click', async event => {
  const button = event.target.closest('[data-root-remove]'); if (!button) return;
  if (!confirm('Remove this folder from Opal’s index? Files stay on disk.')) return;
  try { await apiFormMutation('/local-library/action', {action:'remove-root', id:button.dataset.rootRemove}); await loadLocalLibrary(); }
  catch (error) { toast(error.message || 'Could not remove folder'); }
});
$('local-results').addEventListener('click', async event => {
  const button = event.target.closest('[data-local-save]'); if (!button) return;
  const row = button.closest('.local-media-row');
  const item = $('local-results')._items?.[+row.dataset.i]; if (!item) return;
  button.disabled = true;
  try {
    await apiFormMutation('/local-library/action', {action:'correct', id:item.id,
      title:row.querySelector('.local-title').value.trim(), kind:row.querySelector('.local-kind').value});
    toast('Metadata saved'); await loadLocalLibrary();
  } catch (error) { toast(error.message || 'Could not save metadata'); button.disabled = false; }
});
function saveWatchChoice(key, value){ try { localStorage.setItem(key, value); } catch {} }
function restoreWatchControls(){
  const filter = $('watch-filters').querySelector(`[data-f="${watchFilter}"]`);
  const kind = $('watch-kind-filters').querySelector(`[data-f="${watchKind}"]`);
  if (filter) chooseWatchFilter($('watch-filters'), filter);
  if (kind) chooseWatchFilter($('watch-kind-filters'), kind);
  $('watch-sort').value = watchSort;
  $('watch-page-size').value = String(watchPageSize);
  $('watch-density').setAttribute('aria-pressed', String(watchCompact));
  $('watch-density').classList.toggle('on', watchCompact);
  $('watch-list').classList.toggle('compact', watchCompact);
}
restoreWatchControls();
$('watch-filters').addEventListener('click', e => {
  const b = e.target.closest('button[data-f]'); if (!b) return;
  chooseWatchFilter($('watch-filters'), b); watchFilter = b.dataset.f; saveWatchChoice('opal.watch.filter', watchFilter); setWatchPage(1); renderWatch();
});
$('watch-kind-filters').addEventListener('click', e => {
  const b = e.target.closest('button[data-f]'); if (!b) return;
  chooseWatchFilter($('watch-kind-filters'), b); watchKind = b.dataset.f; saveWatchChoice('opal.watch.kind', watchKind); setWatchPage(1); renderWatch();
});
$('watch-sort').addEventListener('change', e => {
  watchSort = watchSorts.includes(e.target.value) ? e.target.value : 'smart';
  saveWatchChoice('opal.watch.sort', watchSort); setWatchPage(1); renderWatch();
});
$('watch-page-size').addEventListener('change', e => {
  watchPageSize = Number(watchPageSizes.includes(e.target.value) ? e.target.value : '48');
  saveWatchChoice('opal.watch.pageSize', String(watchPageSize)); setWatchPage(1); renderWatch();
});
function setWatchPage(page){
  watchPage = Math.min(9, Math.max(1, page)); saveWatchChoice('opal.watch.page', String(watchPage));
}
$('watch-prev').addEventListener('click', () => { setWatchPage(watchPage - 1); renderWatch(); $('watch-list').scrollIntoView({block:'start'}); });
$('watch-next-page').addEventListener('click', () => { setWatchPage(watchPage + 1); renderWatch(); $('watch-list').scrollIntoView({block:'start'}); });
$('watch-density').addEventListener('click', () => {
  watchCompact = !watchCompact; saveWatchChoice('opal.watch.density', watchCompact ? 'compact' : 'comfortable');
  restoreWatchControls(); renderWatch();
});
$('watch-refresh').onclick = async () => {
  $('watch-hint').textContent = 'Starting metadata refresh…';
  try { await apiMutation('/library/action?action=refresh'); watchSyncPolls = 0; await loadWatch(); }
  catch (e) { $('watch-hint').textContent = e.message || 'Could not refresh metadata.'; }
};
function watchStatusOptions(current){
  return [['none','Automatic'],['plan','Plan'],['watching','Watching'],['completed','Completed'],['dropped','Dropped']]
    .map(([value, label]) => `<option value="${value}" ${current === value ? 'selected' : ''}>${label}</option>`).join('');
}
function renderWatch(){
  const pageRows = watchRows || [];
  const pageCount = Math.max(1, Math.ceil(watchTotal / watchPageSize));
  if (watchPage > pageCount) setWatchPage(pageCount);
  $('watch-hint').textContent = watchCatalogTotal
    ? `${watchTotal} of ${watchCatalogTotal} tracked${watchSyncing ? ' · syncing metadata…' : ''}`
    : 'Nothing tracked yet — play something, or add a show from Browse.';
  $('watch-list').innerHTML = pageRows.map((r, i) => {
    const pct = r.total > 0 ? Math.round(100 * r.watched / r.total) : (r.pct || 0);
    const ep = r.has_next ? `S${String(r.next_season).padStart(2,'0')}E${String(r.next_episode).padStart(2,'0')}` : '';
    const next = r.has_next
      ? `${ep} next`
      : esc(r.status || '');
    return `<div class="result watch-row" data-i="${i}">
      ${r.poster ? `<img class="poster" src="${esc(r.poster)}" loading="lazy" alt="">` : ''}
      <div class="t">${esc(r.name)}</div>
      <div class="m"><span class="src">${esc(r.kind)}</span>
        <span>${esc(next)}</span>
        ${r.total > 0 ? `<span>${r.watched}/${r.total} · ${pct}%</span>` : ''}</div>
      <div class="wbar"><div style="width:${Math.min(100, pct)}%"></div></div>
      <div class="watch-actions">
        <select data-action="status" aria-label="Status for ${esc(r.name)}">${watchStatusOptions(r.user_status || 'none')}</select>
        ${r.has_next && r.kind !== 'movie' ? `<button data-action="watched" title="Advance to the following episode">Mark ${ep} watched</button>` : ''}
        ${r.has_next && r.kind === 'tv' ? `<button class="watch-next" data-action="find-next">Find ${ep}</button>` : ''}
        <button data-action="open">${r.kind === 'tv' ? 'Details' : 'Find'}</button>
        <button class="watch-remove" data-action="remove">Remove</button>
      </div>
    </div>`;
  }).join('') || '<div class="empty">Nothing here</div>';
  $('watch-list')._rows = pageRows;
  const pager = $('watch-pager');
  pager.hidden = watchTotal <= watchPageSize;
  $('watch-page-label').textContent = `Page ${watchPage} of ${pageCount}`;
  $('watch-prev').disabled = watchPage <= 1;
  $('watch-next-page').disabled = watchPage >= pageCount;
}
async function changeLibrary(params){
  $('watch-hint').textContent = 'Updating library…';
  try { await apiMutation('/library/action?' + params); await loadWatch(); }
  catch (e) { $('watch-hint').textContent = e.message || 'Library update failed.'; }
}
$('watch-list').addEventListener('change', e => {
  const select = e.target.closest('select[data-action="status"]'); if (!select) return;
  const row = select.closest('.watch-row'); const r = $('watch-list')._rows?.[+row.dataset.i];
  if (!r) return;
  changeLibrary('action=status&kind=' + r.kind + '&id=' + encodeURIComponent(r.id) + '&value=' + select.value);
});
$('watch-list').addEventListener('click', e => {
  const button = e.target.closest('button[data-action]'); if (!button) return;
  const row = button.closest('.watch-row'); const r = $('watch-list')._rows?.[+row.dataset.i];
  if (!r) return;
  if (button.dataset.action === 'open') {
    if (r.kind === 'tv' && r.tmdb_id) openShow(r.tmdb_id, r.name);
    else prefillSearch(normQuery(r.name));
  } else if (button.dataset.action === 'find-next') {
    prefillSearch(normQuery(r.name) + ' s' + String(r.next_season).padStart(2,'0') + 'e' + String(r.next_episode).padStart(2,'0'));
  } else if (button.dataset.action === 'watched') {
    changeLibrary('action=watched&kind=' + r.kind + '&id=' + encodeURIComponent(r.id)
      + '&season=' + r.next_season + '&episode=' + r.next_episode + '&value=true');
  } else if (button.dataset.action === 'remove') {
    const note = r.kind === 'movie' ? 'This removes its local and connected-account history.' : 'Watch history is kept.';
    if (!confirm(`Remove ${r.name} from Watching? ${note}`)) return;
    changeLibrary('action=remove&kind=' + r.kind + '&id=' + encodeURIComponent(r.id) + '&confirm=1');
  }
});

// ── Settings (Setup › Settings) ──
// Rendered from /api/settings, which returns the server's key REGISTRY with
// live values. The page builds controls from `kind`/`group` rather than
// hard-coding fields, so a setting added in settings_api_pure.zig shows up here
// with no web change — and can never be settable-but-invisible.
async function loadSettings(){
  try {
    const d = await api('/settings');
    const keys = Array.isArray(d.settings) ? d.settings : [];
    $('cfg-hint').textContent = keys.length + ' settings';
    const groups = {};
    keys.forEach(k => (groups[k.group] = groups[k.group] || []).push(k));
    $('cfg-list').innerHTML = Object.entries(groups).map(([g, ks]) => `
      <div class="acc-group">
        <div class="acc-title">${esc(g)}</div>
        ${ks.map(k => k.kind === 'boolean'
          ? `<label class="cfg-row"><input type="checkbox" data-k="${esc(k.name)}" data-kind="boolean"
               ${k.value ? 'checked' : ''}><span>${esc(k.label)}</span></label>`
          : `<label class="cfg-row"><span>${esc(k.label)}</span>
               <input data-k="${esc(k.name)}" data-kind="${esc(k.kind)}"
                 ${k.kind === 'integer' ? 'inputmode="numeric"' : ''}
                 value="${esc(String(k.value ?? ''))}"></label>`).join('')}
      </div>`).join('');
    wireSettings();
  } catch { $('cfg-hint').textContent = 'Could not load settings.'; }
}
function wireSettings(){
  const save = async (el) => {
    const key = el.dataset.k;
    const val = el.dataset.kind === 'boolean' ? (el.checked ? '1' : '0') : el.value.trim();
    const r = await fetch(BASE + '/api/settings?key=' + encodeURIComponent(key) +
      '&value=' + encodeURIComponent(val),
      { method:'POST', credentials:'same-origin' });
    const d = await r.json().catch(() => ({}));
    // The server validates and REJECTS rather than clamping, so re-read to put
    // the stored value back on screen — then report. Reporting first would let
    // loadSettings() overwrite the refusal with its idle text, leaving the user
    // with a reverted field and no explanation.
    if (!r.ok) await loadSettings();
    $('cfg-hint').textContent = r.ok ? 'Saved ✓' : (d.error || 'Could not save ' + key);
  };
  $('cfg-list').querySelectorAll('input[type=checkbox]').forEach(el => el.onchange = () => save(el));
  $('cfg-list').querySelectorAll('input:not([type=checkbox])').forEach(el => {
    el.onchange = () => save(el);
    el.addEventListener('keydown', e => { if (e.key === 'Enter') save(el); });
  });
}

// ── Access (Setup › Access) ──
// Backed by /api/access/*. Two caller classes, and the page adapts: a normal
// web login changes its OWN password (proving the current one), while a caller
// holding the machine-local api.token may RESET any named account — the only
// recovery path when the web password is forgotten.
const apiPost = (path, body) => fetch(BASE + '/api/access' + path, {
  method: 'POST',
  credentials: 'same-origin',
  headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
  body: body || '',
}).then(async r => { const d = await r.json().catch(() => ({})); return { ok: r.ok, d }; });

let accViaToken = false;
let accCanManageUsers = false;
async function loadAccess(){
  try {
    const d = await api('/access/status');
    accViaToken = !!d.via_token;
    accCanManageUsers = !!d.can_manage_users;
    $('acc-hint').textContent = accViaToken
      ? 'Authenticated with the machine api.token — you can reset any account.'
      : ('Signed in as ' + (d.username || '—') + '.');
    // Token callers have no "current password" to prove; they name a target.
    $('acc-pw-user').style.display = accViaToken ? '' : 'none';
    $('acc-pw-cur').style.display = accViaToken ? 'none' : '';
    $('acc-pw-hint').textContent = accViaToken
      ? 'Reset a forgotten password. Signs out every device.'
      : 'Changing it signs out every other device.';
    $('acc-sess-hint').textContent = d.sessions === 1
      ? '1 signed-in device.' : (d.sessions || 0) + ' signed-in devices.';
    $('acc-users-group').hidden = !accCanManageUsers;
    $('acc-machine-token').hidden = !d.can_manage_machine;
    $('acc-machine-network').hidden = !d.can_manage_machine;
    if (accCanManageUsers) await loadAccessUsers();
    $('acc-token').value = d.token_masked || '••••••••';
    $('acc-token-show').textContent = 'Show';
    $('acc-bind').value = d.bind || 'lan';
    $('acc-port').value = d.port || 41595;
    renderBindWarn(d.bind, d.lan_ip, d.port);
  } catch { $('acc-hint').textContent = 'Could not load access settings.'; }
}

async function loadAccessUsers(){
  const d = await api('/access/users');
  const users = d.users || [];
  $('acc-users').innerHTML = users.map(user => `<div class="acc-user">
    <span><strong>${esc(user.username)}</strong>${user.is_admin ? ' · Administrator' : ''}<small>${user.sessions || 0} signed-in device${user.sessions === 1 ? '' : 's'}</small></span>
    <button class="danger" data-user-delete="${user.id}"${user.is_self ? ' disabled title="Current account"' : ''}>Remove</button>
  </div>`).join('') || '<div class="hint">No accounts.</div>';
  $('acc-users').querySelectorAll('[data-user-delete]').forEach(button => button.onclick = async () => {
    const name = button.closest('.acc-user').querySelector('strong').textContent;
    if (!confirm('Remove account “' + name + '” and sign it out everywhere?')) return;
    button.disabled = true;
    const { ok, d: result } = await apiPost('/users/delete', 'id=' + encodeURIComponent(button.dataset.userDelete));
    $('acc-users-hint').textContent = ok ? 'Account removed.' : (result.error || 'Could not remove account.');
    await loadAccessUsers();
  });
}

$('acc-user-form').onsubmit = async event => {
  event.preventDefault();
  const username = $('acc-user-name').value.trim();
  const password = $('acc-user-password').value;
  if (username.length < 3 || password.length < 8) {
    $('acc-users-hint').textContent = 'Use a 3–32 character username and a password of at least 8 characters.';
    return;
  }
  const button = $('acc-user-add');
  button.disabled = true; button.textContent = 'Adding…';
  const body = 'username=' + encodeURIComponent(username) + '&password=' + encodeURIComponent(password)
    + '&admin=' + ($('acc-user-admin').checked ? '1' : '0');
  const { ok, d } = await apiPost('/users/create', body);
  button.disabled = false; button.textContent = 'Add account';
  $('acc-users-hint').textContent = ok ? 'Account added.' : (d.error || 'Could not add account.');
  if (ok) {
    $('acc-user-name').value = $('acc-user-password').value = '';
    $('acc-user-admin').checked = false;
    await loadAccessUsers();
  }
};
function renderBindWarn(bind, ip, port){
  const w = $('acc-bind-warn');
  if (bind === 'loopback') { w.className = 'hint'; w.textContent = 'Only this machine can reach the server.'; }
  else { w.className = 'hint acc-warn'; w.textContent = 'Anyone on your network who can sign in can reach Opal' + (ip ? ' at http://' + ip + ':' + port : '') + '.'; }
}

$('acc-pw-save').onclick = async () => {
  const btn = $('acc-pw-save');
  const nw = $('acc-pw-new').value, cf = $('acc-pw-conf').value;
  // Mirror of access_pure.checkPasswordChange so the common mistakes are
  // caught without a round trip; the server re-checks regardless.
  if (nw.length < 8) return void ($('acc-pw-hint').textContent = 'Password must be at least 8 characters.');
  if (nw !== cf) return void ($('acc-pw-hint').textContent = 'New password and confirmation do not match.');
  let body = 'password=' + encodeURIComponent(nw) + '&confirm=' + encodeURIComponent(cf);
  body += accViaToken
    ? '&username=' + encodeURIComponent($('acc-pw-user').value.trim())
    : '&current=' + encodeURIComponent($('acc-pw-cur').value);
  btn.disabled = true; btn.textContent = 'Saving…';
  const { ok, d } = await apiPost('/password', body);
  btn.disabled = false; btn.textContent = 'Set password';
  const msg = ok
    ? 'Password updated ✓ ' + (d.revoked || 0) + ' other session(s) signed out.'
    : (d.error || 'Could not set the password.');
  if (ok) {
    $('acc-pw-cur').value = $('acc-pw-new').value = $('acc-pw-conf').value = '';
    // Refresh FIRST, then write the result. loadAccess() resets this hint to
    // its idle text, so setting the message before it ran meant a successful
    // change flashed and vanished — indistinguishable from a dead button.
    await loadAccess();
  }
  $('acc-pw-hint').textContent = msg;
};

$('acc-revoke').onclick = async () => {
  const btn = $('acc-revoke');
  btn.disabled = true; btn.textContent = 'Signing out…';
  const { ok, d } = await apiPost('/revoke-all');
  btn.disabled = false; btn.textContent = 'Sign out all other devices';
  // Refresh before reporting, for the same reason as the password hint above.
  await loadAccess();
  $('acc-sess-hint').textContent = ok
    ? (d.revoked || 0) + ' device(s) signed out ✓' : 'Could not revoke sessions.';
};

$('acc-token-show').onclick = async () => {
  const btn = $('acc-token-show');
  if (btn.textContent === 'Hide') return void (loadAccess());
  try { const d = await api('/access/token'); $('acc-token').value = d.token || ''; btn.textContent = 'Hide'; }
  catch { $('acc-token').value = 'unavailable'; }
};
$('acc-token-copy').onclick = async () => {
  const btn = $('acc-token-copy');
  try {
    const d = await api('/access/token');
    await navigator.clipboard.writeText(d.token || '');
    btn.textContent = 'Copied ✓'; setTimeout(() => btn.textContent = 'Copy token', 1500);
  } catch { btn.textContent = 'Copy failed'; setTimeout(() => btn.textContent = 'Copy token', 1500); }
};
$('acc-token-rotate').onclick = async () => {
  if (!confirm('Rotate the API token? The browser extension and any scripts using the old token stop working until re-paired.')) return;
  const btn = $('acc-token-rotate');
  btn.disabled = true; btn.textContent = 'Rotating…';
  const { ok, d } = await apiPost('/token/rotate');
  btn.disabled = false; btn.textContent = 'Rotate token';
  if (ok) { $('acc-token').value = d.token || ''; $('acc-token-show').textContent = 'Hide'; }
  loadAccess();
};

$('acc-bind-save').onclick = async () => {
  const mode = $('acc-bind').value, port = $('acc-port').value.trim();
  const changingPort = String(port) !== String(location.port || 41595);
  if (!confirm('Apply network changes? The server restarts' +
      (changingPort ? ' on port ' + port + ' — this page will need reloading at the new address.' : ' and this page may briefly disconnect.'))) return;
  const btn = $('acc-bind-save');
  btn.disabled = true; btn.textContent = 'Applying…';
  const { ok, d } = await apiPost('/bind', 'mode=' + encodeURIComponent(mode) + '&port=' + encodeURIComponent(port));
  btn.disabled = false; btn.textContent = 'Apply';
  if (!ok) { $('acc-bind-warn').className = 'hint acc-warn'; $('acc-bind-warn').textContent = d.error || 'Could not apply.'; return; }
  $('acc-bind-warn').className = 'hint';
  $('acc-bind-warn').textContent = 'Applied — server restarting on ' + d.bind + ':' + d.port + '.';
};
$('setup-install').onclick = async () => {
  $('setup-install').textContent = 'Installing…'; $('setup-install').disabled = true;
  try { const d = await api('/setup/sources'); $('setup-install').textContent = (d.installed || 0) + ' sources installed ✓'; browseLoaded = false; }
  catch { $('setup-install').textContent = 'Failed'; $('setup-install').disabled = false; }
};
// ── Add a download (Activity) ──
// Magnets go to /load (torrent session); plain URLs to the segmented HTTP
// downloader via /download/url.
$('dl-go').onclick = async () => {
  const u = $('dl-url').value.trim();
  if (!u) return;
  $('dl-hint').textContent = 'Starting…';
  const magnet = /^magnet:/i.test(u);
  try {
    const d = await apiMutation((magnet ? '/load?url=' : '/download/url?url=') + encodeURIComponent(u));
    const ok = d && (d.ok === undefined || d.ok);
    $('dl-hint').textContent = ok ? 'Started ✓' : (d.error || 'Could not start.');
    if (ok) { $('dl-url').value = ''; loadActivity(); }
  } catch { $('dl-hint').textContent = 'Failed — is the URL reachable?'; }
};
$('dl-url').addEventListener('keydown', e => { if (e.key === 'Enter') $('dl-go').click(); });

// Sign out — revokes the session server-side and returns to the login screen.
$('signout').onclick = () => unpair();
$('setup-tmdb-save').onclick = async () => {
  const k = $('setup-tmdb-key').value.trim(); if (!k) return;
  try { await api('/setup/tmdb?key=' + encodeURIComponent(k)); $('setup-tmdb').textContent = 'TMDB key set ✓'; $('setup-tmdb-key').value=''; browseLoaded = false; }
  catch { $('setup-tmdb').textContent = 'Failed to save'; }
};
