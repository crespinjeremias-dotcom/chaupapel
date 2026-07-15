// Multi-local (seccion 1 y 13): el admin puede tener mas de un local. Antes
// de esto, cada pantalla admin operaba siempre sobre locales[0] sin forma de
// elegir -- esto guarda la eleccion en localStorage para que persista entre
// paginas (no es informacion sensible, es solo una preferencia de UI local
// al dispositivo).
const CLAVE = 'chaupapel_local_activo';

export function obtenerLocalActivo(locales) {
  if (!locales || locales.length === 0) return null;
  const guardado = localStorage.getItem(CLAVE);
  if (guardado && locales.some((l) => l.id === guardado)) return guardado;
  const primero = locales[0].id;
  localStorage.setItem(CLAVE, primero);
  return primero;
}

export function establecerLocalActivo(localId) {
  localStorage.setItem(CLAVE, localId);
}
