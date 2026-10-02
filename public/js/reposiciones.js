import { supabase } from './supabaseClient.js';

// Reposicion de stock (seccion 6). El trigger de la base suma la cantidad a
// productos.stock_actual y actualiza ultimo_precio_costo -- esta funcion
// solo inserta el movimiento. Sin proveedor: la funcionalidad de proveedores
// se saco de la interfaz (reposiciones_stock.proveedor_id admite null).
export async function registrarReposicion({ productoId, localId, organizationId, usuarioId, cantidad, precioCosto }) {
  const { error } = await supabase.from('reposiciones_stock').insert({
    producto_id: productoId,
    proveedor_id: null,
    local_id: localId,
    organization_id: organizationId,
    usuario_id: usuarioId,
    cantidad,
    precio_costo: precioCosto,
  });
  if (error) throw error;
}
