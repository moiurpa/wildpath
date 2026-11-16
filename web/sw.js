// WildPath service worker: lets the app open with no signal.
// Network first, so updates show right away; the saved copy is used only when offline.
// Only this site's own files are saved. Google Maps and report uploads are never cached.
const CACHE = "wildpath-v2";
const CORE = ["./", "index.html", "app.css", "app.js", "config.js", "vendor/leaflet.js", "vendor/leaflet.css",
  "data/hotspot-segments.json", "data/demo-reports.json", "manifest.json", "icons/icon-192.png", "privacy.html", "terms.html", "legal.css"];

self.addEventListener("install", e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(CORE)).then(() => self.skipWaiting()));
});
self.addEventListener("activate", e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
    .then(() => self.clients.claim()));
});
self.addEventListener("fetch", e => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET" || url.origin !== location.origin || url.pathname.includes("/v1/")) return;
  e.respondWith(
    fetch(e.request).then(res => {
      if (res.ok) { const copy = res.clone(); caches.open(CACHE).then(c => c.put(e.request, copy)); }
      return res;
    }).catch(() => caches.match(e.request, { ignoreSearch: true }).then(r => r || caches.match("index.html")))
  );
});
