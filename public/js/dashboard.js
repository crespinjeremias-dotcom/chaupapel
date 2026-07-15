import { supabase } from './supabaseClient.js';

function limitesDelDia(fecha = new Date()) {
  const desde = new Date(fecha.getFullYear(), fecha.getMonth(), fecha.getDate());
  const hasta = new Date(desde);
  hasta.setDate(hasta.getDate() + 1);
  return { desde: desde.toISOString(), hasta: hasta.toISOString() };
}

function limitesDelMes(anio, mes) {
  const desde = new Date(anio, mes - 1, 1);
  const hasta = new Date(anio, mes, 1);
  return { desde: desde.toISOString(), hasta: hasta.toISOString() };
}

// Resumen de caja del dia para el dashboard: mismos datos que ya guarda cada
// venta (venta_pagos, cuenta_corriente_movimientos) sumados para hoy, en vivo
// y sin distinguir turnos. El conteo de efectivo turno por turno y la
// diferencia real viven en js/caja.js (modulo Caja).
// localId: si se pasa, filtra a ese local puntual (seccion 13, multi-local);
// sin localId queda consolidado (todos los locales de la organizacion).
export async function obtenerResumenCajaHoy(localId) {
  const { desde, hasta } = limitesDelDia();

  let consultaPagos = supabase
    .from('venta_pagos')
    .select('metodo, monto, ventas!inner(fecha, estado, local_id)')
    .gte('ventas.fecha', desde)
    .lt('ventas.fecha', hasta)
    .neq('ventas.estado', 'anulada');
  let consultaVentas = supabase.from('ventas').select('total').gte('fecha', desde).lt('fecha', hasta).neq('estado', 'anulada');
  let consultaFiado = supabase.from('cuenta_corriente_movimientos').select('monto').eq('tipo', 'fiado_nuevo').gte('fecha', desde).lt('fecha', hasta);
  if (localId) {
    consultaPagos = consultaPagos.eq('ventas.local_id', localId);
    consultaVentas = consultaVentas.eq('local_id', localId);
    consultaFiado = consultaFiado.eq('local_id', localId);
  }

  const [{ data: pagos, error: errorPagos }, { data: ventas, error: errorVentas }, { data: fiado, error: errorFiado }] = await Promise.all([
    consultaPagos,
    consultaVentas,
    consultaFiado,
  ]);
  if (errorPagos) throw errorPagos;
  if (errorVentas) throw errorVentas;
  if (errorFiado) throw errorFiado;

  const sumar = (arr, campo) => arr.reduce((acc, r) => acc + Number(r[campo]), 0);

  return {
    efectivo: sumar(pagos.filter((p) => p.metodo === 'efectivo'), 'monto'),
    transferencia: sumar(pagos.filter((p) => p.metodo === 'transferencia'), 'monto'),
    fiadoGenerado: sumar(fiado, 'monto'),
    totalVendido: sumar(ventas, 'total'),
  };
}

// Resumen mensual del mes en curso para el dashboard: se calcula al vuelo en
// vez de leer cierres_mensuales porque el mes actual todavia no esta cerrado
// (el cierre formal, con "foto" persistida por local, vive en js/caja.js).
// localId: igual que en obtenerResumenCajaHoy, filtra a un local puntual.
export async function obtenerResumenMes(anio, mes, localId) {
  const { desde, hasta } = limitesDelMes(anio, mes);

  let consultaVentas = supabase.from('ventas').select('total').gte('fecha', desde).lt('fecha', hasta).neq('estado', 'anulada');
  let consultaPagos = supabase
    .from('venta_pagos')
    .select('monto, ventas!inner(fecha, estado, local_id)')
    .gte('ventas.fecha', desde)
    .lt('ventas.fecha', hasta)
    .neq('ventas.estado', 'anulada');
  let consultaCobros = supabase.from('cuenta_corriente_movimientos').select('monto').eq('tipo', 'cobro_fiado').gte('fecha', desde).lt('fecha', hasta);
  let consultaClientes = supabase.from('clientes').select('saldo').eq('activo', true);
  let consultaReposiciones = supabase.from('reposiciones_stock').select('cantidad, precio_costo').gte('fecha', desde).lt('fecha', hasta);
  if (localId) {
    consultaVentas = consultaVentas.eq('local_id', localId);
    consultaPagos = consultaPagos.eq('ventas.local_id', localId);
    consultaCobros = consultaCobros.eq('local_id', localId);
    consultaClientes = consultaClientes.eq('local_id', localId);
    consultaReposiciones = consultaReposiciones.eq('local_id', localId);
  }

  const [
    { data: ventas, error: errorVentas },
    { data: pagos, error: errorPagos },
    { data: cobros, error: errorCobros },
    { data: clientes, error: errorClientes },
    { data: reposiciones, error: errorReposiciones },
  ] = await Promise.all([consultaVentas, consultaPagos, consultaCobros, consultaClientes, consultaReposiciones]);
  if (errorVentas) throw errorVentas;
  if (errorPagos) throw errorPagos;
  if (errorCobros) throw errorCobros;
  if (errorClientes) throw errorClientes;
  if (errorReposiciones) throw errorReposiciones;

  const sumar = (arr, campo) => arr.reduce((acc, r) => acc + Number(r[campo]), 0);

  return {
    totalVendido: sumar(ventas, 'total'),
    totalCobrado: sumar(pagos, 'monto') + sumar(cobros, 'monto'),
    saldoFiadoPendiente: sumar(clientes, 'saldo'),
    gastoMercaderia: reposiciones.reduce((acc, r) => acc + Number(r.cantidad) * Number(r.precio_costo), 0),
  };
}
