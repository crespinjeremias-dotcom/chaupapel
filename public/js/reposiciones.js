import { supabase } from './supabaseClient.js';

// Reposicion de stock (seccion 6): misma accion desde Productos y desde
// Proveedores (dos puntos de entrada). El trigger de la base suma la
// cantidad a productos.stock_actual y actualiza ultimo_precio_costo --
// esta funcion solo inserta el movimiento.
export async function registrarReposicion({ productoId, proveedorId, localId, organizationId, usuarioId, cantidad, precioCosto }) {
  const { error } = await supabase.from('reposiciones_stock').insert({
    producto_id: productoId,
    proveedor_id: proveedorId,
    local_id: localId,
    organization_id: organizationId,
    usuario_id: usuarioId,
    cantidad,
    precio_costo: precioCosto,
  });
  if (error) throw error;
}

export async function listarProveedoresDeProducto(productoId) {
  const { data, error } = await supabase
    .from('producto_proveedor')
    .select('proveedor_id, proveedores(id, nombre, deleted_at)')
    .eq('producto_id', productoId);
  if (error) throw error;
  return data.filter((v) => v.proveedores && !v.proveedores.deleted_at).map((v) => v.proveedores);
}
