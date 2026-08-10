/* icon4me — offline support.
   Bump CACHE when you change files, or just push: index.html is network-first
   so a new deploy is picked up on the next launch that has signal. */
const CACHE = 'icon4me-v4_3';
/* The exercise animations get their own cache: ~5MB that never changes, and
   that must survive a code deploy — the gym is where the signal dies. */
const DEMOS = 'icon4me-demos';
const ASSETS = [
  './', './index.html', './config.js', './manifest.webmanifest',
  './icon-192.png', './icon-512.png',
  './icon-192-maskable.png', './icon-512-maskable.png',
  './apple-touch-icon.png', './favicon-32.png',
  './lifter.svg'
];

self.addEventListener('install', e => {
  e.waitUntil(
    caches.open(CACHE)
      .then(c => Promise.all(ASSETS.map(u => c.add(u).catch(() => {}))))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== CACHE && k !== DEMOS).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;

  let url;
  try { url = new URL(req.url); } catch (err) { return; }

  // Exercise animations: cache first, in their own bucket, forever.
  if (url.pathname.endsWith('.gif')) {
    e.respondWith(
      caches.match(req).then(hit => hit || fetch(req).then(resp => {
        if (resp && resp.status === 200) {
          const c = resp.clone();
          caches.open(DEMOS).then(x => x.put(req, c));
        }
        return resp;
      }).catch(() => new Response('', {status: 504, statusText: 'offline'})))
    );
    return;
  }

  // Never touch Supabase traffic — it must always hit the network.
  if (url.hostname.indexOf('supabase.co') >= 0) return;

  // The page itself: network first, cache as a fallback when offline.
  if (req.mode === 'navigate' || url.pathname.endsWith('/index.html')) {
    e.respondWith(
      fetch(req)
        .then(r => { const c = r.clone(); caches.open(CACHE).then(x => x.put('./index.html', c)); return r; })
        .catch(() => caches.match('./index.html').then(r => r || caches.match('./')))
    );
    return;
  }

  // Everything else: cache first, then network, and remember what we fetch.
  e.respondWith(
    caches.match(req).then(hit => hit || fetch(req).then(resp => {
      const ok = resp && (resp.status === 200 || resp.type === 'opaque');
      const cacheable = url.origin === self.location.origin ||
        /jsdelivr|gstatic|googleapis/.test(url.hostname);
      if (ok && cacheable) { const c = resp.clone(); caches.open(CACHE).then(x => x.put(req, c)); }
      return resp;
    }).catch(() => new Response('', {status: 504, statusText: 'offline'})))
  );
});
