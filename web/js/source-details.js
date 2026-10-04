// Shared source detail actions. Loaded after media.js and before discovery.js.
let sourceDetailsReturnFocus = null;
function closeSourceDetails(){
  const dialog = $('source-details');
  if (dialog.open) dialog.close();
}
function detailAction(label, run, primary){
  const button = document.createElement('button');
  button.type = 'button'; button.textContent = label;
  if (primary) button.className = 'primary';
  button.onclick = async () => {
    button.disabled = true;
    try { await run(); } catch (error) {
      button.disabled = false; toast(error.message || 'Action failed');
    }
  };
  return button;
}
function sourceArtUrl(value){
  if (!value) return '';
  try {
    const url = new URL(value, location.href);
    return url.protocol === 'http:' || url.protocol === 'https:' ? url.href : '';
  } catch { return ''; }
}
function openSourceDetails(source, item, trigger){
  const dialog = $('source-details'), actions = $('source-details-actions');
  sourceDetailsReturnFocus = trigger || document.activeElement;
  $('source-details-source').textContent = source;
  $('source-details-title').textContent = item.name || item.title || 'Untitled';
  const runtime = Number(item.runtime || item.duration || 0);
  $('source-details-meta').textContent = item.meta || [item.type || '', item.year || '', runtime ? fmt(runtime) : ''].filter(Boolean).join(' · ');
  const overviewBox = $('source-details-overview');
  overviewBox.textContent = item.overview || ''; overviewBox.removeAttribute('style'); delete overviewBox.dataset.base;
  const art = $('source-details-art');
  const artUrl = sourceArtUrl(item.artUrl || (source === 'Jellyfin' && item.image
    ? `${BASE}/api/jellyfin/poster?id=${encodeURIComponent(item.id)}` : ''));
  art.hidden = !artUrl; art.src = artUrl; art.alt = artUrl ? `Poster for ${item.name || item.title || 'item'}` : '';
  actions.replaceChildren();
  if (source === 'Jellyfin') {
    const play = async () => {
      if (item.folder) { closeSourceDetails(); jfBrowse(item.id); return; }
      const route = isJfAudio(item.type) ? '/jellyfin/play_audio?id=' : '/jellyfin/play?id=';
      await api(route + encodeURIComponent(item.id)); closeSourceDetails();
    };
    actions.append(detailAction(item.folder ? 'Open' : (item.progress && !item.played ? 'Resume on Opal' : 'Play on Opal'), play, true));
    if (!item.folder) {
      actions.append(detailAction(item.favorite ? 'Remove favorite' : 'Favorite', async () => {
        await apiMutation('/jellyfin/action?id=' + encodeURIComponent(item.id) + '&action=favorite&enabled=' + !item.favorite);
        closeSourceDetails(); await loadJellyfin(); setTimeout(loadJellyfin, 1200);
      }));
      actions.append(detailAction(item.played ? 'Mark unwatched' : 'Mark watched', async () => {
        await apiMutation('/jellyfin/action?id=' + encodeURIComponent(item.id) + '&action=played&enabled=' + !item.played);
        closeSourceDetails(); await loadJellyfin(); setTimeout(loadJellyfin, 1200);
      }));
    }
  } else if (source === 'Plex') {
    actions.append(detailAction(item.folder ? 'Open' : (item.progress && !item.played ? 'Resume on Opal' : 'Play on Opal'), async () => {
      await apiMutation('/plex/' + (item.folder ? 'open_item' : 'play') + '?id=' + encodeURIComponent(item.id));
      closeSourceDetails(); pollPlex();
    }, true));
    if (!item.folder) {
      actions.append(detailAction(item.favorite ? 'Remove favorite' : 'Favorite', async () => {
        await apiMutation('/plex/action?id=' + encodeURIComponent(item.id) + '&action=favorite&enabled=' + !item.favorite);
        closeSourceDetails(); pollPlex();
      }));
      actions.append(detailAction(item.played ? 'Mark unwatched' : 'Mark watched', async () => {
        await apiMutation('/plex/action?id=' + encodeURIComponent(item.id) + '&action=played&enabled=' + !item.played);
        closeSourceDetails(); pollPlex();
      }));
      const rating = document.createElement('select');
      rating.className = 'plex-rating'; rating.dataset.id = item.id;
      rating.setAttribute('aria-label', `Rate ${item.title || 'item'}`);
      rating.innerHTML = plexRatingOptions(item.rating);
      rating.onchange = async () => {
        rating.disabled = true;
        try {
          await apiMutation('/plex/action?id=' + encodeURIComponent(item.id) + '&action=rating&rating=' + encodeURIComponent(rating.value));
          closeSourceDetails(); pollPlex();
        } catch (error) { rating.disabled = false; toast(error.message || 'Could not update rating.'); }
      };
      actions.append(rating);
    }
  } else if (source === 'Audiobookshelf') {
    actions.append(detailAction('Play on Opal', async () => {
      await apiMutation('/abs/play?idx=' + encodeURIComponent(item.index)); closeSourceDetails(); pollAbs();
    }, true));
  } else if (source === 'OPDS') {
    actions.append(detailAction(item.nav ? 'Open' : 'Read', async () => {
      await apiMutation('/opds/open?idx=' + encodeURIComponent(item.index)); closeSourceDetails(); pollOpds();
    }, true));
  } else if (source === 'Podcast') {
    actions.append(detailAction(item.kind === 'show' ? 'View episodes' : destinationActionLabel('Play'), async () => {
      closeSourceDetails();
      if (item.kind === 'show') loadPodEpisodes(item.index);
      else dispatchPlay(item.url || '', item.title || item.name || '', () => api('/podcasts/play?idx=' + encodeURIComponent(item.index)));
    }, true));
    if (item.kind === 'episode' && item.url) actions.append(detailAction('Queue', async () => {
      await queueMedia(item.url, item.title || item.name || ''); closeSourceDetails();
    }));
  } else if (source === 'Music') {
    actions.append(detailAction(destinationActionLabel('Play'), async () => {
      closeSourceDetails();
      dispatchPlay(item.url || '', item.title || '', () => api('/music/play?source=' + encodeURIComponent(item.source) + '&id=' + encodeURIComponent(item.id || '')));
    }, true));
    if (item.url) actions.append(detailAction('Queue', async () => {
      await queueMedia(item.url, item.title || ''); closeSourceDetails();
    }));
  } else if (source === 'Radio') {
    actions.append(detailAction(destinationActionLabel('Listen'), async () => {
      closeSourceDetails();
      dispatchPlay(item.url || '', item.name || '', () => api('/radio/play?uuid=' + encodeURIComponent(item.uuid || '')));
    }, true));
    if (item.url) actions.append(detailAction('Queue', async () => {
      await queueMedia(item.url, item.name || ''); closeSourceDetails();
    }));
  } else if (source === 'Anime') {
    actions.append(detailAction('View episodes', () => {
      closeSourceDetails(); loadAnimeEpisodes(item.index);
    }, true));
  } else if (source === 'Live TV') {
    actions.append(detailAction(destinationActionLabel('Watch'), () => {
      closeSourceDetails(); dispatchPlay(item.url || '', item.name || '', () =>
        apiMutation('/load?url=' + encodeURIComponent(item.url || '')));
    }, true));
    if (item.url) actions.append(detailAction('Queue', async () => {
      await queueMedia(item.url, item.name || ''); closeSourceDetails();
    }));
  } else if (source === 'YouTube') {
    const url = 'https://www.youtube.com/watch?v=' + (item.id || '');
    actions.append(detailAction(destinationActionLabel('Play'), () => {
      closeSourceDetails();
      if (HOSTED || PLAY_HERE) openYtEmbed(item.id, item.title || '');
      else return apiMutation('/load?url=' + encodeURIComponent(url));
    }, true));
    if (item.id) actions.append(detailAction('Queue', async () => {
      await queueMedia(url, item.title || ''); closeSourceDetails();
    }));
  } else if (source === 'Comic') {
    actions.append(detailAction('Read', () => { closeSourceDetails(); openComic(item.url); }, true));
  } else if (source === 'Novel') {
    actions.append(detailAction(item.kind === 'chapter' ? 'Read' : 'Open', async () => {
      if (item.kind !== 'chapter') novelIdx = item.index;
      await api('/novels/' + (item.kind === 'chapter' ? 'chapter' : 'open') + '?idx=' + encodeURIComponent(item.index));
      closeSourceDetails(); pollNovels();
    }, true));
  } else if (source === 'Drama') {
    actions.append(detailAction('Find streams', async () => {
      await api('/drama/play?idx=' + encodeURIComponent(item.index)); closeSourceDetails();
    }, true));
    if (item.episodes) {
      const overview = $('source-details-overview');
      overview.dataset.base = item.overview || '';
      actions.append(detailAction('Episodes', async () => { await showDramaEpisodes(item.index, overview); }));
    }
  } else if (source === 'RSS') {
    actions.append(detailAction('Play on Opal', async () => {
      await apiMutation('/load?url=' + encodeURIComponent(item.url)); closeSourceDetails();
    }, true));
    if (item.url) actions.append(detailAction('Queue', async () => {
      await queueMedia(item.url, item.title || item.name || ''); closeSourceDetails();
    }));
  }
  if (!dialog.open) dialog.showModal();
}
$('source-details-close').onclick = closeSourceDetails;
$('source-details').addEventListener('click', event => { if (event.target === $('source-details')) closeSourceDetails(); });
$('source-details').addEventListener('close', () => {
  $('source-details-art').removeAttribute('src');
  if (sourceDetailsReturnFocus && sourceDetailsReturnFocus.isConnected) sourceDetailsReturnFocus.focus();
  sourceDetailsReturnFocus = null;
});
