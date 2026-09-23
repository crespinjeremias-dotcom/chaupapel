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

// Codigos de activacion para crear organizaciones nuevas (seccion 3). Se
// administran directo con RLS (is_super_admin() en las policies de
// codigos_activacion), sin Netlify Function. Se guardan normalizados (sin
// guion); formatearCodigo() es solo para mostrarlos.
const ALFABETO_CODIGO = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // 32 simbolos, sin I/O/0/1 que se confunden
const LARGO_CODIGO = 10;

export function formatearCodigo(codigo) {
  return `${codigo.slice(0, 5)}-${codigo.slice(5)}`;
}

// 32 simbolos dividen 256 exacto: sin sesgo al tomar el byte modulo 32.
function generarCodigoAleatorio() {
  const bytes = crypto.getRandomValues(new Uint8Array(LARGO_CODIGO));
  return Array.from(bytes, (b) => ALFABETO_CODIGO[b % ALFABETO_CODIGO.length]).join('');
}

export function estadoCodigo(c) {
  if (c.revocado) return 'revocado';
  if (c.usos >= c.max_usos) return 'usado';
  if (c.expira_at && new Date(c.expira_at) < new Date()) return 'vencido';
  return 'disponible';
}

export async function listarCodigosActivacion() {
  const { data, error } = await supabase
    .from('codigos_activacion')
    .select('*, organizations(nombre)')
    .order('created_at', { ascending: false });
  if (error) throw error;
  return data;
}

// diasVencimiento: 30 por defecto, null = no vence.
export async function generarCodigoActivacion({ nota, diasVencimiento = 30, maxUsos = 1, creadoPor }) {
  const expiraAt = diasVencimiento ? new Date(Date.now() + diasVencimiento * 24 * 60 * 60 * 1000).toISOString() : null;
  // El unique de codigo hace casi imposible una colision (50 bits), pero si
  // pasa se reintenta en vez de mostrar un error incomprensible.
  for (let intento = 0; intento < 3; intento++) {
    const { data, error } = await supabase
      .from('codigos_activacion')
      .insert({ codigo: generarCodigoAleatorio(), nota: nota || null, max_usos: maxUsos, expira_at: expiraAt, creado_por: creadoPor })
      .select()
      .single();
    if (!error) return data;
    if (error.code !== '23505') throw error;
  }
  throw new Error('No se pudo generar un código único. Probá de nuevo.');
}

export async function revocarCodigoActivacion(id) {
  const { error } = await supabase.from('codigos_activacion').update({ revocado: true }).eq('id', id);
  if (error) throw error;
}
