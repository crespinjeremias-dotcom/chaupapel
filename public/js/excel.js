// Version fijada (no "latest"): ver js/barcode.js para el porque -- una
// libreria de CDN actualizandose sola en produccion es justamente lo que
// rompio el escaner de codigo de barras.
import * as XLSX from 'https://cdn.sheetjs.com/xlsx-0.20.3/package/xlsx.mjs';
import { celdasDeHoja, construirHojaProductos, construirHojaPlantilla, construirHojaInstrucciones } from './importacion.js';

// Fecha local (no UTC) para el nombre del archivo: YYYY-MM-DD
function fechaParaArchivo() {
  const h = new Date();
  return `${h.getFullYear()}-${String(h.getMonth() + 1).padStart(2, '0')}-${String(h.getDate()).padStart(2, '0')}`;
}

// Exporta con las mismas columnas y titulos que usa la importacion (ver
// js/importacion.js), asi el archivo vuelve a importarse sin cambios. Incluye
// el ID de cada producto: al reimportar, las filas con ID actualizan ese
// producto en vez de crear uno nuevo.
export function exportarProductos(productos, nombreArchivo = `productos-${fechaParaArchivo()}.xlsx`) {
  const libro = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(libro, construirHojaProductos(XLSX.utils, productos), 'Productos');
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

// Plantilla vacia con los mismos titulos que la importacion. La importacion
// lee solo la primera hoja ("Productos"); la segunda explica cada columna.
export function descargarPlantilla() {
  const libro = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(libro, construirHojaPlantilla(XLSX.utils), 'Productos');
  XLSX.utils.book_append_sheet(libro, construirHojaInstrucciones(XLSX.utils), 'Instrucciones');
  XLSX.writeFile(libro, 'plantilla-productos.xlsx');
}

// Lee la primera hoja del Excel como matriz de celdas (con su tipo y el texto
// tal como se ve en Excel, que hace falta para detectar codigos de barras en
// notacion cientifica). El mapeo por nombre de columna y la validacion de
// cada fila estan en js/importacion.js.
export async function leerArchivoProductos(file) {
  const buffer = await file.arrayBuffer();
  const libro = XLSX.read(buffer, { type: 'array' });
  const hoja = libro.Sheets[libro.SheetNames[0]];
  return celdasDeHoja(hoja, XLSX.utils);
}
