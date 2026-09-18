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
  const { data, error } = await supabase
    .from('organizations')
    .select('id, nombre, plan, is_active, estado_aprobacion, created_at')
    .order('nombre');
  if (error) throw error;
  return data;
}

// Organizaciones nuevas pendientes de aprobacion (seccion 16). Se hacen dos
// consultas en vez de un embed (organizations -> usuarios es de a muchos, y
// el embed inverso de PostgREST complica el filtro por role=admin) y se
// mezclan en JS -- mas simple. usuarios_select_superadmin (nueva policy) es
// lo que permite leer usuarios de cualquier organizacion desde este panel.
export async function listarOrganizacionesPendientesAprobacion() {
  const { data: orgs, error } = await supabase
    .from('organizations')
    .select('id, nombre, created_at')
    .eq('estado_aprobacion', 'pendiente')
    .order('created_at', { ascending: true });
  if (error) throw error;
  if (orgs.length === 0) return [];

  const { data: admins, error: adminsError } = await supabase
    .from('usuarios')
    .select('organization_id, nombre, email')
    .eq('role', 'admin')
    .in('organization_id', orgs.map((o) => o.id));
  if (adminsError) throw adminsError;

  return orgs.map((o) => ({ ...o, admin: admins.find((a) => a.organization_id === o.id) || null }));
}

// aprobar/rechazar via RPC (security definer) -- mismo patron que
// aprobar_solicitud_plan/rechazar_solicitud_plan, nunca un UPDATE directo
// (ver prevent_estado_aprobacion_change_directo).
export async function aprobarOrganizacion(id) {
  const { error } = await supabase.rpc('aprobar_organizacion', { p_organization_id: id });
  if (error) throw error;
}

export async function rechazarOrganizacion(id) {
  const { error } = await supabase.rpc('rechazar_organizacion', { p_organization_id: id });
  if (error) throw error;
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
