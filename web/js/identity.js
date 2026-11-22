'use strict';

// ── Shared media identity ──
// The server computes one canonical identity per actionable row in
// src/services/media_identity_pure.zig (the native app renders from the same
// card) and ships it as `row.identity`:
//   {key, kind, ids, season, episode, absolute, resume, duration, watched,
//    targets:{here, opal, queue, download}, actions:[{id, label}]}
// This file only validates and reads that object. It never re-derives labels,
// equality, or targets, so the browser cannot drift from native.

const IDENTITY_KEY_RE = /^(?:film|series|other):(?:imdb:tt\d{7,10}|(?:tmdb|tvdb|anilist|mal):\d{1,10}|local:[0-9a-f]{1,16})(?::(?:s\d{1,5}e\d{1,5}|a\d{1,5}))?$/;
const IDENTITY_ACTIONS = new Set(['play_here', 'play_on_opal', 'queue', 'download', 'details', 'read', 'open', 'open_audio']);

function mediaIdentityKey(row){
  const key = row?.identity?.key;
  return typeof key === 'string' && IDENTITY_KEY_RE.test(key) ? key : '';
}

function identityActions(identity){
  if (!Array.isArray(identity?.actions)) return [];
  return identity.actions.filter(action => IDENTITY_ACTIONS.has(action?.id) && typeof action.label === 'string' && action.label.length <= 32);
}

// The verb that opens the item: everything except the secondary queue/download.
function identityPrimaryAction(identity){
  return identityActions(identity).find(action => action.id !== 'queue' && action.id !== 'download') || null;
}

function identityHas(identity, id){
  return identityActions(identity).some(action => action.id === id);
}

// Resume/watched exactly as the server judged them (same ≥95% rule as sync).
function identityProgress(identity){
  const resume = Number(identity?.resume), duration = Number(identity?.duration);
  return {
    resume: Number.isFinite(resume) && resume > 0 ? resume : 0,
    duration: Number.isFinite(duration) && duration > 0 ? duration : 0,
    watched: identity?.watched === true,
  };
}

// ── Selection tokens ──
// Same contract as media_identity_pure.Selection: every async fetch for a
// selection captures a token, and its result is applied only while that token
// is still current, so a slow answer for title A never paints onto title B.
function createSelection(){
  let generation = 0, key = '';
  return {
    select(next){ generation += 1; key = String(next || ''); return {generation, key}; },
    clear(){ generation += 1; key = ''; },
    token(){ return {generation, key}; },
    isCurrent(token){ return key !== '' && token?.generation === generation && token.key === key; },
    isSameTitle(token){ return key !== '' && token?.key === key; },
  };
}
