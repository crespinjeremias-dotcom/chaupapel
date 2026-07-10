import { supabase } from './supabaseClient.js';

export async function listarLocales() {
  const { data, error } = await supabase.from('locales').select('id, nombre').order('nombre');
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
