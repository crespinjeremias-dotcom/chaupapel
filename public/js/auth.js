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

// Sesion unica por dispositivo (seccion 3): al cerrar sesion se libera
// usuarios.current_session_id, si no el proximo login siempre veia el aviso
// "ya habia una sesion abierta" aunque no quedara ninguna. Solo se limpia si
// la sesion registrada es ESTA (eq current_session_id): si otra pestana/
// dispositivo se registro despues, esa sigue siendo la vigente y no se pisa.
// Es best-effort -- si falla (sin red, token vencido) el logout sigue igual,
// lo peor que pasa es un aviso de mas en el proximo login. Cerrar la pestana
// sin hacer logout tampoco lo libera; no hay forma de detectarlo.
// Sin RPC ni migracion: usuarios_update_self ya deja al usuario tocar su fila
// y prevent_privilege_escalation no controla esta columna. El super-admin no
// tiene fila en usuarios, ahi el update simplemente no afecta nada.
export async function logout() {
  try {
    const { data } = await supabase.auth.getSession();
    if (data.session) {
      const sessionId = parseJwt(data.session.access_token).session_id;
      await supabase
        .from('usuarios')
        .update({ current_session_id: null })
        .eq('id', data.session.user.id)
        .eq('current_session_id', sessionId);
    }
  } catch {
    // ver comentario arriba: no bloquea el cierre de sesion
  }
  return supabase.auth.signOut();
}

// Codigo de activacion (seccion 3): se valida ANTES del signUp para no dejar
// una cuenta de auth huerfana cuando el codigo esta mal. La barrera real es
// crear_organizacion, que lo vuelve a validar y lo consume en la misma
// transaccion -- esto es solo para avisar temprano.
export async function validarCodigoActivacion(codigo) {
  return supabase.rpc('validar_codigo_activacion', { p_codigo: codigo });
}

export async function registrarOrganizacion({ nombreNegocio, nombreAdmin, email, telefono, password, codigo }) {
  const { error: codigoError } = await validarCodigoActivacion(codigo);
  if (codigoError) return { error: codigoError };

  const { data: signUpData, error: signUpError } = await supabase.auth.signUp({ email, password });
  if (signUpError) return { error: signUpError };

  const { data, error } = await supabase.rpc('crear_organizacion', {
    p_nombre: nombreNegocio,
    p_nombre_admin: nombreAdmin,
    p_telefono: telefono || null,
    p_codigo: codigo,
  });
  return { data, error, session: signUpData.session };
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
// locales!usuarios_local_id_fkey: usuarios y locales tienen dos FKs entre si
// (usuarios.local_id y locales.eliminacion_solicitada_por); sin indicar cual,
// PostgREST rechaza el embed por ambiguo (PGRST201) y nadie puede iniciar sesion.
export async function obtenerUsuarioActual() {
  const { data: sessionData } = await supabase.auth.getSession();
  if (!sessionData.session) return null;

  const { data, error } = await supabase
    .from('usuarios')
    .select(
      'id, nombre, role, status, local_id, organization_id, organizations(nombre, plan, plan_overrides, is_active), locales!usuarios_local_id_fkey(nombre, fiado_habilitado, bloqueado_por_plan, archivado)'
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

// El local propio del empleado no se puede usar: bloqueado por el plan
// (seccion 15) o archivado por el dueno. Para el admin siempre es false --
// no tiene local propio (usuario.locales es null).
export function localNoOperable(usuario) {
  return usuario?.locales?.bloqueado_por_plan === true || usuario?.locales?.archivado === true;
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
  if (localNoOperable(usuario)) return 'panel.html';
  return usuario.role === 'empleado' ? 'ventas.html' : 'panel.html';
}
