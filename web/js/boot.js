'use strict';

// All feature bundles are loaded before this file. Keep startup here so no
// feature can run while a later bundle's state is still in its TDZ.
// Every form control must retain an accessible name even while labels are
// visually compact. Prefer authored labels, then derive a stable fallback
// from nearby configuration text or the control id (never from live values).
document.querySelectorAll('input, select, textarea').forEach(control => {
  if (control.hasAttribute('aria-label') || control.hasAttribute('aria-labelledby') ||
      control.closest('label') || (control.id && document.querySelector(`label[for="${CSS.escape(control.id)}"]`))) return;
  const rowText = control.closest('.cfg-row')?.querySelector('span')?.textContent?.trim();
  const name = rowText || control.getAttribute('placeholder') || control.id
    .replace(/^(auth|acc|setup|plug|jf|abs|opds|ltv|party)-/, '')
    .replace(/[-_]+/g, ' ').trim();
  if (name) control.setAttribute('aria-label', name.replace(/[\u2026:.]+$/u, '').trim());
});
navPageButtons.forEach(button => {
  const page = $('page-' + button.dataset.page);
  if (page) page.setAttribute('aria-label', button.textContent.trim());
});
syncNavMode();
openPage(routePage() || 'home', { replace:true, focus:false });
webPerf.shellReady();

// ── Authentication boot ──
fetch(BASE + '/api/auth/status', { credentials:'same-origin' })
  .then(r => r.json())
  .then(d => d.authed ? paired() : showAuth())
  .catch(showAuth);
