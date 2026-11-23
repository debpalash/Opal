'use strict';
// Age caps offered for kid profiles (maturity_pure.TIERS); the server accepts
// any of these names and snaps anything else onto the same scale.
const KID_RATINGS = ['G', 'TV-Y7', 'PG', 'PG-13', 'TV-14', 'R', 'NC-17'];
const KID_RATING_AGES = [0, 7, 8, 13, 14, 17, 18];
let profileRows = [];
async function loadProfiles() {
  try {
    const data = await api('/profiles');
    profileRows = data.profiles || [];
    $('profile-choice').replaceChildren();
    $('profile-kid-target').replaceChildren();
    for (const profile of profileRows) {
      const option = document.createElement('option'); option.value = profile.id;
      option.textContent = profile.name + (profile.kid ? ' · Kids · ' + profile.rating : ''); option.selected = profile.id === data.active;
      $('profile-choice').append(option);
      if (profile.default) continue;
      const kidOption = document.createElement('option'); kidOption.value = profile.id;
      kidOption.textContent = profile.name;
      $('profile-kid-target').append(kidOption);
    }
    if (!$('profile-kid-rating').options.length) {
      for (const name of KID_RATINGS) {
        const option = document.createElement('option'); option.value = name; option.textContent = name;
        $('profile-kid-rating').append(option);
      }
    }
    $('profile-kid-form').hidden = !$('profile-kid-target').options.length;
    syncKidForm();
    $('profile-status').textContent = 'Switching profiles restarts this Opal. Administrator access is required.';
  } catch (error) { $('profile-status').textContent = error.message; }
}
function syncKidForm() {
  const profile = profileRows.find(p => p.id === $('profile-kid-target').value);
  if (!profile) return;
  $('profile-kid-on').checked = !!profile.kid;
  $('profile-kid-unrated').checked = !!profile.allow_unrated;
  let index = 2; // PG
  if (profile.kid && Number.isFinite(profile.max_age)) KID_RATING_AGES.forEach((age, i) => { if (age <= profile.max_age) index = i; });
  $('profile-kid-rating').value = KID_RATINGS[index];
  $('profile-kid-status').textContent = profile.kid ? 'Limit: ' + profile.rating + '. Unrated and over-limit titles are hidden and blocked.' : 'Not a kid profile.';
}
$('profile-kid-target').onchange = syncKidForm;
$('profile-kid-form').onsubmit = async event => {
  event.preventDefault();
  $('profile-kid-save').disabled = true;
  try {
    // A wrong parent PIN is a 401 that must not unpair this browser.
    const response = await networkFetch(BASE + '/api/profiles/kid', {method:'POST', credentials:'same-origin', headers:{'Content-Type':'application/x-www-form-urlencoded'}, body:new URLSearchParams({
      id:$('profile-kid-target').value, kid:$('profile-kid-on').checked ? '1' : '0', rating:$('profile-kid-rating').value,
      allow_unrated:$('profile-kid-unrated').checked ? '1' : '0', pin:$('profile-kid-pin').value})});
    const data = await response.json();
    if (!response.ok) throw new Error(data.pin_of === 'owner' ? (data.error === 'wrong pin' ? 'Wrong main profile PIN.' : 'Enter the main profile PIN to loosen these limits.') : data.error || 'Could not save age limits');
    $('profile-kid-pin').value = '';
    $('profile-kid-status').textContent = 'Saved (' + data.rating + '). Applies the next time that profile opens.';
    await loadProfiles();
  } catch (error) { $('profile-kid-status').textContent = error.message; }
  finally { $('profile-kid-save').disabled = false; }
};
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
