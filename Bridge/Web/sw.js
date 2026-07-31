// Service worker for HelmMirror.
//
// Deliberately minimal. The whole point of this app is a LIVE video stream, so
// caching the stream would be actively wrong — stale sonar is worse than none.
// We cache only the app shell (page, icons, manifest) so the home-screen icon
// opens instantly and shows a useful message even when the bridge is off.

// Bump this on every page change — it evicts the old cache so phones that
// already added the app to their home screen pick up the new version.
const SHELL = 'helmmirror-shell-v2';
const SHELL_FILES = [
  './',
  './index.html',
  './manifest.webmanifest',
  './icon-180.png',
  './icon-192.png',
  './icon-512.png',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(SHELL).then((c) => c.addAll(SHELL_FILES)).then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== SHELL).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);

  // NEVER cache the live stream, its playlist, or control endpoints.
  const isLive =
    url.pathname.endsWith('.m3u8') ||
    url.pathname.endsWith('.ts') ||
    url.pathname.endsWith('.m4s') ||
    url.pathname.startsWith('/touch') ||
    url.pathname.startsWith('/status');
  if (isLive || event.request.method !== 'GET') return;   // straight to network

  // App shell: network-first so edits show up, falling back to cache offline.
  event.respondWith(
    fetch(event.request)
      .then((res) => {
        const copy = res.clone();
        caches.open(SHELL).then((c) => c.put(event.request, copy)).catch(() => {});
        return res;
      })
      .catch(() => caches.match(event.request).then((hit) => hit || caches.match('./index.html')))
  );
});
