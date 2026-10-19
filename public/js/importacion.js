// Logica de la importacion de productos desde Excel. Es codigo puro: no toca el
// DOM, ni Supabase, ni la libreria de Excel -- recibe las celdas ya leidas y el
// estado actual del local, y devuelve que se va a crear / actualizar / rechazar.
// Asi se puede probar con archivos reales sin abrir el navegador, y la pantalla
// (productos.html) solo se ocupa de mostrar la vista previa y de guardar.

// ---------------------------------------------------------------------------
// Texto: comparacion sin mayusculas, tildes ni espacios de mas
// ---------------------------------------------------------------------------

export function normalizar(texto) {
  return String(texto ?? '')
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, ' ')
    .trim();
}

// ---------------------------------------------------------------------------
// Columnas reconocidas. `alias` se compara ya normalizado (ver normalizar).
// `extra`: columnas que no son de las 6 basicas pero que la importacion ya
// leia antes (stock, perecedero) o que sirven para volver a importar lo
// exportado (ID).
// ---------------------------------------------------------------------------

export const COLUMNAS = [
  { campo: 'id', titulo: 'ID', alias: ['id', 'identificador'], extra: true },
  { campo: 'nombre', titulo: 'Nombre', alias: ['nombre', 'producto', 'descripcion'], obligatoria: true },
  { campo: 'presentacion', titulo: 'Presentación', alias: ['presentacion', 'tamano', 'contenido'] },
  { campo: 'unidad_medida', titulo: 'Unidad de medida', alias: ['unidad de medida', 'unidad', 'medida', 'um'] },
  { campo: 'codigo_barras', titulo: 'Código de barras', alias: ['codigo de barras', 'codigo', 'ean', 'barcode'] },
  { campo: 'precio', titulo: 'Precio', alias: ['precio', 'precio de venta'] },
  { campo: 'categoria', titulo: 'Categoría', alias: ['categoria', 'rubro'] },
  { campo: 'stock_actual', titulo: 'Stock actual', alias: ['stock actual', 'stock'], extra: true },
  { campo: 'stock_minimo', titulo: 'Stock mínimo', alias: ['stock minimo'], extra: true },
  { campo: 'perecedero', titulo: 'Perecedero (SI/NO)', alias: ['perecedero', 'perecedero si no'], extra: true },
];

// ---------------------------------------------------------------------------
// Unidades de medida validas. Se guarda el nombre estandar (`valor`); en el
// archivo se aceptan sus variantes comunes.
// ---------------------------------------------------------------------------

export const UNIDADES = [
  { valor: 'unidad', alias: ['unidad', 'unidades', 'un', 'u', 'unid', 'uni'] },
  { valor: 'kg', alias: ['kg', 'kgs', 'kilo', 'kilos', 'kilogramo', 'kilogramos'] },
  { valor: 'g', alias: ['g', 'gr', 'grs', 'gramo', 'gramos'] },
  { valor: 'litro', alias: ['litro', 'litros', 'l', 'lt', 'lts'] },
  { valor: 'ml', alias: ['ml', 'mililitro', 'mililitros', 'cc'] },
  { valor: 'metro', alias: ['metro', 'metros', 'm', 'mt', 'mts'] },
  { valor: 'pack', alias: ['pack', 'packs'] },
  { valor: 'caja', alias: ['caja', 'cajas'] },
  { valor: 'docena', alias: ['docena', 'docenas', 'doc'] },
];

export const UNIDADES_VALIDAS = UNIDADES.map((u) => u.valor);

// ---------------------------------------------------------------------------
// Celdas. Una celda es { valor, texto, tipo } o null (celda sin contenido).
//   valor: lo que guarda el archivo (numero o texto)
//   texto: lo que se ve en pantalla (formato de Excel, ej. "7,79E+12")
//   tipo:  't' texto, 'n' numero, 'b' booleano (como en SheetJS)
// ---------------------------------------------------------------------------

// Pasa una hoja de SheetJS a una matriz de celdas. `utils` es XLSX.utils (se
// recibe como parametro para que este archivo no dependa de la libreria).
export function celdasDeHoja(hoja, utils) {
  if (!hoja || !hoja['!ref']) return [];
  const rango = utils.decode_range(hoja['!ref']);
  const filas = [];
  for (let r = rango.s.r; r <= rango.e.r; r++) {
    const fila = [];
    for (let c = rango.s.c; c <= rango.e.c; c++) {
      const celda = hoja[utils.encode_cell({ r, c })];
      fila.push(celda ? { valor: celda.v, texto: celda.w ?? String(celda.v ?? ''), tipo: celda.t } : null);
    }
    filas.push({ numero: r + 1, celdas: fila });
  }
  return filas;
}

const vacia = (celda) => !celda || celda.valor === undefined || celda.valor === null || String(celda.valor).trim() === '';

// Texto de una celda tal como lo escribio la persona. Un numero entero se
// pasa sin decimales ni notacion cientifica.
function textoDe(celda) {
  if (vacia(celda)) return '';
  if (celda.tipo === 'n') {
    return String(celda.valor);
  }
  return String(celda.valor).trim();
}

// ---------------------------------------------------------------------------
// Parsers por campo. Todos devuelven { valor } o { error }.
// ---------------------------------------------------------------------------

// Precio / cantidades: acepta "$ 1.234,50", "1234.5", "1,234.50", "1500", numeros
// del archivo. Si hay coma y punto, el ultimo es el decimal. Si hay uno solo
// seguido de exactamente 3 digitos (y 1-3 digitos antes) se toma como separador
// de miles ("1.234" = 1234), porque ningun precio lleva 3 decimales.
export function parseNumero(celda, { etiqueta = 'El valor' } = {}) {
  if (vacia(celda)) return { valor: null };
  if (celda.tipo === 'n') {
    if (!Number.isFinite(celda.valor)) return { error: `${etiqueta} no es un número válido` };
    if (celda.valor < 0) return { error: `${etiqueta} no puede ser negativo` };
    return { valor: celda.valor };
  }
  let s = String(celda.valor).trim().replace(/\s+/g, '').replace(/^(\$|ars|usd)/i, '').replace(/(\$|ars)$/i, '');
  if (!/^[\d.,]+$/.test(s)) return { error: `${etiqueta} "${String(celda.valor).trim()}" no es un número` };
  const ultimoPunto = s.lastIndexOf('.');
  const ultimaComa = s.lastIndexOf(',');
  if (ultimoPunto !== -1 && ultimaComa !== -1) {
    const decimal = ultimoPunto > ultimaComa ? '.' : ',';
    const miles = decimal === '.' ? ',' : '.';
    s = s.split(miles).join('').replace(decimal, '.');
  } else if (ultimoPunto !== -1 || ultimaComa !== -1) {
    const sep = ultimoPunto !== -1 ? '.' : ',';
    const partes = s.split(sep);
    const hayVarios = partes.length > 2;
    const esMiles = hayVarios || (partes[1].length === 3 && partes[0].length >= 1 && partes[0].length <= 3);
    s = esMiles ? partes.join('') : partes.join('.');
  }
  const n = Number(s);
  if (!Number.isFinite(n) || s === '') return { error: `${etiqueta} "${String(celda.valor).trim()}" no es un número` };
  return { valor: n };
}

// Codigo de barras: siempre texto. Rechaza lo que llego en notacion cientifica
// (Excel lo hace con numeros largos y pierde digitos) en vez de guardarlo mal.
export function parseCodigo(celda) {
  if (vacia(celda)) return { valor: null };
  if (celda.tipo === 'n') {
    const n = celda.valor;
    const texto = String(celda.texto ?? '');
    if (!Number.isInteger(n) || n < 0) return { error: `Código de barras "${texto}" no es un número entero` };
    const digitos = String(n);
    if (digitos.length > 15) return { error: 'Código de barras con más de 15 dígitos: Excel pierde precisión, cargalo como texto' };
    // Celda numerica que Excel muestra en notacion cientifica y termina en
    // varios ceros: casi seguro perdio digitos (un codigo real no termina asi).
    if (/e[+-]?\d+/i.test(texto) && /0{4,}$/.test(digitos)) {
      return { error: `Código de barras en notación científica ("${texto}"): se perdieron dígitos. Formateá la columna como Texto y volvé a cargarlo` };
    }
    return { valor: digitos };
  }
  const texto = String(celda.valor).trim();
  if (/^\d+(?:[.,]\d+)?\s*e\s*[+-]?\s*\d+$/i.test(texto)) {
    return { error: `Código de barras en notación científica ("${texto}"): se perdieron dígitos. Formateá la columna como Texto y volvé a cargarlo` };
  }
  return { valor: texto };
}

export function parseUnidad(celda) {
  if (vacia(celda)) return { valor: null };
  const buscada = normalizar(textoDe(celda));
  const unidad = UNIDADES.find((u) => u.alias.includes(buscada));
  if (!unidad) return { error: `Unidad de medida "${textoDe(celda)}" no es válida (valores válidos: ${UNIDADES_VALIDAS.join(', ')})` };
  return { valor: unidad.valor };
}

export function parsePerecedero(celda) {
  if (vacia(celda)) return { valor: null };
  if (celda.tipo === 'b') return { valor: !!celda.valor };
  const t = normalizar(textoDe(celda));
  if (['si', 's', '1', 'true', 'verdadero', 'x'].includes(t)) return { valor: true };
  if (['no', 'n', '0', 'false', 'falso'].includes(t)) return { valor: false };
  return { error: `Perecedero "${textoDe(celda)}" no es SI ni NO` };
}

// ---------------------------------------------------------------------------
// Analisis completo del archivo
// ---------------------------------------------------------------------------

// filas: salida de celdasDeHoja().
// contexto: {
//   productos:  productos vivos del local [{ id, nombre, presentacion, unidad_medida, codigo_barras,
//               precio_venta_actual, categoria_id, stock_minimo, perecedero }]
//   categorias: categorias del local [{ id, nombre }]
// }
export function analizarImportacion(filas, contexto) {
  const productos = contexto?.productos || [];
  const categorias = contexto?.categorias || [];

  // 1) fila de encabezados: la primera con algo escrito
  const indiceEncabezado = filas.findIndex((f) => f.celdas.some((c) => !vacia(c)));
  if (indiceEncabezado === -1) return { errorGlobal: 'El archivo está vacío: no tiene encabezados ni filas.' };
  const encabezado = filas[indiceEncabezado];

  // 2) mapear cada columna por su titulo
  const columnaDe = {}; // campo -> indice de columna
  const reconocidas = [];
  const ignoradas = [];
  encabezado.celdas.forEach((celda, indice) => {
    if (vacia(celda)) return;
    const titulo = textoDe(celda);
    const buscado = normalizar(titulo);
    const definicion = COLUMNAS.find((c) => c.alias.includes(buscado));
    if (!definicion) {
      ignoradas.push({ titulo, motivo: 'no se reconoce' });
    } else if (columnaDe[definicion.campo] !== undefined) {
      ignoradas.push({ titulo, motivo: `repite la columna ${definicion.titulo}` });
    } else {
      columnaDe[definicion.campo] = indice;
      reconocidas.push({ titulo, campo: definicion.campo, tituloEstandar: definicion.titulo });
    }
  });
  if (columnaDe.nombre === undefined) {
    return {
      errorGlobal: 'No se encontró la columna Nombre (también se acepta: Producto, Descripción). Revisá los encabezados de la primera fila.',
      columnas: { reconocidas, ignoradas },
    };
  }
  const opcionalesAusentes = COLUMNAS.filter((c) => !c.extra && !c.obligatoria && columnaDe[c.campo] === undefined).map((c) => c.titulo);
  const tiene = (campo) => columnaDe[campo] !== undefined;
  const celdaDe = (fila, campo) => (tiene(campo) ? fila.celdas[columnaDe[campo]] ?? null : null);

  // 3) indices del estado actual del local
  const porId = new Map(productos.map((p) => [p.id, p]));
  const porCodigo = new Map(productos.filter((p) => p.codigo_barras).map((p) => [p.codigo_barras, p]));
  const categoriaPorNombre = new Map(categorias.map((c) => [normalizar(c.nombre), c]));
  // nombre + presentacion de lo ya cargado: para avisar si el archivo trae
  // productos nuevos que parecen repetidos (no es error: puede ser a proposito)
  const clave = (nombre, presentacion) => normalizar(nombre) + '|' + normalizar(presentacion);
  const clavesExistentes = new Set(productos.map((p) => clave(p.nombre, p.presentacion)));
  const clavesNuevas = new Set();
  const parecenRepetidos = [];

  const resultado = [];
  const categoriasFaltantes = new Set();
  const codigosEnArchivo = new Map(); // codigo -> numero de fila
  const idsEnArchivo = new Map();
  let ignoradasSinNombre = 0;
  let filasSinPrecio = 0;
  let stockIgnoradoEnActualizacion = false;

  for (const fila of filas.slice(indiceEncabezado + 1)) {
    const hayAlgo = fila.celdas.some((c) => !vacia(c));
    if (!hayAlgo) continue; // fila totalmente vacia: ni se cuenta
    const nombre = textoDe(celdaDe(fila, 'nombre'));
    if (!nombre) {
      ignoradasSinNombre++;
      continue;
    }

    const errores = [];
    const datos = {}; // campos de la base presentes en el archivo y con valor
    const aplicar = (campoArchivo, campoBase, parser, opciones) => {
      if (!tiene(campoArchivo)) return;
      const r = parser(celdaDe(fila, campoArchivo), opciones);
      if (r.error) errores.push(r.error);
      else if (r.valor !== null) datos[campoBase] = r.valor;
    };
    datos.nombre = nombre;
    if (tiene('presentacion') && !vacia(celdaDe(fila, 'presentacion'))) datos.presentacion = textoDe(celdaDe(fila, 'presentacion'));
    // la unidad se valida mas abajo, cuando se sabe a que producto corresponde
    let errorUnidad = null;
    if (tiene('unidad_medida')) {
      const r = parseUnidad(celdaDe(fila, 'unidad_medida'));
      if (r.error) errorUnidad = { mensaje: r.error, texto: textoDe(celdaDe(fila, 'unidad_medida')) };
      else if (r.valor !== null) datos.unidad_medida = r.valor;
    }
    aplicar('codigo_barras', 'codigo_barras', parseCodigo);
    aplicar('precio', 'precio_venta_actual', parseNumero, { etiqueta: 'El precio' });
    aplicar('stock_actual', 'stock_actual', parseNumero, { etiqueta: 'El stock actual' });
    aplicar('stock_minimo', 'stock_minimo', parseNumero, { etiqueta: 'El stock mínimo' });
    aplicar('perecedero', 'perecedero', parsePerecedero);

    // categoria: tiene que existir en el local
    if (tiene('categoria') && !vacia(celdaDe(fila, 'categoria'))) {
      const nombreCategoria = textoDe(celdaDe(fila, 'categoria'));
      const categoria = categoriaPorNombre.get(normalizar(nombreCategoria));
      if (!categoria) {
        categoriasFaltantes.add(nombreCategoria);
        errores.push(`La categoría "${nombreCategoria}" no existe en este local`);
      } else {
        datos.categoria_id = categoria.id;
      }
    }

    // a que producto corresponde: por ID, o por codigo de barras si existe
    let objetivo = null;
    const idTexto = tiene('id') ? textoDe(celdaDe(fila, 'id')) : '';
    if (idTexto) {
      objetivo = porId.get(idTexto) || null;
      if (!objetivo) errores.push(`El ID "${idTexto}" no corresponde a un producto de este local`);
      else if (idsEnArchivo.has(idTexto)) errores.push(`El ID está repetido en el archivo (ya aparece en la fila ${idsEnArchivo.get(idTexto)})`);
      else idsEnArchivo.set(idTexto, fila.numero);
    }
    if (datos.codigo_barras) {
      const duenio = porCodigo.get(datos.codigo_barras);
      if (!idTexto && duenio) objetivo = duenio;
      else if (idTexto && objetivo && duenio && duenio.id !== objetivo.id) {
        errores.push(`El código de barras ya lo usa otro producto del local ("${duenio.nombre}")`);
      }
      if (codigosEnArchivo.has(datos.codigo_barras)) {
        errores.push(`El código de barras está repetido en el archivo (ya aparece en la fila ${codigosEnArchivo.get(datos.codigo_barras)})`);
      } else {
        codigosEnArchivo.set(datos.codigo_barras, fila.numero);
      }
    }
    // Unidad fuera de la lista: es error, salvo que sea exactamente la que el
    // producto ya tiene (unidades cargadas a mano antes de existir la lista).
    if (errorUnidad && !(objetivo && normalizar(objetivo.unidad_medida) === normalizar(errorUnidad.texto))) {
      errores.push(errorUnidad.mensaje);
    }
    // un producto que ya aparecio por codigo de barras no puede repetirse por otra fila sin codigo
    if (!idTexto && objetivo && idsEnArchivo.has(objetivo.id) && !errores.length) {
      errores.push(`Este producto ya se actualiza en la fila ${idsEnArchivo.get(objetivo.id)}`);
    }
    if (objetivo && !errores.length) idsEnArchivo.set(objetivo.id, idsEnArchivo.get(objetivo.id) ?? fila.numero);

    const base = { numero: fila.numero, nombre, errores, advertencias: [] };
    if (errores.length) {
      resultado.push({ ...base, accion: 'error' });
      continue;
    }

    if (objetivo) {
      // actualizar: solo lo que vino con valor. Una celda vacia NO borra el dato actual.
      const cambios = {};
      const comparar = (campo, actual) => {
        if (!(campo in datos)) return;
        const nuevo = datos[campo];
        const texto = (v) => (typeof v === 'string' ? v.trim() : v ?? null);
        const igual = typeof nuevo === 'number' ? Number(actual) === nuevo : texto(nuevo) === texto(actual);
        if (!igual) cambios[campo] = nuevo;
      };
      comparar('nombre', objetivo.nombre);
      comparar('presentacion', objetivo.presentacion);
      comparar('unidad_medida', objetivo.unidad_medida);
      comparar('codigo_barras', objetivo.codigo_barras);
      comparar('precio_venta_actual', objetivo.precio_venta_actual);
      comparar('categoria_id', objetivo.categoria_id);
      comparar('stock_minimo', objetivo.stock_minimo);
      comparar('perecedero', objetivo.perecedero);
      if ('stock_actual' in datos) stockIgnoradoEnActualizacion = true;
      resultado.push({
        ...base,
        accion: Object.keys(cambios).length ? 'actualizar' : 'sin_cambios',
        objetivoId: objetivo.id,
        datos: cambios,
        // lo que ya tenia, para mostrar "antes → despues" si se quiere
        actuales: { nombre: objetivo.nombre, presentacion: objetivo.presentacion },
      });
    } else {
      const sinPrecio = !('precio_venta_actual' in datos);
      if (sinPrecio) filasSinPrecio++;
      const k = clave(nombre, datos.presentacion);
      if (clavesExistentes.has(k) || clavesNuevas.has(k)) {
        parecenRepetidos.push(`fila ${fila.numero}: ${datos.presentacion ? nombre + ' · ' + datos.presentacion : nombre}`);
      }
      clavesNuevas.add(k);
      resultado.push({
        ...base,
        accion: 'crear',
        datos: {
          nombre,
          presentacion: datos.presentacion ?? null,
          unidad_medida: datos.unidad_medida ?? null,
          codigo_barras: datos.codigo_barras ?? null,
          categoria_id: datos.categoria_id ?? null,
          precio_venta_actual: datos.precio_venta_actual ?? 0,
          stock_actual: datos.stock_actual ?? 0,
          stock_minimo: datos.stock_minimo ?? 0,
          perecedero: datos.perecedero ?? false,
        },
      });
    }
  }

  const advertencias = [];
  if (ignoradas.length) advertencias.push(`Se ignoraron ${ignoradas.length} columna(s): ${ignoradas.map((i) => `"${i.titulo}" (${i.motivo})`).join(', ')}.`);
  if (stockIgnoradoEnActualizacion) advertencias.push('"Stock actual" no se aplica a productos que ya existen: el stock cambia solo con "Ajustar stock" o "Reponer stock", para que quede registrado.');
  if (parecenRepetidos.length) {
    const muestra = parecenRepetidos.slice(0, 5).join('; ') + (parecenRepetidos.length > 5 ? '…' : '');
    advertencias.push(
      `${parecenRepetidos.length} producto(s) nuevo(s) tienen el mismo nombre y presentación que uno ya cargado o repetido en el archivo (${muestra}). Se van a crear igual; si querés actualizarlos en vez de duplicarlos, exportá la lista, completala y volvé a importarla con la columna ID.`
    );
  }
  if (filasSinPrecio) advertencias.push(`${filasSinPrecio} producto(s) nuevo(s) vienen sin precio y se cargan en $0 (podés editarlos después).`);

  const cuenta = (accion) => resultado.filter((f) => f.accion === accion).length;
  return {
    columnas: { reconocidas, ignoradas, opcionalesAusentes },
    filas: resultado,
    categoriasFaltantes: [...categoriasFaltantes],
    advertencias,
    resumen: {
      leidas: resultado.length + ignoradasSinNombre,
      aCrear: cuenta('crear'),
      aActualizar: cuenta('actualizar'),
      sinCambios: cuenta('sin_cambios'),
      conError: cuenta('error'),
      ignoradasSinNombre,
    },
  };
}

// ---------------------------------------------------------------------------
// Exportacion y plantilla. Usan LOS MISMOS titulos que la importacion (salen de
// COLUMNAS), asi lo exportado vuelve a importarse sin cambios.
// ---------------------------------------------------------------------------

// Orden del archivo: las 6 columnas basicas, luego stock/perecedero, y el ID al
// final (identifica el producto al volver a importar; no hace falta tocarlo).
const CAMPOS_EXPORTACION = ['nombre', 'presentacion', 'unidad_medida', 'codigo_barras', 'precio', 'categoria', 'stock_actual', 'stock_minimo', 'perecedero', 'id'];
export const COLUMNAS_EXPORTACION = CAMPOS_EXPORTACION.map((campo) => COLUMNAS.find((c) => c.campo === campo));
const COLUMNAS_PLANTILLA = COLUMNAS_EXPORTACION.filter((c) => c.campo !== 'id');
const CAMPOS_TEXTO = ['codigo_barras', 'id']; // siempre texto, para no perder ceros ni pasar a notacion cientifica

function valorExportado(campo, p) {
  switch (campo) {
    case 'id':
      return p.id;
    case 'nombre':
      return p.nombre ?? '';
    case 'presentacion':
      return p.presentacion ?? '';
    case 'unidad_medida':
      return p.unidad_medida ?? '';
    case 'codigo_barras':
      return p.codigo_barras ?? '';
    case 'precio':
      return Number(p.precio_venta_actual);
    case 'categoria':
      return p.categorias?.nombre ?? '';
    case 'stock_actual':
      return Number(p.stock_actual);
    case 'stock_minimo':
      return Number(p.stock_minimo);
    case 'perecedero':
      return p.perecedero ? 'SI' : 'NO';
    default:
      return '';
  }
}

// Marca como TEXTO las celdas de una columna (y las deja formateadas como texto
// para que, si se edita en Excel, el codigo siga siendo texto).
function columnaComoTexto(hoja, utils, indiceColumna, desdeFila, hastaFila) {
  for (let r = desdeFila; r <= hastaFila; r++) {
    const ref = utils.encode_cell({ r, c: indiceColumna });
    const celda = hoja[ref] || (hoja[ref] = { t: 's', v: '' });
    celda.t = 's';
    celda.v = String(celda.v ?? '');
    celda.z = '@';
    delete celda.w;
  }
}

// Hoja "Productos" para exportar. productos: filas de la tabla (con
// categorias(nombre)). utils: XLSX.utils.
export function construirHojaProductos(utils, productos) {
  const encabezados = COLUMNAS_EXPORTACION.map((c) => c.titulo);
  const filas = productos.map((p) => Object.fromEntries(COLUMNAS_EXPORTACION.map((c) => [c.titulo, valorExportado(c.campo, p)])));
  const hoja = utils.json_to_sheet(filas, { header: encabezados });
  CAMPOS_TEXTO.forEach((campo) => {
    const indice = CAMPOS_EXPORTACION.indexOf(campo);
    columnaComoTexto(hoja, utils, indice, 1, productos.length);
  });
  hoja['!cols'] = COLUMNAS_EXPORTACION.map((c) => ({ wch: { nombre: 32, presentacion: 16, unidad_medida: 12, codigo_barras: 18, precio: 12, categoria: 16, stock_actual: 12, stock_minimo: 12, perecedero: 18, id: 38 }[c.campo] }));
  return hoja;
}

// Hoja "Productos" de la plantilla vacia: solo encabezados, y la columna del
// codigo de barras ya formateada como texto (500 filas) para que Excel no la
// convierta a numero.
export function construirHojaPlantilla(utils, filasPreformateadas = 500) {
  const encabezados = COLUMNAS_PLANTILLA.map((c) => c.titulo);
  const hoja = utils.aoa_to_sheet([encabezados]);
  columnaComoTexto(hoja, utils, COLUMNAS_PLANTILLA.findIndex((c) => c.campo === 'codigo_barras'), 1, filasPreformateadas);
  hoja['!ref'] = utils.encode_range({ s: { r: 0, c: 0 }, e: { r: filasPreformateadas, c: encabezados.length - 1 } });
  hoja['!cols'] = COLUMNAS_PLANTILLA.map((c) => ({ wch: Math.max(14, c.titulo.length + 2) }));
  return hoja;
}

// Segunda hoja de la plantilla: instrucciones (la importacion lee solo la primera).
export function construirHojaInstrucciones(utils) {
  const filas = [
    ['Cómo completar la hoja "Productos"'],
    [''],
    ['Columna', 'Qué va', 'También se acepta como título'],
    ...COLUMNAS_PLANTILLA.map((c) => [
      c.titulo,
      {
        nombre: 'Nombre del producto (obligatorio). Las filas sin nombre se ignoran.',
        presentacion: 'El tamaño o contenido del envase: 500 ml, 1,5 L, 354 ml (lata), 1 kg.',
        unidad_medida: `Cómo se cuenta o vende: ${UNIDADES_VALIDAS.join(', ')}. Opcional.`,
        codigo_barras: 'Opcional. Se guarda como texto (conserva los ceros del principio). Si lo dejás vacío se importa igual.',
        precio: 'Precio de venta. Acepta coma o punto decimal y el símbolo $. Vacío = $0.',
        categoria: 'Tiene que existir ya en el local (se crean desde Nuevo producto → + Nueva). Si no existe, la fila da error.',
        stock_actual: 'Opcional. Stock inicial de los productos nuevos (en los que ya existen no se usa: se ajusta desde la lista).',
        stock_minimo: 'Opcional. Avisa cuando el stock baja de este número.',
        perecedero: 'Opcional. SI o NO.',
      }[c.campo],
      // los alias se guardan normalizados (sin tildes); aca se muestran como se escriben
      {
        nombre: 'Producto, Descripción',
        presentacion: 'Tamaño, Contenido',
        unidad_medida: 'Unidad, Medida, UM',
        codigo_barras: 'Código, EAN, Barcode',
        precio: 'Precio de venta',
        categoria: 'Rubro',
        stock_actual: 'Stock',
        stock_minimo: '',
        perecedero: '',
      }[c.campo],
    ]),
    [''],
    ['Para modificar productos que ya están cargados: usá "Exportar", completá lo que quieras en el Excel (sin borrar la columna ID) y volvé a importarlo. Los datos que dejes vacíos no se borran.'],
  ];
  const hoja = utils.aoa_to_sheet(filas);
  hoja['!cols'] = [{ wch: 20 }, { wch: 95 }, { wch: 34 }];
  return hoja;
}
