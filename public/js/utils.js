export function parseJwt(token) {
  const payload = token.split('.')[1];
  const json = decodeURIComponent(
    atob(payload.replace(/-/g, '+').replace(/_/g, '/'))
      .split('')
      .map((c) => '%' + c.charCodeAt(0).toString(16).padStart(2, '0'))
      .join('')
  );
  return JSON.parse(json);
}

const ESCAPES_HTML = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };

// Los nombres de producto/categoria/cliente/usuario los escribe el usuario y
// se insertan via innerHTML en varias pantallas -- hay que escaparlos.
export function escapeHtml(texto) {
  return String(texto ?? '').replace(/[&<>"']/g, (c) => ESCAPES_HTML[c]);
}

// Cantidad cargada contra un producto (venta, ajuste, reposicion,
// devolucion): valida el texto tal cual lo escribio el usuario. No usar
// Number()/parseFloat() para esto -- son demasiado permisivos (Number('') es
// 0, no NaN; parseFloat('1,5') es 1, no un error) y type="number" no
// bloquea de forma confiable comas o texto invalido en todos los
// navegadores/mobile (el valor puede llegar como '' aunque el usuario haya
// tipeado algo). Devuelve null si no es valido -- nunca "corrige" en
// silencio un valor que no se pueda interpretar con certeza.
export function parseCantidad(texto, permiteDecimal) {
  const valor = String(texto ?? '').trim();
  if (permiteDecimal) {
    if (!/^\d+(\.\d+)?$/.test(valor)) return null;
  } else if (!/^[1-9]\d*$/.test(valor)) {
    return null;
  }
  const n = Number(valor);
  return n > 0 ? n : null;
}

export function mostrarError(el, mensaje) {
  el.textContent = mensaje;
  el.hidden = !mensaje;
}

export function mostrarCargando(boton, cargando, textoNormal) {
  boton.disabled = cargando;
  boton.textContent = cargando ? 'Un momento...' : textoNormal;
}

const MENSAJES_ERROR = {
  'Invalid login credentials': 'Email o contraseña incorrectos.',
  'User already registered': 'Ya existe una cuenta con ese email.',
  'Email not confirmed': 'Falta confirmar el email. Revisá tu casilla.',
};

export function traducirError(error) {
  if (!error) return '';
  if (error.code === 'email_address_invalid') return 'Ese email no parece válido. Revisá que esté bien escrito.';
  return MENSAJES_ERROR[error.message] || error.message;
}
