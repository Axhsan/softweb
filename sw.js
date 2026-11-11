const CACHE_NAME = 'sonybox-isp-v131';

const STATIC_ASSETS = [
  './',
  './index.html',
  './manifest.json',
  './recovery.html',
  './assets/images/logo-icon.svg',
  './assets/images/logo.svg',
  './assets/images/logo.png',
  'https://cdn.tailwindcss.com',
  'https://cdn.jsdelivr.net/npm/chart.js',
  'https://code.jquery.com/jquery-3.7.1.min.js',
  'https://cdnjs.cloudflare.com/ajax/libs/toastr.js/latest/toastr.min.js',
  'https://cdnjs.cloudflare.com/ajax/libs/toastr.js/latest/toastr.min.css',
  'https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.1/css/all.min.css'
];

// Pre-cache core assets
self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then(async (cache) => {
      await Promise.allSettled(
        STATIC_ASSETS.map((asset) => 
          fetch(asset, { mode: asset.startsWith('http') ? 'cors' : 'no-cors' })
            .then((res) => {
              if (res.ok || res.type === 'opaque') {
                return cache.put(asset, res);
              }
            })
            .catch((err) => console.warn('Cache prefetch failed:', asset, err))
        )
      );
    })
  );
  self.skipWaiting();
});

// Purge all old cache versions
self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) => {
      return Promise.all(
        keys.map((key) => {
          if (key !== CACHE_NAME) {
            console.log('[SW] Purging old cache:', key);
            return caches.delete(key);
          }
        })
      );
    })
  );
  self.clients.claim();
});

// High-speed caching strategies
self.addEventListener('fetch', (event) => {
  const req = event.request;
  const url = req.url;

  // 1. API Calls / Dynamic Data: Network-First with Cache fallback
  if (url.includes('/api/') || url.endsWith('.php') || url.includes('data.json')) {
    event.respondWith(
      fetch(req)
        .then((networkRes) => {
          if (networkRes && networkRes.ok) {
            const clone = networkRes.clone();
            caches.open(CACHE_NAME).then((cache) => cache.put(req, clone));
          }
          return networkRes;
        })
        .catch(() => caches.match(req))
    );
    return;
  }

  // 2. Navigation / HTML: Network-First (always fresh code when online, cache when offline)
  if (req.mode === 'navigate' || url.endsWith('.html') || url.endsWith('/')) {
    event.respondWith(
      fetch(req)
        .then((networkRes) => {
          if (networkRes && networkRes.ok) {
            const clone = networkRes.clone();
            caches.open(CACHE_NAME).then((cache) => cache.put(req, clone));
          }
          return networkRes;
        })
        .catch(() => caches.match(req).then(cached => cached || caches.match('./index.html')))
    );
    return;
  }

  // 3. Static Assets, CDN Scripts, Fonts, Images: Cache-First
  event.respondWith(
    caches.match(req).then((cachedRes) => {
      if (cachedRes) return cachedRes;

      return fetch(req)
        .then((networkRes) => {
          if (networkRes && (networkRes.ok || networkRes.type === 'opaque')) {
            const clone = networkRes.clone();
            caches.open(CACHE_NAME).then((cache) => cache.put(req, clone));
          }
          return networkRes;
        })
        .catch(() => cachedRes);
    })
  );
});
