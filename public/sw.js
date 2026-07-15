// Service worker minimo (seccion 14 y 16): la instalacion como app es una
// comodidad opcional, no un modo offline-first. Estrategia "network-first"
// a proposito -- este proyecto ya se comio un bug entero de cache de
// navegador sirviendo JS viejo durante el desarrollo, asi que la prioridad
// es nunca servir algo desactualizado mientras haya conexion. El cache solo
// entra en juego si la red falla (sin conexion).
const CACHE_NAME = 'chaupapel-shell-v1';

self.addEventListener('install', (event) => {
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((nombres) => Promise.all(nombres.filter((n) => n !== CACHE_NAME).map((n) => caches.delete(n))))
  );
  self.clients.claim();
});

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);

  // Solo intercepta GET del mismo origen -- deja pasar directo a la red
  // cualquier llamada a Supabase o a un CDN externo (esm.sh, jsdelivr).
  if (event.request.method !== 'GET' || url.origin !== self.location.origin) return;

  event.respondWith(
    fetch(event.request)
      .then((respuesta) => {
        const copia = respuesta.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(event.request, copia));
        return respuesta;
      })
      .catch(() => caches.match(event.request))
  );
});
