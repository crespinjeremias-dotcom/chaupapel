// Registro del service worker (seccion 14 y 16). No hace nada si el
// navegador no soporta service workers -- la instalacion como app es
// opcional, nunca requisito para usar el sistema.
export function registrarServiceWorker() {
  if (!('serviceWorker' in navigator)) return;
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('sw.js').catch(() => {
      // si falla el registro (ej. sw.js no accesible en este entorno), la
      // app sigue funcionando igual, solo sin la opcion de instalar
    });
  });
}
