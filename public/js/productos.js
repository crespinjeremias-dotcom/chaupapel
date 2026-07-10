import { supabase } from './supabaseClient.js';

export const MOTIVOS_AJUSTE = [
  { value: 'rotura', label: 'Rotura/daño' },
  { value: 'vencido', label: 'Vencido' },
  { value: 'robo', label: 'Robo/faltante' },
  { value: 'error_conteo', label: 'Error de conteo' },
  { value: 'otro', label: 'Otro' },
];

export async function listarCategorias() {
  const { data, error } = await supabase.from('categorias').select('id, nombre').order('nombre');
  if (error) throw error;
  return data;
}

export async function crearCategoria(nombre, localId, organizationId) {
  const { data, error } = await supabase
    .from('categorias')
    .insert({ nombre, local_id: localId, organization_id: organizationId })
    .select()
    .single();
  if (error) throw error;
  return data;
}

// Busca por nombre (autocompletado, seccion 4) o por codigo de barras exacto
// (lector fisico o camara). Trae tambien el nombre de categoria para la tabla.
export async function listarProductos({ query, soloActivos = false } = {}) {
  let consulta = supabase
    .from('productos')
    .select('*, categorias(nombre)')
    .order('nombre');

  if (soloActivos) consulta = consulta.eq('activo', true);

  if (query) {
    consulta = consulta.or(`nombre.ilike.%${query}%,codigo_barras.eq.${query}`);
  }

  const { data, error } = await consulta;
  if (error) throw error;
  return data;
}

export async function obtenerProducto(id) {
  const { data, error } = await supabase.from('productos').select('*, categorias(nombre)').eq('id', id).single();
  if (error) throw error;
  return data;
}

// stock_actual solo se manda en la creacion (carga inicial). En edicion no
// se toca desde aca -- cambia unicamente via ajustarStock, para que quede
// registrado el motivo (seccion 4).
export async function crearProducto(datos) {
  const { data, error } = await supabase.from('productos').insert(datos).select().single();
  if (error) throw error;
  return data;
}

export async function actualizarProducto(id, datos) {
  const { stock_actual, ...resto } = datos;
  const { data, error } = await supabase.from('productos').update(resto).eq('id', id).select().single();
  if (error) throw error;
  return data;
}

export async function establecerActivo(id, activo) {
  const { error } = await supabase.from('productos').update({ activo }).eq('id', id);
  if (error) throw error;
}

// Inserta el movimiento; el trigger de la base actualiza productos.stock_actual.
export async function ajustarStock({ productoId, localId, organizationId, usuarioId, cantidad, motivo, comentario }) {
  const { error } = await supabase.from('ajustes_stock').insert({
    producto_id: productoId,
    local_id: localId,
    organization_id: organizationId,
    usuario_id: usuarioId,
    cantidad,
    motivo,
    comentario: comentario || null,
  });
  if (error) throw error;
}
