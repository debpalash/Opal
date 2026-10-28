'use strict';
async function loadProfiles() {
  try {
    const data = await api('/profiles');
    $('profile-choice').replaceChildren();
    for (const profile of data.profiles || []) {
      const option = document.createElement('option'); option.value = profile.id;
      option.textContent = profile.name + (profile.kid ? ' · Kids' : ''); option.selected = profile.id === data.active;
      $('profile-choice').append(option);
    }
    $('profile-status').textContent = 'Switching profiles restarts this Opal. Administrator access is required.';
  } catch (error) { $('profile-status').textContent = error.message; }
}
$('profile-refresh').onclick = loadProfiles;
$('profile-form').onsubmit = async event => {
  event.preventDefault();
  $('profile-switch').disabled = true;
  try {
    // PIN errors are not expired browser sessions; handle them without unpairing.
    const response = await networkFetch(BASE + '/api/profiles/switch', {method:'POST', credentials:'same-origin', headers:{'Content-Type':'application/x-www-form-urlencoded'}, body:new URLSearchParams({id:$('profile-choice').value, pin:$('profile-pin').value})});
    const data = await response.json();
    if (!response.ok) throw new Error(data.pin_of === 'owner' ? 'Enter the owner profile PIN.' : data.error || 'Could not switch profiles');
    $('profile-pin').value = '';
    $('profile-status').textContent = data.restarting ? 'Opal is restarting. Refresh profiles when it reconnects.' : 'This profile is already active.';
  } catch (error) { $('profile-status').textContent = error.message; }
  finally { $('profile-switch').disabled = false; }
};
