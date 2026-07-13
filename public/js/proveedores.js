import { supabase } from './supabaseClient.js';

// Excluye SIEMPRE los eliminados (deleted_at) -- listado operativo.
export async function listarProveedores({ query, soloActivos = false } = {}) {
  let consulta = supabase.from('proveedores').select('*').is('deleted_at', null).order('nombre');
  if (soloActivos) consulta = consulta.eq('activo', true);
  if (query) consulta = consulta.ilike('nombre', `%${query}%`);
  const { data, error } = await consulta;
  if (error) throw error;
  return data;
}

export async function obtenerProveedor(id) {
  const { data, error } = await supabase.from('proveedores').select('*').eq('id', id).single();
  if (error) throw error;
  return data;
}

export async function crearProveedor(datos) {
  const { data, error } = await supabase.from('proveedores').insert(datos).select().single();
  if (error) throw error;
  return data;
}

export async function actualizarProveedor(id, datos) {
  const { data, error } = await supabase.from('proveedores').update(datos).eq('id', id).select().single();
  if (error) throw error;
  return data;
}

export async function establecerActivo(id, activo) {
  const { error } = await supabase.from('proveedores').update({ activo }).eq('id', id);
  if (error) throw error;
}

// Borrado logico (ver misma nota en productos.js): reclamos y reposiciones ya
// cargados contra este proveedor siguen intactos y resuelven su nombre via
// join normal. Terminal desde la UI, sin funcion de "restaurar".
export async function eliminarProveedor(id) {
  const { error } = await supabase.from('proveedores').update({ deleted_at: new Date().toISOString() }).eq('id', id);
  if (error) throw error;
}

// Productos vinculados a un proveedor (seccion 5), con la fecha de la
// ultima reposicion de cada uno hecha a traves de ESE proveedor puntual.
// Es un listado operativo (de aca se dispara "Reponer stock"), asi que un
// producto eliminado no debe aparecer aunque el vinculo siga en la tabla.
export async function listarProductosVinculados(proveedorId) {
  const { data: vinculos, error } = await supabase
    .from('producto_proveedor')
    .select('id, precio_referencia, productos(id, nombre, presentacion, stock_actual, unidad_medida, activo, deleted_at)')
    .eq('proveedor_id', proveedorId)
    .order('created_at');
  if (error) throw error;

  const vinculosVigentes = vinculos.filter((v) => v.productos && !v.productos.deleted_at);

  const { data: reposiciones, error: errorRepo } = await supabase
    .from('reposiciones_stock')
    .select('producto_id, fecha')
    .eq('proveedor_id', proveedorId)
    .order('fecha', { ascending: false });
  if (errorRepo) throw errorRepo;

  const ultimaFechaPorProducto = new Map();
  for (const r of reposiciones) {
    if (!ultimaFechaPorProducto.has(r.producto_id)) ultimaFechaPorProducto.set(r.producto_id, r.fecha);
  }

  return vinculosVigentes.map((v) => ({
    vinculoId: v.id,
    precioReferencia: v.precio_referencia,
    producto: v.productos,
    ultimaReposicion: ultimaFechaPorProducto.get(v.productos.id) || null,
  }));
}

export async function listarProductosNoVinculados(proveedorId, localId) {
  const [{ data: productos, error: errorProductos }, { data: vinculados, error: errorVinculados }] = await Promise.all([
    supabase.from('productos').select('id, nombre, presentacion').eq('local_id', localId).eq('activo', true).is('deleted_at', null).order('nombre'),
    supabase.from('producto_proveedor').select('producto_id').eq('proveedor_id', proveedorId),
  ]);
  if (errorProductos) throw errorProductos;
  if (errorVinculados) throw errorVinculados;

  const idsVinculados = new Set(vinculados.map((v) => v.producto_id));
  return productos.filter((p) => !idsVinculados.has(p.id));
}

export async function vincularProducto({ productoId, proveedorId, localId, organizationId, precioReferencia }) {
  const { error } = await supabase.from('producto_proveedor').insert({
    producto_id: productoId,
    proveedor_id: proveedorId,
    local_id: localId,
    organization_id: organizationId,
    precio_referencia: precioReferencia || null,
  });
  if (error) throw error;
}

export async function desvincularProducto(vinculoId) {
  const { error } = await supabase.from('producto_proveedor').delete().eq('id', vinculoId);
  if (error) throw error;
}

// Reclamos y devoluciones al proveedor (seccion 5 y 8).
export async function listarReclamos(proveedorId) {
  const { data, error } = await supabase
    .from('reclamos_proveedor')
    .select('*, productos(nombre)')
    .eq('proveedor_id', proveedorId)
    .order('fecha', { ascending: false });
  if (error) throw error;
  return data;
}

export async function crearReclamo({ proveedorId, productoId, localId, organizationId, usuarioId, cantidad, motivo }) {
  const { error } = await supabase.from('reclamos_proveedor').insert({
    proveedor_id: proveedorId,
    producto_id: productoId || null,
    local_id: localId,
    organization_id: organizationId,
    usuario_id: usuarioId,
    cantidad: cantidad || null,
    motivo,
  });
  if (error) throw error;
}

export async function marcarReclamoRepuesto(id) {
  const { error } = await supabase.from('reclamos_proveedor').update({ estado: 'repuesto' }).eq('id', id);
  if (error) throw error;
}
