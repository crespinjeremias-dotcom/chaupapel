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
