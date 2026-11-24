/* worklog service worker: lets the app open without a network. Served at /sw.js (root scope) with __VERSION__ filled in.
   Network first for pages and static files, the kept copy only when the network is unreachable. Never touches /api/*,
   other methods or other origins, and a 401 or any other answer from the server is passed on as it is: a logged-out
   browser is never given a kept page. */
"use strict";
const VERSION = "__VERSION__";
const CACHE = `worklog-${VERSION}`;
const SHELLS = ["/day", "/timer", "/week", "/pomodoro", "/reports", "/days", "/settings", "/find", "/move", "/workcal"];
const ASSETS = ["core.js", "app.js", "style.css", "pomodoro.js", "week.js", "day.js", "find.js", "move.js", "workcal.js", "mdlite.js",
  "icon.svg", "icon-192.png", "manifest.webmanifest"].map((n) => `/static/${n}?v=${VERSION}`);

// keep what is already there: pages are only added when the server answers 200 for them
async function remember(cache, url) {
  try {
    const res = await fetch(url, { credentials: "same-origin" });
    if (res.ok && !res.redirected) await cache.put(url, res);
  } catch (_) { /* offline or logged out: nothing to keep */ }
}

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE).then((cache) => Promise.all([...ASSETS, ...SHELLS].map((u) => remember(cache, u)))).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (event) => {
  event.waitUntil(caches.keys()
    .then((keys) => Promise.all(keys.filter((k) => k.startsWith("worklog-") && k !== CACHE).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  if (url.pathname.startsWith("/api/") || url.pathname === "/sw.js" || url.pathname === "/healthz") return;
  if (!(req.mode === "navigate" || url.pathname.startsWith("/static/"))) return;
  event.respondWith((async () => {
    try {
      const res = await fetch(req);
      if (res.ok && !res.redirected && res.status === 200) {
        const copy = res.clone();
        caches.open(CACHE).then((c) => c.put(req.mode === "navigate" ? url.pathname + url.search : req, copy)).catch(() => {});
      }
      return res; // any answer, a 401 included, is the server's
    } catch (_) {
      const cache = await caches.open(CACHE);
      const hit = await cache.match(req.mode === "navigate" ? url.pathname + url.search : req)
        || (req.mode === "navigate" ? await cache.match(url.pathname) : await cache.match(req, { ignoreSearch: true }));
      if (hit) return hit;
      return new Response("Offline, and this page was never opened here before.", { status: 503, headers: { "content-type": "text/plain; charset=utf-8" } });
    }
  })());
});
