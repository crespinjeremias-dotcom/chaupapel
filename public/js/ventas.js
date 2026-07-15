import { supabase } from './supabaseClient.js';

const VENTANA_EDICION_MS = 15 * 60 * 1000; // 10-15 min, seccion 7 -- se usa el limite superior

export function dentroDeVentana(venta) {
  return Date.now() - new Date(venta.created_at).getTime() < VENTANA_EDICION_MS;
}

// Espeja la policy de RLS (ventas_update) para poder mostrar/ocultar
// botones en la UI -- el bloqueo real sigue siendo el de la base.
export function puedeModificar(venta, usuario) {
  if (venta.estado === 'anulada') return false;
  if (usuario.role === 'admin') return true;
  return venta.usuario_id === usuario.id && dentroDeVentana(venta);
}

// Editar el detalle (cantidad/items) de una venta fiada requeriria tambien
// corregir el monto ya acreditado en cuenta_corriente_movimientos -- eso
// interactua con el modulo de cobros que todavia no existe (Fase 6), asi que
// por ahora una venta fiada con un error se anula y se recarga de nuevo, no
// se edita item por item.
export function puedeEditarItems(venta, usuario) {
  return !venta.es_fiado && puedeModificar(venta, usuario);
}

export async function registrarVenta({ turnoId, usuarioId, localId, organizationId, items, esFiado, clienteId, pagos }) {
  const total = items.reduce((acc, it) => acc + it.cantidad * it.precioUnitario, 0);

  const { data: venta, error: errorVenta } = await supabase
    .from('ventas')
    .insert({
      local_id: localId,
      organization_id: organizationId,
      turno_id: turnoId,
      usuario_id: usuarioId,
      cliente_id: esFiado ? clienteId : null,
      es_fiado: esFiado,
      total,
    })
    .select()
    .single();
  if (errorVenta) throw errorVenta;

  const { error: errorItems } = await supabase.from('venta_items').insert(
    items.map((it) => ({
      venta_id: venta.id,
      producto_id: it.productoId,
      local_id: localId,
      organization_id: organizationId,
      cantidad: it.cantidad,
      precio_unitario: it.precioUnitario,
    }))
  );
  if (errorItems) throw errorItems;

  if (esFiado) {
    const { error: errorFiado } = await supabase.from('cuenta_corriente_movimientos').insert({
      cliente_id: clienteId,
      local_id: localId,
      organization_id: organizationId,
      tipo: 'fiado_nuevo',
      monto: total,
      venta_id: venta.id,
      usuario_id: usuarioId,
    });
    if (errorFiado) throw errorFiado;
  } else {
    const { error: errorPagos } = await supabase.from('venta_pagos').insert(
      pagos.map((p) => ({
        venta_id: venta.id,
        local_id: localId,
        organization_id: organizationId,
        metodo: p.metodo,
        monto: p.monto,
      }))
    );
    if (errorPagos) throw errorPagos;
  }

  return venta;
}

// usuarioId: si se pasa, filtra a las ventas de ese vendedor puntual -- lo
// usa historial-ventas.html cuando quien mira es un empleado (seccion "menu
// diferenciado por rol": el empleado ve "mis ventas", no las de todo el
// local). En modo de cuenta compartida esto ya funciona bien solo, porque
// todas las ventas de ese dia quedan cargadas con el mismo usuario_id.
export async function listarVentas({ desde, hasta, query, usuarioId } = {}) {
  let consulta = supabase
    .from('ventas')
    // ventas tiene dos FK a usuarios (usuario_id y anulada_por) -- hay que
    // decirle a PostgREST cual usar o tira "more than one relationship".
    .select('*, usuarios:usuarios!usuario_id(nombre), clientes(nombre), venta_items(count)')
    .order('fecha', { ascending: false });

  if (desde) consulta = consulta.gte('fecha', desde);
  if (hasta) consulta = consulta.lte('fecha', hasta);
  if (usuarioId) consulta = consulta.eq('usuario_id', usuarioId);

  const { data, error } = await consulta;
  if (error) throw error;

  let resultado = data;
  if (query) {
    const q = query.toLowerCase();
    resultado = resultado.filter((v) => v.usuarios?.nombre?.toLowerCase().includes(q) || v.clientes?.nombre?.toLowerCase().includes(q));
  }

  return resultado;
}

export async function obtenerVentaConDetalle(id) {
  const [{ data: venta, error: errorVenta }, { data: items, error: errorItems }, { data: pagos, error: errorPagos }] = await Promise.all([
    supabase.from('ventas').select('*, usuarios:usuarios!usuario_id(nombre), clientes(nombre)').eq('id', id).single(),
    supabase.from('venta_items').select('*, productos(nombre, unidad_medida)').eq('venta_id', id).order('created_at'),
    supabase.from('venta_pagos').select('*').eq('venta_id', id),
  ]);
  if (errorVenta) throw errorVenta;
  if (errorItems) throw errorItems;
  if (errorPagos) throw errorPagos;

  return { venta, items, pagos };
}

// Productos mas vendidos (seccion 12): agrupa venta_items por producto en un
// rango de fechas, con filtro opcional de franja horaria (hora local, ej.
// 8-14). Se trae el detalle y se agrupa en el cliente porque PostgREST no
// puede filtrar por "hora del dia" de una columna timestamptz directamente.
export async function productosMasVendidos({ desde, hasta, horaDesde, horaHasta }) {
  const { data, error } = await supabase
    .from('venta_items')
    .select('cantidad, producto_id, productos(nombre), ventas!inner(fecha, estado)')
    .gte('ventas.fecha', desde)
    .lt('ventas.fecha', hasta)
    .neq('ventas.estado', 'anulada');
  if (error) throw error;

  const filtrados =
    horaDesde == null || horaHasta == null
      ? data
      : data.filter((it) => {
          const hora = new Date(it.ventas.fecha).getHours();
          return hora >= horaDesde && hora < horaHasta;
        });

  const porProducto = new Map();
  for (const it of filtrados) {
    const actual = porProducto.get(it.producto_id) || { nombre: it.productos?.nombre || 'Producto eliminado', cantidad: 0 };
    actual.cantidad += Number(it.cantidad);
    porProducto.set(it.producto_id, actual);
  }

  return [...porProducto.values()].sort((a, b) => b.cantidad - a.cantidad);
}

// Reemplaza items y pagos por completo (borra + inserta de nuevo) en vez de
// diffear cambio a cambio -- los triggers de stock ya reaccionan a insert y
// delete de venta_items, asi que el stock queda bien sin logica extra aca.
// Solo aplica a ventas NO fiadas (ver puedeEditarItems).
export async function actualizarVenta(id, { items, pagos }) {
  const total = items.reduce((acc, it) => acc + it.cantidad * it.precioUnitario, 0);

  const { data: ventaActual, error: errorActual } = await supabase.from('ventas').select('local_id, organization_id').eq('id', id).single();
  if (errorActual) throw errorActual;

  const { error: errorDeleteItems } = await supabase.from('venta_items').delete().eq('venta_id', id);
  if (errorDeleteItems) throw errorDeleteItems;

  const { error: errorInsertItems } = await supabase.from('venta_items').insert(
    items.map((it) => ({
      venta_id: id,
      producto_id: it.productoId,
      local_id: ventaActual.local_id,
      organization_id: ventaActual.organization_id,
      cantidad: it.cantidad,
      precio_unitario: it.precioUnitario,
    }))
  );
  if (errorInsertItems) throw errorInsertItems;

  const { error: errorDeletePagos } = await supabase.from('venta_pagos').delete().eq('venta_id', id);
  if (errorDeletePagos) throw errorDeletePagos;

  const { error: errorInsertPagos } = await supabase.from('venta_pagos').insert(
    pagos.map((p) => ({
      venta_id: id,
      local_id: ventaActual.local_id,
      organization_id: ventaActual.organization_id,
      metodo: p.metodo,
      monto: p.monto,
    }))
  );
  if (errorInsertPagos) throw errorInsertPagos;

  const { error: errorUpdate } = await supabase.from('ventas').update({ total, estado: 'editada' }).eq('id', id);
  if (errorUpdate) throw errorUpdate;
}

// El trigger aplicar_anulacion_venta repone el stock y, si era fiada,
// revierte la deuda automaticamente (ver migracion de Fase 5).
export async function anularVenta(id, usuarioId) {
  const { error } = await supabase
    .from('ventas')
    .update({ estado: 'anulada', anulada_por: usuarioId, anulada_at: new Date().toISOString() })
    .eq('id', id);
  if (error) throw error;
}
