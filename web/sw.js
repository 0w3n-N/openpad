// Offline support for the installed app. All of the app's files are cached
// together under one version; the Pages workflow stamps a new version on
// every deploy, so an update replaces the whole set at once and the app
// never runs a mix of old and new files. Notebooks live in IndexedDB.

const VERSION = 'openpad-dev';
const FILES = [
  './', 'app.html', 'app.js', 'editor.js', 'ink.js', 'link.js', 'model.js', 'scan.js', 'store.js', 'ui.js',
  'style.css', 'icon.svg', 'icon.png', 'manifest.webmanifest',
  'vendor/pdfjs/pdf.min.mjs', 'vendor/pdfjs/pdf.worker.min.mjs', 'vendor/jsqr/jsqr.js',
];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(VERSION).then((c) => c.addAll(FILES.map((f) => new Request(f, { cache: 'reload' })))).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys()
    .then((keys) => Promise.all(keys.filter((k) => k !== VERSION).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);
  // Only the app's own files; the computer's API is never cached.
  if (e.request.method !== 'GET' || url.origin !== location.origin) return;
  e.respondWith((async () => {
    const cache = await caches.open(VERSION);
    const hit = await cache.match(e.request, { ignoreSearch: true });
    if (hit) return hit;
    if (e.request.mode === 'navigate') return (await cache.match('./')) || fetch(e.request);
    return fetch(e.request);
  })());
});
