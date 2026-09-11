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

// Las 3 escrituras (venta, items, pagos/fiado) viven en un solo RPC
// transaccional (registrar_venta) -- ya hubo un caso real de una venta que
// no se completo (fallo de red a mitad de camino) y quedo igual registrada
// en el historial, sin items ni pago. Con inserts sueltos, un fallo entre
// el paso 2 y el 3 puede ser peor que un registro fantasma: venta_items ya
// descuenta stock al insertarse, asi que el stock quedaria mal aunque la
// venta nunca se haya cobrado. El RPC hace que un fallo en cualquier paso
// revierta todo (ver migracion 20260912093000).
export async function registrarVenta({ turnoId, localId, organizationId, items, esFiado, clienteId, pagos }) {
  const { data: venta, error } = await supabase.rpc('registrar_venta', {
    p_turno_id: turnoId,
    p_local_id: localId,
    p_organization_id: organizationId,
    p_items: items.map((it) => ({ productoId: it.productoId, cantidad: it.cantidad, precioUnitario: it.precioUnitario })),
    p_es_fiado: esFiado,
    p_cliente_id: esFiado ? clienteId : null,
    p_pagos: esFiado ? [] : pagos.map((p) => ({ metodo: p.metodo, monto: p.monto })),
  });
  if (error) throw error;
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
    supabase.from('venta_items').select('*, productos(nombre, unidad_medida, permite_cantidad_decimal)').eq('venta_id', id).order('created_at'),
    supabase.from('venta_pagos').select('*').eq('venta_id', id),
  ]);
  if (errorVenta) throw errorVenta;
  if (errorItems) throw errorItems;
  if (errorPagos) throw errorPagos;

  return { venta, items, pagos };
}

// Productos mas vendidos (seccion 12, Plan Completo): agregado por producto
// en un rango de fechas, con filtro opcional de franja horaria. Vive en el
// RPC obtener_productos_mas_vendidos (no en un query directo a venta_items)
// porque esas tablas tienen que seguir siendo legibles para el resto de la
// operacion y no se pueden restringir por plan -- el RPC valida el plan
// antes de calcular el agregado (ver la migracion 20260911210000).
export async function productosMasVendidos({ desde, hasta, horaDesde, horaHasta }) {
  const { data, error } = await supabase.rpc('obtener_productos_mas_vendidos', {
    p_desde: desde,
    p_hasta: hasta,
    p_hora_desde: horaDesde ?? null,
    p_hora_hasta: horaHasta ?? null,
  });
  if (error) throw error;

  return data.map((r) => ({ nombre: r.nombre, cantidad: Number(r.cantidad) }));
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
