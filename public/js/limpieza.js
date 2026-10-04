import { supabase } from './supabaseClient.js';

// Organizaciones candidatas a borrar (panel de super-admin, seccion 16).
// Trae cobro_habilitado y si ya tiene cobros registrados (embed de
// cobros(id), solo para contar) para poder bloquear del lado del cliente
// las que no se pueden borrar -- eliminar_organizacion_de_prueba() igual
// revalida esto mismo por su cuenta antes de tocar nada.
export async function listarOrganizacionesParaLimpieza() {
  const { data, error } = await supabase
    .from('organizations')
    .select('id, nombre, created_at, cobro_habilitado, cobros(id)')
    .order('created_at', { ascending: false });
  if (error) throw error;
  return data.map((o) => ({
    id: o.id,
    nombre: o.nombre,
    created_at: o.created_at,
    cobro_habilitado: o.cobro_habilitado,
    tieneCobros: (o.cobros || []).length > 0,
  }));
}

// Pasa por la Netlify Function porque el ultimo paso (borrar el usuario de
// Supabase Auth) necesita la service role key -- el borrado de los datos en
// si lo hace la RPC, llamada ahi con el JWT de quien esta logueado.
export async function eliminarOrganizacionDePrueba(organizationId) {
  const { data: sessionData } = await supabase.auth.getSession();
  const token = sessionData.session?.access_token;
  const resp = await fetch('/.netlify/functions/eliminar-organizacion', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    body: JSON.stringify({ organizationId }),
  });
  const data = await resp.json().catch(() => ({}));
  if (!resp.ok) throw new Error(data.error || 'No se pudo eliminar la organización.');
  return data;
}

// Locales de prueba (borrado inmediato, solo super-admin). El super-admin no
// tiene policy de select sobre `locales`, asi que el listado va por una RPC;
// eliminar_local_ahora() revalida todo del lado del servidor (super-admin, sin
// cobro, que no sea el unico local operable) antes de borrar.
export async function listarLocalesParaLimpieza() {
  const { data, error } = await supabase.rpc('listar_locales_para_limpieza');
  if (error) throw error;
  return data.map((l) => ({
    id: l.local_id,
    nombre: l.local_nombre,
    organizationId: l.organization_id,
    organizacion: l.organizacion_nombre,
    archivado: l.archivado,
    eliminarEn: l.eliminar_en,
    cobro_habilitado: l.cobro_habilitado,
    tieneCobros: l.tiene_cobros,
  }));
}

export async function eliminarLocalAhora(localId) {
  const { data, error } = await supabase.rpc('eliminar_local_ahora', { p_local_id: localId });
  if (error) throw error;
  return data;
}
