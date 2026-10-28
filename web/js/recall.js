'use strict';
let recallGeneration = 0;
async function searchRecall(event) {
  event?.preventDefault();
  const generation = ++recallGeneration;
  const query = $('recall-query').value.trim();
  $('recall-results').replaceChildren();
  if (!query) return;
  $('recall-status').textContent = 'Searching your library…';
  try {
    const data = await api('/recall?' + new URLSearchParams({q: query}));
    if (generation !== recallGeneration) return;
    const rows = [...(data.docs || []).map(row => ({...row, type:'doc'})), ...(data.moments || []).map(row => ({...row, type:'moment'}))];
    $('recall-status').textContent = rows.length ? `${rows.length} matches · ${data.constraints?.summary || 'Your library'}` : 'No matches yet. Import media or captions, then try another phrase.';
    for (const row of rows) {
      const item = document.createElement('div'); item.className = 'file';
      const copy = document.createElement('div'); copy.className = 'n';
      const title = document.createElement('strong'); title.textContent = row.title || 'Untitled'; copy.append(title);
      const detail = document.createElement('p'); detail.className = 'hint'; detail.textContent = [row.clock, row.snippet].filter(Boolean).join(' · '); copy.append(detail);
      const play = document.createElement('button'); play.type = 'button'; play.textContent = row.type === 'moment' ? 'Play this moment' : 'Play on Opal';
      play.disabled = row.type === 'doc' && !row.playable;
      play.onclick = async () => { play.disabled = true; try { await apiFormMutation('/recall/play', {[row.type]:row.id}); toast('Playing on Opal'); } catch (error) { toast(error.message); } finally { play.disabled = false; } };
      item.append(copy, play); $('recall-results').append(item);
    }
  } catch (error) { if (generation === recallGeneration) $('recall-status').textContent = error.message; }
}
$('recall-form').addEventListener('submit', searchRecall);
