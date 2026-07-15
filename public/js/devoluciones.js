import { supabase } from './supabaseClient.js';

// El trigger aplicar_stock_devolucion_cambio (Fase 1) ya se encarga de:
// - restar stock del producto nuevo si es un cambio (el producto devuelto no
//   se repone -- queda descartado, seccion 8).
// - insertar el movimiento de cuenta corriente si la resolucion es
//   "saldo_pendiente" (fiado_nuevo si el cliente debe, saldo_favor_generado
//   si es a favor del cliente).
export async function registrarDevolucionCambio({
  ventaId,
  localId,
  organizationId,
  tipo,
  productoOriginalId,
  cantidad,
  motivo,
  productoNuevoId,
  cantidadNueva,
  diferenciaPrecio,
  resolucion,
  clienteId,
  usuarioId,
}) {
  const { error } = await supabase.from('devoluciones_cambios').insert({
    venta_id: ventaId,
    local_id: localId,
    organization_id: organizationId,
    tipo,
    producto_original_id: productoOriginalId,
    cantidad,
    motivo,
    producto_nuevo_id: tipo === 'cambio' ? productoNuevoId : null,
    cantidad_nueva: tipo === 'cambio' ? cantidadNueva : null,
    diferencia_precio: diferenciaPrecio || null,
    resolucion: diferenciaPrecio ? resolucion : null,
    cliente_id: resolucion === 'saldo_pendiente' ? clienteId : null,
    usuario_id: usuarioId,
  });
  if (error) throw error;
}

export async function listarDevolucionesDeVenta(ventaId) {
  const { data, error } = await supabase
    .from('devoluciones_cambios')
    .select('*, producto_original:productos!producto_original_id(nombre), producto_nuevo:productos!producto_nuevo_id(nombre)')
    .eq('venta_id', ventaId)
    .order('fecha', { ascending: false });
  if (error) throw error;
  return data;
}
