'use strict';

// Curated manga/novel catalog plus the active endpoint for each framework.
let srcCatalog = null, srcActive = {};
const SRC_PAGE = 12;
let srcShown = SRC_PAGE;
async function loadSources(){
  try {
    const [catalog, state] = await Promise.all([api('/source/catalog'), api('/source/config')]);
    srcCatalog = Array.isArray(catalog) ? catalog : [];
    srcActive = Object.fromEntries((state.sources || []).map(item => [item.framework, item.base || '']));
    renderSources();
  } catch { $('srcs-hint').textContent = 'Could not load the source catalog.'; }
}
$('srcs-q').addEventListener('input', () => { srcShown = SRC_PAGE; renderSources(); });
function renderSources(){
  const q = $('srcs-q').value.trim().toLowerCase();
  const all = (srcCatalog || []).filter(s => !q || (s.name || '').toLowerCase().includes(q));
  const rows = all.slice(0, srcShown), total = (srcCatalog || []).length;
  $('srcs-hint').textContent = q ? `${all.length} of ${total} match “${$('srcs-q').value.trim()}” · showing ${rows.length}`
    : `${total} sources in the catalog · showing ${rows.length}`;
  $('srcs-list').innerHTML = rows.map(s => {
    const active = srcActive[s.framework] === s.base.replace(/\/$/, '');
    return `<div class="result"><div class="t">${esc(s.name)}</div><div class="m"><span class="src">${esc(s.framework || '')}</span>
      ${s.lang ? `<span>${esc(s.lang)}</span>` : ''}<button class="play" data-source-action="${active ? 'remove' : 'save'}"
      data-fw="${esc(s.framework || '')}" data-base="${encodeURIComponent(s.base || '')}">${active ? 'Remove' : (srcActive[s.framework] ? 'Use instead' : 'Use source')}</button></div></div>`;
  }).join('') || '<div class="empty">No matches</div>';
  if (all.length > rows.length) {
    const more = document.createElement('button'); more.className = 'quick-btn';
    more.textContent = `Show ${Math.min(SRC_PAGE, all.length - rows.length)} more of ${all.length - rows.length}`;
    more.onclick = () => { srcShown += SRC_PAGE; renderSources(); }; $('srcs-list').append(more);
  }
  $('srcs-list').querySelectorAll('[data-source-action]').forEach(button => button.onclick = async () => {
    const action = button.dataset.sourceAction, framework = button.dataset.fw;
    if (action === 'save' && srcActive[framework] && !confirm('Replace the active source for this framework?')) return;
    button.disabled = true;
    try {
      await apiFormMutation('/source/config', {action, framework, base:decodeURIComponent(button.dataset.base || '')});
      toast(action === 'remove' ? 'Source removed' : 'Source activated'); await loadSources();
    } catch (error) { toast(error.message || 'Could not update source'); button.disabled = false; }
  });
}
