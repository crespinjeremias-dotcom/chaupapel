import { supabase } from './supabaseClient.js';

export async function listarLocales() {
  const { data, error } = await supabase
    .from('locales')
    .select('id, nombre, alerta_stock_email, alerta_cierre_caja_email, bloqueado_por_plan, activo')
    .order('nombre');
  if (error) throw error;
  return data;
}

// Locales que se pueden ofrecer para trabajar ahi (seccion 15 y 1/13):
// excluye los bloqueados por plan y los archivados. Usar esta funcion, no
// listarLocales(), en cualquier selector de "local activo" para operar
// (menu.js, caja/productos/ventas/proveedores/clientes) -- panel.html es la
// unica excepcion, porque "Mis locales" tiene que seguir mostrando los
// bloqueados/archivados con su marca.
export async function listarLocalesOperables() {
  const locales = await listarLocales();
  return locales.filter((l) => !l.bloqueado_por_plan && l.activo);
}

// Archivar/desarchivar un local (seccion 1/13): reversible, a diferencia de
// bloqueado_por_plan que se recalcula solo. Un UPDATE directo alcanza (RLS
// ya exige admin de la organizacion) -- la restriccion de no poder archivar
// el ultimo local operable la valida el trigger validar_archivado_local en
// la base, no hace falta duplicarla aca.
export async function alternarArchivadoLocal(localId, activo) {
  const { error } = await supabase.from('locales').update({ activo }).eq('id', localId);
  if (error) throw error;
}

// Toggles de email por local (seccion 11): el admin los prende/apaga desde
// "Mis locales" en panel.html, gateados alli por el mismo tieneFeature que
// el resto del panel.
export async function actualizarAlertasEmailLocal(localId, cambios) {
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
