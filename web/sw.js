// Offline support for the installed app: keep its files cached, and serve
// them from the cache first. Notebooks themselves live in IndexedDB.

const VERSION = 'openpad-0.5.0';
const FILES = [
  './', 'app.html', 'app.js', 'editor.js', 'ink.js', 'link.js', 'model.js', 'store.js', 'style.css',
  'icon.svg', 'icon.png', 'manifest.webmanifest', 'vendor/pdfjs/pdf.min.mjs', 'vendor/pdfjs/pdf.worker.min.mjs',
];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(VERSION).then((c) => c.addAll(FILES)).then(() => self.skipWaiting()));
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
  e.respondWith(
    caches.match(e.request, { ignoreSearch: true }).then((hit) => {
      const net = fetch(e.request).then((r) => {
        if (r.ok) caches.open(VERSION).then((c) => c.put(e.request, r.clone()));
        return r;
      });
      return hit || net.catch(() => caches.match('app.html'));
    }),
  );
});
