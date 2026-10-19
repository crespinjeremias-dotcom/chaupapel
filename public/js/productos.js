import { supabase } from './supabaseClient.js';

// Un solo lugar para este criterio: productos.html, panel.html y
// alertas-stock.html lo usaban cada uno por su cuenta, y productos.html sin
// el Number() de los otros dos -- stock_actual/stock_minimo llegan de
// PostgREST como string, asi que esa comparacion era lexicografica en vez de
// numerica (ej. "9" > "10").
export function esStockBajo(p) {
  return Number(p.stock_actual) <= Number(p.stock_minimo);
}

export const MOTIVOS_AJUSTE = [
  { value: 'rotura', label: 'Rotura/daño' },
  { value: 'vencido', label: 'Vencido' },
  { value: 'robo', label: 'Robo/faltante' },
  { value: 'error_conteo', label: 'Error de conteo' },
  { value: 'otro', label: 'Otro' },
];

export async function listarCategorias() {
  const { data, error } = await supabase.from('categorias').select('id, nombre, local_id').order('nombre');
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

// Valor entre comillas dobles para un filtro de PostgREST: asi una coma o un
// parentesis dentro del texto buscado (ej. "coca 1,5") no se interpreta como
// parte de la sintaxis del filtro -- antes rompia la busqueda.
function entreComillas(texto) {
  return `"${texto.replace(/[\\"]/g, '\\$&')}"`;
}

// Busca por nombre (autocompletado, seccion 4) o por codigo de barras exacto
// (lector fisico o camara). Trae tambien el nombre de categoria para la tabla.
// Excluye SIEMPRE los eliminados (deleted_at) -- es un listado operativo, un
// producto eliminado no puede volver a aparecer para nada nuevo. soloActivos
// es un filtro aparte (activo/inactivo), independiente de eliminado.
export async function listarProductos({ query, soloActivos = false } = {}) {
  let consulta = supabase
    .from('productos')
    .select('*, categorias(nombre)')
    .is('deleted_at', null)
    .order('nombre');

  if (soloActivos) consulta = consulta.eq('activo', true);

  // Busqueda por palabras: cada palabra tiene que aparecer en el nombre O en la
  // presentacion, en cualquier orden ("coca 1,5" encuentra "Coca-Cola · 1,5 L").
  // Con una sola palabra tambien vale el codigo de barras exacto (lector o
  // camara). Con varias palabras se arma un unico and=(or(...),or(...)), la
  // forma documentada de PostgREST para "todas las palabras".
  if (query) {
    const palabras = String(query).trim().split(/\s+/).filter(Boolean);
    const grupos = palabras.map((palabra) => {
      // "1,5" y "1.5" se buscan por igual (la presentacion se escribe de las dos formas)
      const variantes = [...new Set([palabra, palabra.replace(/,/g, '.'), palabra.replace(/\./g, ',')])];
      const condiciones = variantes.flatMap((v) => {
        const patron = entreComillas(`%${v.replace(/[\\%_]/g, '\\$&')}%`);
        return [`nombre.ilike.${patron}`, `presentacion.ilike.${patron}`];
      });
      if (palabras.length === 1) condiciones.push(`codigo_barras.eq.${entreComillas(palabra)}`);
      return condiciones.join(',');
    });
    if (grupos.length === 1) {
      consulta = consulta.or(grupos[0]);
    } else if (grupos.length > 1) {
      consulta.url.searchParams.append('and', `(${grupos.map((g) => `or(${g})`).join(',')})`);
    }
  }

  const { data, error } = await consulta;
  if (error) throw error;
  return data;
}

// Acciones masivas (solo admin). Cada una es UNA llamada a una funcion de la
// base que cambia todos los productos en una sola operacion -- o cambian todos
// o ninguno -- y valida del lado del servidor el rol, la organizacion y el
// local (ver migracion 20261019100000). Devuelven los ids que SI cambiaron:
// puede ser menos de los pedidos (ya estaban eliminados, otro local, etc.).
export async function eliminarProductos(localId, ids) {
  const { data, error } = await supabase.rpc('eliminar_productos', { p_local_id: localId, p_ids: ids });
  if (error) throw error;
  return data || [];
}

// Deshacer una eliminacion: solo vuelve lo eliminado hace menos de 15 minutos
// y cuyo codigo de barras no lo use ahora otro producto del local.
export async function restaurarProductos(localId, ids) {
  const { data, error } = await supabase.rpc('restaurar_productos', { p_local_id: localId, p_ids: ids });
  if (error) throw error;
  return data || [];
}

export async function establecerActivoProductos(localId, ids, activo) {
  const { data, error } = await supabase.rpc('establecer_activo_productos', { p_local_id: localId, p_ids: ids, p_activo: activo });
  if (error) throw error;
  return data || [];
}

// Productos vivos de UN local (lo que la importacion compara contra el
// archivo). Pagina de a 1000 porque PostgREST corta ahi por defecto.
export async function listarProductosDelLocal(localId) {
  const todos = [];
  for (let desde = 0; ; desde += 1000) {
    const { data, error } = await supabase
      .from('productos')
      .select('id, nombre, presentacion, unidad_medida, codigo_barras, precio_venta_actual, categoria_id, stock_minimo, perecedero')
      .eq('local_id', localId)
      .is('deleted_at', null)
      .order('nombre')
      .range(desde, desde + 999);
    if (error) throw error;
    todos.push(...data);
    if (data.length < 1000) return todos;
  }
}

function mensajeDeError(err) {
  if (err?.code === '23505') return 'ya existe un producto con ese código de barras en el local';
  return err?.message || 'error desconocido';
}

// Crea muchos productos. Manda de a 100 en una sola operacion; si una tanda
// falla (ej. un codigo de barras repetido que se colo), reintenta esa tanda
// fila por fila para que una fila mala no frene a las demas ni se pierdan
// las buenas. filas: [{ numero, datos }]. Devuelve { creados, errores }.
export async function crearProductosEnLote(filas) {
  let creados = 0;
  const errores = [];
  for (let i = 0; i < filas.length; i += 100) {
    const tanda = filas.slice(i, i + 100);
    const { error } = await supabase.from('productos').insert(tanda.map((f) => f.datos));
    if (!error) {
      creados += tanda.length;
      continue;
    }
    for (const f of tanda) {
      const { error: errorFila } = await supabase.from('productos').insert(f.datos);
      if (errorFila) errores.push({ numero: f.numero, mensaje: mensajeDeError(errorFila) });
      else creados++;
    }
  }
  return { creados, errores };
}

// Actualiza productos existentes (cada uno con sus propios cambios), de a 10
// en paralelo. filas: [{ numero, id, datos }]. Devuelve { actualizados, errores }.
export async function actualizarProductosEnLote(filas) {
  let actualizados = 0;
  const errores = [];
  for (let i = 0; i < filas.length; i += 10) {
    const tanda = filas.slice(i, i + 10);
    const resultados = await Promise.all(
      tanda.map(async (f) => {
        const { stock_actual, ...cambios } = f.datos; // el stock solo cambia por ajustes
        const { error } = await supabase.from('productos').update(cambios).eq('id', f.id);
        return { f, error };
      })
    );
    for (const { f, error } of resultados) {
      if (error) errores.push({ numero: f.numero, mensaje: mensajeDeError(error) });
      else actualizados++;
    }
  }
  return { actualizados, errores };
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

// Borrado logico: la fila sigue existiendo (ventas, reposiciones, ajustes y
// vinculos con proveedores ya cargados la siguen referenciando sin romperse),
// pero desaparece de listarProductos y de cualquier flujo operativo nuevo.
// Terminal desde la UI -- no hay funcion de "restaurar" a proposito.
export async function eliminarProducto(id) {
  const { error } = await supabase.from('productos').update({ deleted_at: new Date().toISOString() }).eq('id', id);
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

// Historial de ajustes de stock (mermas, seccion 12): mismo motivo/comentario
// que ya se carga en ajustarStock, solo para consulta.
export async function listarAjustesStock({ desde, hasta } = {}) {
  let consulta = supabase
    .from('ajustes_stock')
    .select('*, productos(nombre, presentacion), usuarios(nombre)')
    .order('created_at', { ascending: false });
  if (desde) consulta = consulta.gte('created_at', desde);
  if (hasta) consulta = consulta.lt('created_at', hasta);

  const { data, error } = await consulta;
  if (error) throw error;
  return data;
}
