import { supabase } from './supabaseClient.js';

// Minimo necesario para marcar una venta como fiada desde el punto de venta
// (seccion 9, Fase 5).
export async function buscarClientes(query) {
  let consulta = supabase.from('clientes').select('id, nombre, telefono, saldo').eq('activo', true).order('nombre');
  if (query) consulta = consulta.ilike('nombre', `%${query}%`);
  const { data, error } = await consulta.limit(20);
  if (error) throw error;
  return data;
}

export async function crearClienteRapido({ nombre, localId, organizationId }) {
  const { data, error } = await supabase
    .from('clientes')
    .insert({ nombre, local_id: localId, organization_id: organizationId })
    .select()
    .single();
  if (error) throw error;
  return data;
}

// Modulo de cuenta corriente (Fase 6) ---------------------------------

export async function listarClientes({ query, soloActivos = false } = {}) {
  let consulta = supabase.from('clientes').select('*').order('nombre');
  if (soloActivos) consulta = consulta.eq('activo', true);
  if (query) consulta = consulta.ilike('nombre', `%${query}%`);
  const { data, error } = await consulta;
  if (error) throw error;
  return data;
}

export async function actualizarCliente(id, datos) {
  const { data, error } = await supabase.from('clientes').update(datos).eq('id', id).select().single();
  if (error) throw error;
  return data;
}

export async function establecerActivo(id, activo) {
  const { error } = await supabase.from('clientes').update({ activo }).eq('id', id);
  if (error) throw error;
}

export async function obtenerClienteConMovimientos(id) {
  const [{ data: cliente, error: errorCliente }, { data: movimientos, error: errorMov }] = await Promise.all([
    supabase.from('clientes').select('*').eq('id', id).single(),
    supabase
      .from('cuenta_corriente_movimientos')
      .select('*, usuarios(nombre)')
      .eq('cliente_id', id)
      .order('fecha', { ascending: false }),
  ]);
  if (errorCliente) throw errorCliente;
  if (errorMov) throw errorMov;
  return { cliente, movimientos };
}

// Cobro de fiado (seccion 9): "el pago se carga como ingreso del dia en que
// se cobra, con su metodo de pago" -- por eso exige un turno abierto, igual
// que una venta (asi js/caja.js puede sumarlo al efectivo esperado del
// turno via turno_id). El trigger de la base actualiza clientes.saldo solo.
export async function registrarCobro({ clienteId, turnoId, usuarioId, localId, organizationId, monto, metodoPago }) {
  const { error } = await supabase.from('cuenta_corriente_movimientos').insert({
    cliente_id: clienteId,
    local_id: localId,
    organization_id: organizationId,
    tipo: 'cobro_fiado',
    monto,
    turno_id: turnoId,
    metodo_pago: metodoPago,
    usuario_id: usuarioId,
  });
  if (error) throw error;
}
