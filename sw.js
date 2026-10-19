/* SnapPro service worker.
   1. Shows a friendly page when there's no internet. It never stores the app
      itself, so every update reaches people at once.
   2. Shows phone notifications (quotes, bookings, messages, calls…) even when
      SnapPro is closed, and opens the right screen when one is tapped. */
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

/* ---------- notifications ---------- */
self.addEventListener("push", e => {
  let d = {};
  try{ d = e.data ? e.data.json() : {}; }catch(_){ d = { body: e.data ? e.data.text() : "" }; }
  const call = d.kind === "call";
  const url = typeof d.url === "string" && d.url.startsWith("/") ? d.url : "/app.html";
  e.waitUntil(self.registration.showNotification(d.title || "SnapPro", {
    body: d.body || "", icon: "/icon-192.png", badge: "/badge-72.png",
    tag: d.tag || undefined, renotify: !!d.tag, data: { url },
    requireInteraction: call, vibrate: call ? [600, 300, 600, 300, 600, 300, 600] : [150, 80, 150]
  }));
});
self.addEventListener("notificationclick", e => {
  e.notification.close();
  const url = new URL((e.notification.data && e.notification.data.url) || "/app.html", self.location.origin).href;
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(list => {
    const app = list.find(c => { try{ return new URL(c.url).pathname === "/app.html"; }catch(_){ return false; } });
    if(app){ app.postMessage({ type: "snappro-open", url }); return app.focus(); }
    return self.clients.openWindow(url);
  }));
});
