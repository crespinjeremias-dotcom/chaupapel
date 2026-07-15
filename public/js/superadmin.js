import { supabase } from './supabaseClient.js';

// Solicitudes de cambio de plan pendientes, de todas las organizaciones
// (is_super_admin() en la policy de solicitudes_cambio_plan es lo que
// permite ver mas alla de la propia organizacion).
export async function listarSolicitudesPendientes() {
  const { data, error } = await supabase
    .from('solicitudes_cambio_plan')
    .select('*, organizations(nombre)')
    .eq('estado', 'pendiente')
    .order('created_at', { ascending: true });
  if (error) throw error;
  return data;
}

export async function listarHistorialSolicitudes() {
  const { data, error } = await supabase
    .from('solicitudes_cambio_plan')
    .select('*, organizations(nombre)')
    .neq('estado', 'pendiente')
    .order('resuelta_at', { ascending: false })
    .limit(50);
  if (error) throw error;
  return data;
}

// aprobar/rechazar van por RPC (security definer) para que el cambio real de
// organizations.plan y el estado de la solicitud queden atomicos -- ver
// migracion 20260717080100_solicitudes_cambio_plan.sql.
export async function aprobarSolicitud(id) {
  const { error } = await supabase.rpc('aprobar_solicitud_plan', { p_solicitud_id: id });
  if (error) throw error;
}

export async function rechazarSolicitud(id) {
  const { error } = await supabase.rpc('rechazar_solicitud_plan', { p_solicitud_id: id });
  if (error) throw error;
}

// Listado de todas las organizaciones: esto SI se puede leer directo con
// RLS (policy organizations_select_superadmin), no hace falta la Netlify
// Function -- esa function solo hace falta para escribir is_active.
export async function listarOrganizaciones() {
  const { data, error } = await supabase.from('organizations').select('id, nombre, plan, is_active, created_at').order('nombre');
  if (error) throw error;
  return data;
}

// activar/desactivar si pasa por la Netlify Function: es la unica columna
// que el trigger prevent_is_active_change bloquea salvo con la service role
// key (ver netlify/functions/toggle-organizacion.js).
export async function alternarOrganizacionActiva(organizationId, activo) {
  const { data: sessionData } = await supabase.auth.getSession();
  const token = sessionData.session?.access_token;
  const resp = await fetch('/.netlify/functions/toggle-organizacion', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    body: JSON.stringify({ organizationId, activo }),
  });
  const data = await resp.json().catch(() => ({}));
  if (!resp.ok) throw new Error(data.error || 'No se pudo actualizar la organización.');
  return data;
}
