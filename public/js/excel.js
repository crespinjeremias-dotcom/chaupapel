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

export function exportarVentas(ventas, nombreArchivo = 'ventas.xlsx') {
  const filas = ventas.map((v) => ({
    Fecha: new Date(v.fecha).toLocaleString('es-AR'),
    Vendedor: v.usuarios?.nombre || '',
    Total: Number(v.total),
    Pago: v.es_fiado ? `Fiado (${v.clientes?.nombre || ''})` : 'Contado',
    Estado: v.estado,
  }));
  const hoja = XLSX.utils.json_to_sheet(filas, { header: ['Fecha', 'Vendedor', 'Total', 'Pago', 'Estado'] });
  const libro = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(libro, hoja, 'Ventas');
  XLSX.writeFile(libro, nombreArchivo);
}

export function exportarCierres(cierresDiarios, cierresMensuales, nombreArchivo = 'cierres-de-caja.xlsx') {
  const filasDiarios = cierresDiarios.map((c) => ({
    Fecha: c.fecha,
    'Efectivo esperado': Number(c.efectivo_esperado_total),
    'Efectivo contado': Number(c.efectivo_contado_total),
    Transferencia: Number(c.transferencia_total),
    'Fiado nuevo': Number(c.fiado_nuevo_total),
    Diferencia: Number(c.diferencia_total),
  }));
  const filasMensuales = cierresMensuales.map((c) => ({
    Mes: `${String(c.mes).padStart(2, '0')}/${c.anio}`,
    'Total vendido': Number(c.total_vendido),
    'Total cobrado': Number(c.total_cobrado),
    'Fiado pendiente': Number(c.total_fiado_pendiente),
    'Gasto mercadería': Number(c.total_gastos_mercaderia),
    'Ganancia bruta': Number(c.ganancia_bruta),
  }));

  const libro = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(libro, XLSX.utils.json_to_sheet(filasDiarios), 'Cierres diarios');
  XLSX.utils.book_append_sheet(libro, XLSX.utils.json_to_sheet(filasMensuales), 'Cierres mensuales');
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
