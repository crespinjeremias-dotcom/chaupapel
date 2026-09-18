import { supabase } from './supabaseClient.js';
import { parseJwt } from './utils.js';

export async function login(email, password) {
  return supabase.auth.signInWithPassword({ email, password });
}

// Seccion 3: sesion unica por dispositivo. Se llama despues de un login
// exitoso. Devuelve true si habia otra sesion activa distinta a esta.
export async function registrarSesionActual() {
  const { data } = await supabase.auth.getSession();
  const sessionId = parseJwt(data.session.access_token).session_id;
  const { data: huboSesionPrevia, error } = await supabase.rpc('registrar_sesion', {
    p_session_id: sessionId,
  });
  if (error) throw error;
  return huboSesionPrevia;
}

export async function cerrarSesionesAnteriores() {
  return supabase.auth.signOut({ scope: 'others' });
}

export async function logout() {
  return supabase.auth.signOut();
}

export async function registrarOrganizacion({ nombreNegocio, nombreAdmin, email, telefono, password }) {
  const { data: signUpData, error: signUpError } = await supabase.auth.signUp({ email, password });
  if (signUpError) return { error: signUpError };

  const { data, error } = await supabase.rpc('crear_organizacion', {
    p_nombre: nombreNegocio,
    p_nombre_admin: nombreAdmin,
    p_telefono: telefono || null,
  });

  // crear_organizacion() esta declarada "returns table(...)" -- PostgREST
  // siempre devuelve eso como un array (una fila en este caso), no un objeto
  // suelto.
  const organizationId = data?.[0]?.organization_id;

  // Best-effort: si el aviso al super-admin falla, la organizacion ya quedo
  // creada igual (solo pendiente de aprobacion) -- no tiene sentido hacer
  // fallar el registro por esto. No se espera con await bloqueante: el envio
  // corre en paralelo, el error (si hay) solo se loguea en la consola.
  if (!error && organizationId && signUpData.session) {
    notificarOrganizacionNueva(organizationId, signUpData.session.access_token).catch((err) =>
      console.error('No se pudo avisar de la organización nueva:', err)
    );
  }

  return { data, error, session: signUpData.session };
}

async function notificarOrganizacionNueva(organizationId, accessToken) {
  const resp = await fetch('/.netlify/functions/notificar-organizacion-nueva', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${accessToken}` },
    body: JSON.stringify({ organizationId }),
  });
  if (!resp.ok) {
    const data = await resp.json().catch(() => ({}));
    throw new Error(data.error || `Resp ${resp.status}`);
  }
}

export async function redimirInvitacion({ codigo, nombre, telefono, email, password }) {
  const { data: signUpData, error: signUpError } = await supabase.auth.signUp({ email, password });
  if (signUpError) return { error: signUpError };

  const { data, error } = await supabase.rpc('redimir_invitacion', {
    p_codigo: codigo,
    p_nombre: nombre,
    p_telefono: telefono || null,
  });
  return { data, error, session: signUpData.session };
}

export async function solicitarRecuperacion(email) {
  const redirectTo = new URL('restablecer.html', window.location.href).toString();
  return supabase.auth.resetPasswordForEmail(email, { redirectTo });
}

export async function actualizarPassword(nuevaPassword) {
  return supabase.auth.updateUser({ password: nuevaPassword });
}

// Trae la fila de usuarios + organizations del usuario logueado. Usado por
// las paginas que necesitan mostrar datos reales (panel) o decidir si
// redirigir al login.
export async function obtenerUsuarioActual() {
  const { data: sessionData } = await supabase.auth.getSession();
  if (!sessionData.session) return null;

  const { data, error } = await supabase
    .from('usuarios')
    .select(
      'id, nombre, role, status, local_id, organization_id, organizations(nombre, plan, plan_overrides, is_active, estado_aprobacion), locales(nombre, fiado_habilitado, bloqueado_por_plan)'
    )
    .eq('id', sessionData.session.user.id)
    .maybeSingle();

  if (error) throw error;
  return data;
}

// Super-Admin (seccion 16, Fase 15): identidad separada de organizations/
// usuarios -- se chequea aparte, antes de asumir que el usuario logueado
// tiene una fila en `usuarios`. Null para cualquier cuenta normal.
export async function obtenerSuperAdminActual() {
  const { data: sessionData } = await supabase.auth.getSession();
  if (!sessionData.session) return null;

  const { data, error } = await supabase
    .from('super_admins')
    .select('id, nombre')
    .eq('id', sessionData.session.user.id)
    .maybeSingle();
  if (error) throw error;
  return data;
}

// Access token de la sesion actual, para llamar a Netlify Functions que
// necesitan el JWT del usuario logueado (ej. notificar-cierre-caja).
export async function obtenerAccessToken() {
  const { data } = await supabase.auth.getSession();
  return data.session?.access_token || null;
}

// Guard simple para paginas que requieren sesion iniciada.
export async function requireSession() {
  const { data } = await supabase.auth.getSession();
  if (!data.session) {
    window.location.href = 'index.html';
    return null;
  }
  return data.session;
}

// A donde va cada quien despues de iniciar sesion (no despues de registrarse
// -- un admin recien creado o un empleado pending siguen yendo a panel.html,
// que ya maneja esos estados). Empleado entra directo al punto de venta;
// admin al dashboard general. pending/organizacion suspendida siempre van a
// panel.html, que ya tiene los mensajes correspondientes para esos casos.
export function pantallaDeEntrada(usuario) {
  if (!usuario) return 'index.html';
  if (usuario.status !== 'approved') return 'panel.html';
  if (usuario.organizations?.is_active === false) return 'panel.html';
  if (usuario.organizations?.estado_aprobacion && usuario.organizations.estado_aprobacion !== 'aprobada') return 'panel.html';
  if (usuario.locales?.bloqueado_por_plan === true) return 'panel.html';
  return usuario.role === 'empleado' ? 'ventas.html' : 'panel.html';
}
