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
