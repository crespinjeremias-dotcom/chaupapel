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

// Instalacion como PWA de escritorio (Chrome/Edge -- Firefox y Safari no
// disparan beforeinstallprompt, ahi simplemente no aparece el boton).
// beforeinstallprompt puede disparar antes de que el boton que lo muestra
// exista (ese boton se arma recien adentro del menu, despues de validar la
// sesion) -- por eso esta funcion se llama aparte y bien temprano, en el
// mismo script inline que ya registra el service worker en cada pagina, y
// guarda el evento en una variable de modulo hasta que haya un boton
// conectado.
let promptDiferido = null;
let yaInstalada = false;

export function escucharPromptInstalacion() {
  window.addEventListener('beforeinstallprompt', (e) => {
    e.preventDefault();
    promptDiferido = e;
    document.dispatchEvent(new CustomEvent('chaupapel:instalable'));
  });
  window.addEventListener('appinstalled', () => {
    yaInstalada = true;
    promptDiferido = null;
    document.dispatchEvent(new CustomEvent('chaupapel:instalada'));
  });
}

// Conecta un boton "Instalar app" ya existente en el DOM. `contenedor` es el
// elemento a mostrar/ocultar (por defecto el boton mismo; en el menu es el
// <li> que lo envuelve, para no dejar un hueco vacio en la lista).
export function conectarBotonInstalar(boton, contenedor = boton) {
  if (!boton || !contenedor) return;

  if (window.matchMedia('(display-mode: standalone)').matches || yaInstalada) {
    contenedor.hidden = true;
    return;
  }

  contenedor.hidden = !promptDiferido;
  document.addEventListener('chaupapel:instalable', () => {
    contenedor.hidden = false;
  });
  document.addEventListener('chaupapel:instalada', () => {
    contenedor.hidden = true;
  });

  boton.addEventListener('click', async () => {
    if (!promptDiferido) return;
    boton.disabled = true;
    promptDiferido.prompt();
    await promptDiferido.userChoice;
    promptDiferido = null;
    contenedor.hidden = true;
    boton.disabled = false;
  });
}
