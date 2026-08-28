'use strict';

// All feature bundles are loaded before this file. Keep startup here so no
// feature can run while a later bundle's state is still in its TDZ.
navPageButtons.forEach(button => {
  const page = $('page-' + button.dataset.page);
  if (page) page.setAttribute('aria-label', button.textContent.trim());
});
syncNavMode();
openPage(routePage() || 'home', { replace:true, focus:false });

// ── Authentication boot ──
fetch(BASE + '/api/auth/status', { credentials:'same-origin' })
  .then(r => r.json())
  .then(d => d.authed ? paired() : showAuth())
  .catch(showAuth);
