'use strict';

// Empty catalog placeholders share the real card geometry and never start requests.
const BROWSE_POLL_MS = 300;
const BROWSE_POLL_LIMIT = 180;
function browseLoadingHtml(kind = 'poster', count = 8){
  const safeKind = ['poster', 'square', 'video', 'row'].includes(kind) ? kind : 'poster';
  const cards = Array.from({length:Math.max(1, Math.min(12, count))}, () =>
    `<div class="browse-skeleton browse-skeleton-${safeKind}" aria-hidden="true"><div class="browse-skeleton-art"></div><div class="browse-skeleton-copy"><i></i><i></i></div></div>`).join('');
  return `<div class="browse-loading-status" role="status"><span class="sr-only">Loading content…</span></div>${cards}`;
}
function setBrowseBusy(target, loading){ $(target)?.setAttribute('aria-busy', String(Boolean(loading))); }
function failBrowse(target, hint, message){
  setBrowseBusy(target, false);
  if ($(target)?.querySelector('.browse-skeleton')) $(target).innerHTML = `<div class="empty">${esc(message)}</div>`;
  $(hint).textContent = message;
}

