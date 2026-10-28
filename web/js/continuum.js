'use strict';
let continuumSession = null;
let continuumGeneration = 0;
let continuumProgressAt = 0;
function continuumEndpoint(session, action) {
  const path = session.url.slice(0, session.url.lastIndexOf('/') + 1);
  if (!/^\/api\/stream\/[a-f0-9]+\/[a-zA-Z0-9._-]+\/$/.test(path)) throw new Error('Invalid stream response');
  return path + action;
}
async function stopContinuum() {
  ++continuumGeneration;
  const session = continuumSession; continuumSession = null;
  if (session) await networkFetch(BASE + continuumEndpoint(session, 'stop'), {method:'POST', credentials:'same-origin'}).catch(()=>{});
}
async function playContinuum() {
  const stopping = stopContinuum();
  const generation = continuumGeneration;
  await stopping;
  if (generation !== continuumGeneration) return;
  $('continuum-status').textContent = 'Preparing playback…';
  try {
    const session = await apiFormMutation('/stream', {current:1, quality:$('continuum-quality').value, caps:'h264,aac,mp4,hls'});
    continuumEndpoint(session, 'stop');
    if (generation !== continuumGeneration) { await networkFetch(BASE + continuumEndpoint(session, 'stop'), {method:'POST', credentials:'same-origin'}); return; }
    if (session.mode === 'direct') openStreamUrl(BASE + session.url, session.title);
    else openHls(BASE + session.url, session.title);
    continuumSession = session;
    const video = $('video');
    video.addEventListener('loadedmetadata', () => {
      if (continuumSession === session) video.currentTime = Math.max(0, session.start - session.offset);
    }, {once:true});
    $('continuum-status').textContent = 'Playing here. Close the player to end the stream.';
  } catch (error) { $('continuum-status').textContent = error.message; }
}
$('continuum-play').onclick = playContinuum;
$('video').addEventListener('timeupdate', () => {
  const session = continuumSession, now = Date.now();
  if (!session || now - continuumProgressAt < 5000) return;
  continuumProgressAt = now;
  const video = $('video');
  networkFetch(BASE + continuumEndpoint(session, 'progress'), {method:'POST', credentials:'same-origin', headers:{'Content-Type':'application/x-www-form-urlencoded'}, body:new URLSearchParams({pos:video.currentTime + session.offset, dur:session.duration || video.duration})}).catch(()=>{});
});
async function handoffContinuum(action) {
  $('continuum-status').textContent = 'Connecting…';
  try {
    await apiFormMutation('/handoff/' + action, {peer:$('continuum-peer').value.trim(), token:$('continuum-token').value});
    $('continuum-token').value = '';
    $('continuum-status').textContent = action === 'send' ? 'Playback sent to the other Opal.' : 'Playback brought to this Opal.';
  } catch (error) { $('continuum-status').textContent = error.message; }
}
$('continuum-send').onclick = () => handoffContinuum('send');
$('continuum-bring').onclick = () => handoffContinuum('bring');
