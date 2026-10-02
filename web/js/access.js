// Account, session, and remote-access controls. Loaded after integrations.js.
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
