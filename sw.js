/* SnapPro service worker.
   Only job: show a friendly page when there's no internet.
   It never stores the app itself, so every update reaches people at once. */
const CACHE = "snappro-offline-v1";
const OFFLINE = "/offline.html";
self.addEventListener("install", e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll([OFFLINE, "/icon-192.png"])).then(() => self.skipWaiting()));
});
self.addEventListener("activate", e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener("fetch", e => {
  const r = e.request;
  if(r.method !== "GET" || r.mode !== "navigate") return;                 // everything else goes straight to the network
  if(new URL(r.url).origin !== self.location.origin) return;
  e.respondWith(fetch(r).catch(() => caches.match(OFFLINE)));
});
