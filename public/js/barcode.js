// Version fijas (no "latest"): @zxing/browser@0.2.1 no expone reset() en
// BrowserMultiFormatReader -- la limpieza es via el objeto "controls" que
// devuelven los metodos decodeFrom*. Usar "latest" fue justamente lo que
// rompio esto en produccion cuando la libreria actualizo su API.
import { BrowserMultiFormatReader } from 'https://cdn.jsdelivr.net/npm/@zxing/browser@0.2.1/+esm';
import { BarcodeFormat, DecodeHintType } from 'https://cdn.jsdelivr.net/npm/@zxing/library@0.23.0/+esm';

// Formatos relevantes para productos de almacen: EAN/UPC (codigos de fabrica
// impresos de origen) + Code128 (por si algun proveedor usa codigos internos).
// Sin esto, el lector intenta TODOS los formatos que soporta (QR, PDF417,
// Aztec, Data Matrix, etc.), lo que baja la tasa de deteccion y la velocidad.
const FORMATOS_SOPORTADOS = [
  BarcodeFormat.EAN_13,
  BarcodeFormat.EAN_8,
  BarcodeFormat.UPC_A,
  BarcodeFormat.UPC_E,
  BarcodeFormat.CODE_128,
];

// Excepciones "normales" que ZXing tira en casi cada frame mientras todavia
// no encontro un codigo (fotograma borroso, fuera de foco, sin codigo en
// cuadro). No son errores reales -- si se las reporta como error, la UI
// parece fallar constantemente aunque el escaneo este funcionando bien.
const ERRORES_ESPERADOS_POR_FRAME = new Set(['NotFoundException', 'ChecksumException', 'FormatException']);

let controlesActivos = null;

// Arranca la camara sobre el <video> dado y llama a onDetectado(texto) en
// cuanto lee un codigo. Requiere permiso de camara del navegador.
export async function iniciarEscaneo(videoEl, onDetectado, onError) {
  const hints = new Map();
  hints.set(DecodeHintType.POSSIBLE_FORMATS, FORMATOS_SOPORTADOS);
  hints.set(DecodeHintType.TRY_HARDER, true);

  const lector = new BrowserMultiFormatReader(hints);

  // facingMode "environment" pide la camara trasera explicitamente (antes
  // se adivinaba tomando "el ultimo dispositivo de la lista", que no es
  // confiable: el orden de enumeracion varia por navegador/dispositivo).
  // La resolucion ideal mas alta ayuda a resolver codigos en envases
  // curvos o con poco contraste (ej. retornables).
  const constraints = {
    video: {
      facingMode: { ideal: 'environment' },
      width: { ideal: 1280 },
      height: { ideal: 720 },
    },
  };

  controlesActivos = await lector.decodeFromConstraints(constraints, videoEl, (resultado, error) => {
    if (resultado) {
      onDetectado(resultado.getText());
    } else if (error && !ERRORES_ESPERADOS_POR_FRAME.has(error.name)) {
      onError?.(error);
    }
  });
}

// Nunca deja la camara "colgada": si algo falla al frenar el stream, lo
// avisa por consola pero no rompe la ejecucion de quien la llama (para que
// cerrar el modal de escaneo funcione siempre, se haya podido limpiar bien
// la camara o no).
export function detenerEscaneo() {
  try {
    controlesActivos?.stop();
  } catch (error) {
    console.warn('No se pudo detener el escaner de codigo de barras:', error);
  } finally {
    controlesActivos = null;
  }
}
