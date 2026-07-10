// Version fijada (no "latest"): ver js/barcode.js para el porque -- una
// libreria de CDN actualizandose sola en produccion es justamente lo que
// rompio el escaner de codigo de barras.
import * as XLSX from 'https://cdn.jsdelivr.net/npm/xlsx@0.18.5/+esm';

export const COLUMNAS = [
  'Nombre',
  'Presentación',
  'Unidad',
  'Categoría',
  'Perecedero (SI/NO)',
  'Stock actual',
  'Stock mínimo',
  'Precio de venta',
  'Código de barras',
];

export function exportarProductos(productos, nombreArchivo = 'productos.xlsx') {
  const filas = productos.map((p) => ({
    Nombre: p.nombre,
    Presentación: p.presentacion || '',
    Unidad: p.unidad_medida || '',
    Categoría: p.categorias?.nombre || '',
    'Perecedero (SI/NO)': p.perecedero ? 'SI' : 'NO',
    'Stock actual': p.stock_actual,
    'Stock mínimo': p.stock_minimo,
    'Precio de venta': p.precio_venta_actual,
    'Código de barras': p.codigo_barras || '',
  }));
  const hoja = XLSX.utils.json_to_sheet(filas, { header: COLUMNAS });
  const libro = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(libro, hoja, 'Productos');
  XLSX.writeFile(libro, nombreArchivo);
}

export function descargarPlantilla() {
  const hoja = XLSX.utils.json_to_sheet([], { header: COLUMNAS });
  const libro = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(libro, hoja, 'Productos');
  XLSX.writeFile(libro, 'plantilla-productos.xlsx');
}

// Devuelve las filas crudas del Excel (una por producto), tal cual las
// columnas de COLUMNAS. La pagina se encarga de mapear/validar cada fila.
export async function leerArchivoProductos(file) {
  const buffer = await file.arrayBuffer();
  const libro = XLSX.read(buffer, { type: 'array' });
  const hoja = libro.Sheets[libro.SheetNames[0]];
  return XLSX.utils.sheet_to_json(hoja, { defval: '' });
}
