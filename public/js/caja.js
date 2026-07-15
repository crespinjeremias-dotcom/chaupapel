import { supabase } from './supabaseClient.js';

function sumar(arr, campo) {
  return arr.reduce((acc, r) => acc + Number(r[campo]), 0);
}

function limitesDelDia(fechaStr) {
  const base = fechaStr ? new Date(fechaStr + 'T00:00:00') : new Date();
  const desde = new Date(base.getFullYear(), base.getMonth(), base.getDate());
  const hasta = new Date(desde);
  hasta.setDate(hasta.getDate() + 1);
  return { desde, hasta };
}

function limitesDelMes(anio, mes) {
  return { desde: new Date(anio, mes - 1, 1), hasta: new Date(anio, mes, 1) };
}

// Efectivo/transferencia esperados de un turno (seccion 10): ventas cobradas
// en ese turno + cobros de fiado registrados durante ese turno (ver nota en
// cuenta_corriente_movimientos.turno_id). El fiado nuevo generado se muestra
// aparte, informativo -- no entra en el conteo de efectivo (seccion 9).
export async function calcularEsperadoTurno(turnoId) {
  const [{ data: pagos, error: errorPagos }, { data: cobros, error: errorCobros }, { data: ventasFiado, error: errorFiado }] = await Promise.all([
    supabase
      .from('venta_pagos')
      .select('metodo, monto, ventas!inner(turno_id, estado)')
      .eq('ventas.turno_id', turnoId)
      .neq('ventas.estado', 'anulada'),
    supabase.from('cuenta_corriente_movimientos').select('metodo_pago, monto').eq('tipo', 'cobro_fiado').eq('turno_id', turnoId),
    supabase.from('ventas').select('total').eq('turno_id', turnoId).eq('es_fiado', true).neq('estado', 'anulada'),
  ]);
  if (errorPagos) throw errorPagos;
  if (errorCobros) throw errorCobros;
  if (errorFiado) throw errorFiado;

  const efectivo = sumar(pagos.filter((p) => p.metodo === 'efectivo'), 'monto') + sumar(cobros.filter((c) => c.metodo_pago === 'efectivo'), 'monto');
  const transferencia =
    sumar(pagos.filter((p) => p.metodo === 'transferencia'), 'monto') + sumar(cobros.filter((c) => c.metodo_pago === 'transferencia'), 'monto');
  const fiadoGenerado = sumar(ventasFiado, 'total');

  return { efectivoEsperado: efectivo, transferenciaEsperada: transferencia, fiadoGenerado };
}

// Cierra el turno con el conteo real de efectivo (seccion 10, paso 3-4): la
// diferencia queda registrada para que el admin la vea, pero no bloquea el
// cierre -- contar mal no es un error del sistema.
export async function cerrarTurnoConConteo(turnoId, efectivoContado) {
  const { efectivoEsperado, transferenciaEsperada } = await calcularEsperadoTurno(turnoId);
  const diferencia = Number(efectivoContado) - efectivoEsperado;

  const { error } = await supabase
    .from('turnos')
    .update({
      estado: 'cerrado',
      fecha_cierre: new Date().toISOString(),
      efectivo_esperado: efectivoEsperado,
      efectivo_contado: Number(efectivoContado),
      transferencia_esperada: transferenciaEsperada,
      diferencia,
    })
    .eq('id', turnoId);
  if (error) throw error;

  return { efectivoEsperado, transferenciaEsperada, efectivoContado: Number(efectivoContado), diferencia };
}

// Turnos de un local en un dia puntual (vista de caja del admin).
export async function listarTurnosDelDia(localId, fechaStr) {
  const { desde, hasta } = limitesDelDia(fechaStr);
  const { data, error } = await supabase
    .from('turnos')
    .select('*, usuarios(nombre)')
    .eq('local_id', localId)
    .gte('fecha_apertura', desde.toISOString())
    .lt('fecha_apertura', hasta.toISOString())
    .order('fecha_apertura');
  if (error) throw error;
  return data;
}

// Cierre consolidado del dia (seccion 10): agrega los turnos ya cerrados de
// ese local+fecha. Exige que no quede ningun turno abierto -- si alguien se
// olvido de cerrar su turno, se avisa en vez de cerrar el dia con un hueco.
export async function cerrarCajaDelDia({ localId, organizationId, fechaStr, usuarioId }) {
  const turnos = await listarTurnosDelDia(localId, fechaStr);
  if (turnos.length === 0) throw new Error('No hay turnos cargados ese día para este local.');
  if (turnos.some((t) => t.estado === 'abierto')) {
    throw new Error('Todavía hay un turno abierto ese día. Tiene que estar cerrado para poder cerrar la caja del día.');
  }

  const { desde, hasta } = limitesDelDia(fechaStr);
  const { data: ventasFiado, error: errorFiado } = await supabase
    .from('ventas')
    .select('total')
    .eq('local_id', localId)
    .eq('es_fiado', true)
    .neq('estado', 'anulada')
    .gte('fecha', desde.toISOString())
    .lt('fecha', hasta.toISOString());
  if (errorFiado) throw errorFiado;
  const fiadoNuevoTotal = sumar(ventasFiado, 'total');

  const efectivoEsperadoTotal = sumar(turnos, 'efectivo_esperado');
  const efectivoContadoTotal = sumar(turnos, 'efectivo_contado');
  const transferenciaTotal = sumar(turnos, 'transferencia_esperada');
  const diferenciaTotal = sumar(turnos, 'diferencia');

  const { error } = await supabase.from('cierres_diarios').upsert(
    {
      local_id: localId,
      organization_id: organizationId,
      fecha: desde.toISOString().slice(0, 10),
      efectivo_esperado_total: efectivoEsperadoTotal,
      efectivo_contado_total: efectivoContadoTotal,
      transferencia_total: transferenciaTotal,
      fiado_nuevo_total: fiadoNuevoTotal,
      diferencia_total: diferenciaTotal,
      estado: 'cerrado',
      cerrado_por: usuarioId,
      cerrado_at: new Date().toISOString(),
    },
    { onConflict: 'local_id,fecha' }
  );
  if (error) throw error;
}

export async function listarCierresDiarios(localId) {
  const { data, error } = await supabase.from('cierres_diarios').select('*').eq('local_id', localId).order('fecha', { ascending: false });
  if (error) throw error;
  return data;
}

// Mismos totales que el resumen del dashboard (js/dashboard.js), pero
// acotados a un local puntual -- se usa tanto para la vista previa como
// para lo que efectivamente se persiste al cerrar el mes.
export async function calcularResumenMes(localId, anio, mes) {
  const { desde, hasta } = limitesDelMes(anio, mes);

  const [{ data: ventas, error: errorVentas }, { data: pagos, error: errorPagos }, { data: cobros, error: errorCobros }, { data: reposiciones, error: errorReposiciones }] =
    await Promise.all([
      supabase.from('ventas').select('total').eq('local_id', localId).gte('fecha', desde.toISOString()).lt('fecha', hasta.toISOString()).neq('estado', 'anulada'),
      supabase
        .from('venta_pagos')
        .select('monto, ventas!inner(fecha, estado, local_id)')
        .eq('ventas.local_id', localId)
        .gte('ventas.fecha', desde.toISOString())
        .lt('ventas.fecha', hasta.toISOString())
        .neq('ventas.estado', 'anulada'),
      supabase
        .from('cuenta_corriente_movimientos')
        .select('monto')
        .eq('local_id', localId)
        .eq('tipo', 'cobro_fiado')
        .gte('fecha', desde.toISOString())
        .lt('fecha', hasta.toISOString()),
      supabase.from('reposiciones_stock').select('cantidad, precio_costo').eq('local_id', localId).gte('fecha', desde.toISOString()).lt('fecha', hasta.toISOString()),
    ]);
  if (errorVentas) throw errorVentas;
  if (errorPagos) throw errorPagos;
  if (errorCobros) throw errorCobros;
  if (errorReposiciones) throw errorReposiciones;

  const { data: clientes, error: errorClientes } = await supabase.from('clientes').select('saldo').eq('local_id', localId).eq('activo', true);
  if (errorClientes) throw errorClientes;

  const totalVendido = sumar(ventas, 'total');
  const totalCobrado = sumar(pagos, 'monto') + sumar(cobros, 'monto');
  const totalFiadoPendiente = sumar(clientes, 'saldo');
  const totalGastosMercaderia = reposiciones.reduce((acc, r) => acc + Number(r.cantidad) * Number(r.precio_costo), 0);
  const gananciaBruta = totalVendido - totalGastosMercaderia;

  return { totalVendido, totalCobrado, totalFiadoPendiente, totalGastosMercaderia, gananciaBruta };
}

// Cierre mensual (seccion 9 y 10): persiste calcularResumenMes como una
// "foto" -- no depende de que cada dia se haya cerrado formalmente.
export async function cerrarCajaDelMes({ localId, organizationId, anio, mes, usuarioId }) {
  const resumen = await calcularResumenMes(localId, anio, mes);

  const { error } = await supabase.from('cierres_mensuales').upsert(
    {
      local_id: localId,
      organization_id: organizationId,
      anio,
      mes,
      total_vendido: resumen.totalVendido,
      total_cobrado: resumen.totalCobrado,
      total_fiado_pendiente: resumen.totalFiadoPendiente,
      total_gastos_mercaderia: resumen.totalGastosMercaderia,
      ganancia_bruta: resumen.gananciaBruta,
      cerrado_por: usuarioId,
      cerrado_at: new Date().toISOString(),
    },
    { onConflict: 'local_id,anio,mes' }
  );
  if (error) throw error;
}

export async function listarCierresMensuales(localId) {
  const { data, error } = await supabase
    .from('cierres_mensuales')
    .select('*')
    .eq('local_id', localId)
    .order('anio', { ascending: false })
    .order('mes', { ascending: false });
  if (error) throw error;
  return data;
}
