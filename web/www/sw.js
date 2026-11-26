// Service Worker: guarda o app (não o jogo) para funcionar offline.
const CACHE = 'tg-web-v1';
const FILES = ['./', 'index.html', 'main.js', 'worker.js', 'psxcore.wasm', 'openbios.bin', 'manifest.webmanifest'];
self.addEventListener('install', (e) => e.waitUntil(caches.open(CACHE).then((c) => c.addAll(FILES))));
self.addEventListener('fetch', (e) => {
  if (e.request.headers.has('range')) return; // leituras do disco local nunca passam pelo cache
  e.respondWith(caches.match(e.request).then((r) => r || fetch(e.request)));
});
