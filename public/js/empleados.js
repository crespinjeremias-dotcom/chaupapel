import { supabase } from './supabaseClient.js';

// No incluye los locales archivados (quedan ocultos en toda la app) -- para
// verlos y restaurarlos, listarLocalesArchivados().
export async function listarLocales() {
  const { data, error } = await supabase
    .from('locales')
    .select('id, nombre, alerta_stock_email, alerta_cierre_caja_email, bloqueado_por_plan, fiado_habilitado')
    .eq('archivado', false)
    .order('nombre');
  if (error) throw error;
  return data;
}

// eliminar_en: fecha de la eliminacion definitiva si el dueno ya la programo
// (null = solo archivado). Ver programarEliminacionLocal().
export async function listarLocalesArchivados() {
  const { data, error } = await supabase.from('locales').select('id, nombre, eliminar_en').eq('archivado', true).order('nombre');
  if (error) throw error;
  return data;
}

// Archivar/restaurar van por RPC (no un update directo): la regla de "no se
// puede archivar el ultimo local activo" y el cupo del plan al restaurar
// viven en la base -- ver migracion 20260923090000. Los errores de esas
// reglas ya vienen redactados para el usuario en error.message.
export async function archivarLocal(localId) {
  const { error } = await supabase.rpc('archivar_local', { p_local_id: localId });
  if (error) throw error;
}

export async function restaurarLocal(localId) {
  const { error } = await supabase.rpc('restaurar_local', { p_local_id: localId });
  if (error) throw error;
}

// Eliminar un local archivado (migracion 20260925090000): no lo borra en el
// momento -- lo programa para dentro de 30 dias, y hasta entonces se puede
// cancelar o restaurar. El borrado real lo hace un cron en la base. El
// servidor vuelve a validar que el nombre coincida (no confia en el
// frontend). Devuelve la fecha (ISO) en la que se va a eliminar.
export async function programarEliminacionLocal(localId, nombreConfirmacion) {
  const { data, error } = await supabase.rpc('programar_eliminacion_local', {
    p_local_id: localId,
    p_nombre_confirmacion: nombreConfirmacion,
  });
  if (error) throw error;
  return data;
}

export async function cancelarEliminacionLocal(localId) {
  const { error } = await supabase.rpc('cancelar_eliminacion_local', { p_local_id: localId });
  if (error) throw error;
}

// Locales que se pueden ofrecer para trabajar ahi (seccion 15): excluye los
// bloqueados por plan (los archivados ya los excluye listarLocales()). Usar esta funcion, no listarLocales(), en cualquier
// selector de "local activo" para operar (menu.js, caja/productos/ventas/
// proveedores/clientes) -- panel.html es la unica excepcion, porque "Mis
// locales" tiene que seguir mostrando los bloqueados con su marca.
export async function listarLocalesOperables() {
  const locales = await listarLocales();
  return locales.filter((l) => !l.bloqueado_por_plan);
}

// Configuracion por local (configuracion-local.html): nombre, fiado_habilitado
// y los toggles de email (seccion 11). La RLS ya exige admin de la
// organizacion, asi que un update directo alcanza.
export async function actualizarLocal(localId, cambios) {
  const { error } = await supabase.from('locales').update(cambios).eq('id', localId);
  if (error) throw error;
}

// Alta de un local adicional (seccion 1 y 13, multi-local): la RLS ya exige
// admin de la organizacion, asi que un insert directo alcanza -- a diferencia
// del alta de la organizacion en si, esto no necesita una funcion security
// definer.
export async function crearLocal({ nombre, organizationId }) {
  const { data, error } = await supabase.from('locales').insert({ nombre, organization_id: organizationId }).select().single();
  if (error) throw error;
  return data;
}

export async function listarUsuariosOrganizacion() {
  const { data, error } = await supabase
    .from('usuarios')
    .select('id, nombre, email, role, status, local_id, locales(nombre)')
    .order('created_at', { ascending: false });
  if (error) throw error;
  return data;
}

// expira_at a 7 dias: la spec no fija una duracion para el codigo de
// invitacion, se usa el mismo numero de referencia que el trial (seccion 15).
export async function generarInvitacion({ organizationId, creadoPor, localId }) {
  const expiraAt = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString();
  const { data, error } = await supabase
    .from('invitaciones')
    .insert({
      organization_id: organizationId,
      creado_por: creadoPor,
      local_id: localId || null,
      expira_at: expiraAt,
    })
    .select('codigo, expira_at')
    .single();
  if (error) throw error;
  return data;
}

export async function aprobarEmpleado(usuarioId, localId) {
  const cambios = { status: 'approved' };
  if (localId) cambios.local_id = localId;
  const { error } = await supabase.from('usuarios').update(cambios).eq('id', usuarioId);
  if (error) throw error;
}
