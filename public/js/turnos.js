import { supabase } from './supabaseClient.js';

// El turno abierto del usuario actual (login y apertura de turno son dos
// pasos separados, seccion 3). El cierre con conteo de efectivo vive en
// js/caja.js (cerrarTurnoConConteo) -- este modulo solo abre y consulta.
export async function obtenerTurnoAbierto(usuarioId) {
  const { data, error } = await supabase
    .from('turnos')
    .select('*')
    .eq('usuario_id', usuarioId)
    .eq('estado', 'abierto')
    .order('fecha_apertura', { ascending: false })
    .limit(1)
    .maybeSingle();
  if (error) throw error;
  return data;
}

export async function abrirTurno({ localId, organizationId, usuarioId }) {
  const { data, error } = await supabase
    .from('turnos')
    .insert({ local_id: localId, organization_id: organizationId, usuario_id: usuarioId })
    .select()
    .single();
  if (error) throw error;
  return data;
}

