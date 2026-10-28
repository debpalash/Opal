'use strict';
async function loadAddonRepositories() {
  $('addon-status').textContent = 'Loading repositories…';
  try {
    const data = await api('/addons');
    $('addon-list').replaceChildren();
    for (const repo of data.repositories || []) {
      const section = document.createElement('section');
      const title = document.createElement('h3'); title.textContent = repo.id; section.append(title);
      const refresh = document.createElement('button'); refresh.type = 'button'; refresh.textContent = 'Fetch signed catalog';
      refresh.onclick = async () => { refresh.disabled = true; try { await apiFormMutation('/addons/refresh', {id:repo.id}); await loadAddonRepositories(); } catch (error) { $('addon-status').textContent = error.message; } finally { refresh.disabled = false; } };
      const remove = document.createElement('button'); remove.type = 'button'; remove.textContent = 'Remove repository';
      remove.onclick = async () => { if (!confirm(`Remove ${repo.id}? Installed add-ons remain.`)) return; try { await apiFormMutation('/addons/remove',{id:repo.id}); await loadAddonRepositories(); } catch (error) { $('addon-status').textContent = error.message; } };
      section.append(refresh,remove);
      for (const addon of repo.addons || []) {
        const item = document.createElement('article'); item.className = 'file';
        const copy = document.createElement('div'); copy.className = 'n';
        const name = document.createElement('strong'); name.textContent = `${addon.name} · ${addon.version}`; copy.append(name);
        const permissions = document.createElement('p'); permissions.className = 'hint'; permissions.textContent = `Requests: ${(addon.permissions || []).join(', ') || 'none'}. Install and approve on the Opal host under Plugins → Sources.`; copy.append(permissions);
        if (addon.panel) {
          const heading = document.createElement('h4'); heading.textContent = addon.panel.title;
          const body = document.createElement('p'); body.textContent = addon.panel.body;
          copy.append(heading,body);
        }
        item.append(copy); section.append(item);
      }
      $('addon-list').append(section);
    }
    $('addon-status').textContent = data.repositories?.length ? 'Only catalogs verified against your saved publisher keys are shown.' : 'Add a repository URL and the publisher key you obtained from its author.';
  } catch (error) { $('addon-status').textContent = error.message; }
}
$('addon-refresh').onclick = loadAddonRepositories;
$('addon-form').onsubmit = async event => {
  event.preventDefault(); $('addon-add').disabled = true;
  try { await apiFormMutation('/addons/add',{id:$('addon-id').value.trim(),url:$('addon-url').value.trim(),public_key:$('addon-key').value.trim()}); await loadAddonRepositories(); }
  catch (error) { $('addon-status').textContent = error.message; }
  finally { $('addon-add').disabled = false; }
};
async function loadMoments() {
  try {
    const data = await api('/moments'); $('moment-list').replaceChildren();
    for (const moment of data.moments || []) {
      const item = document.createElement('div'); item.className = 'file';
      const title = document.createElement('div'); title.className = 'n'; title.textContent = `${moment.title} · ${Math.round(moment.end-moment.start)}s · ${moment.profile}`;
      const play = document.createElement('button'); play.type = 'button'; play.textContent = 'Play clip';
      play.onclick = () => startBrowserSession(async () => ({...await apiFormMutation('/moments/play',{id:moment.id}), mode:'direct', start:0, offset:0}));
      const send = document.createElement('button'); send.type = 'button'; send.textContent = 'Send to other Opal';
      send.onclick = async () => { try { await apiFormMutation('/moments/send',{id:moment.id,peer:$('continuum-peer').value.trim(),token:$('continuum-token').value}); $('continuum-token').value=''; toast('Clip sent'); } catch (error) { toast(error.message); } };
      const remove = document.createElement('button'); remove.type = 'button'; remove.textContent = 'Delete clip';
      remove.onclick = async () => { if (!confirm('Delete this shared clip?')) return; try { await apiFormMutation('/moments/delete',{id:moment.id}); await loadMoments(); } catch (error) { toast(error.message); } };
      item.append(title,play,send,remove); $('moment-list').append(item);
    }
    $('moment-status').textContent = data.moments?.length ? 'Send uses the other Opal address and token above.' : 'Share a clip from a local file playing on this Opal.';
  } catch (error) { $('moment-status').textContent = error.message; }
}
$('moment-refresh').onclick = loadMoments;
$('moment-form').onsubmit = async event => {
  event.preventDefault(); $('moment-create').disabled = true; $('moment-status').textContent = 'Exporting clip…';
  try { await apiFormMutation('/moments/create',{title:$('moment-title').value,start:$('moment-start').value,end:$('moment-end').value}); await loadMoments(); }
  catch (error) { $('moment-status').textContent=error.message; }
  finally { $('moment-create').disabled=false; }
};
