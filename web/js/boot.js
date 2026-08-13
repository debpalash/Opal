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
if (TOKEN) paired(); else showAuth();
