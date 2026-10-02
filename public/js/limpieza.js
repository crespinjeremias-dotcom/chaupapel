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
