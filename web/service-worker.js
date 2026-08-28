const CACHE = 'opal-shell-v3';
const SHELL = [
  '/',
  '/index.html',
  '/manifest.webmanifest',
  '/icon.svg',
  '/styles/app.css',
  '/js/core.js',
  '/js/now-playing.js',
  '/js/catalog.js',
  '/js/playback.js',
  '/js/integrations.js',
  '/js/media.js',
  '/js/discovery.js',
  '/js/boot.js',
  '/vendor/hls.min.js',
];

self.addEventListener('install', event => {
  event.waitUntil(caches.open(CACHE).then(cache => cache.addAll(SHELL)));
  self.skipWaiting();
});

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(keys => Promise.all(keys.filter(key => key !== CACHE).map(key => caches.delete(key))))
  );
  self.clients.claim();
});

self.addEventListener('fetch', event => {
  const request = event.request;
  if (request.method !== 'GET') return;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;

  // User data, credentials, live state, and media are deliberately never
  // cached. Offline mode is a navigable shell, not a stale copy of an account.
  if (url.pathname.startsWith('/api/') ||
      ['/events', '/stream', '/transcode', '/poster', '/vtt', '/now-playing/art'].includes(url.pathname)) return;

  if (request.mode === 'navigate') {
    event.respondWith(
      fetch(request).then(async response => {
        if (response.ok) await (await caches.open(CACHE)).put('/index.html', response.clone());
        return response;
      }).catch(async () => (await caches.match('/index.html')) || new Response(
        '<h1>Opal is offline</h1><p>Reconnect to your Opal server and retry.</p>',
        { status: 503, headers: { 'Content-Type': 'text/html; charset=utf-8' } },
      ))
    );
    return;
  }

  if (!SHELL.includes(url.pathname)) return;
  event.respondWith(
    caches.match(request).then(cached => cached || fetch(request).then(async response => {
      if (response.ok) await (await caches.open(CACHE)).put(request, response.clone());
      return response;
    }))
  );
});
