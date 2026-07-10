import { BrowserMultiFormatReader } from 'https://cdn.jsdelivr.net/npm/@zxing/browser@latest/+esm';

let lector = null;

// Arranca la camara sobre el <video> dado y llama a onDetectado(texto) en
// cuanto lee un codigo. Requiere permiso de camara del navegador -- en
// desktop sin camara o si el usuario lo rechaza, se rechaza la promesa.
export async function iniciarEscaneo(videoEl, onDetectado, onError) {
  lector = new BrowserMultiFormatReader();
  const dispositivos = await BrowserMultiFormatReader.listVideoInputDevices();
  const deviceId = dispositivos[dispositivos.length - 1]?.deviceId;

  lector.decodeFromVideoDevice(deviceId, videoEl, (resultado, error) => {
    if (resultado) {
      onDetectado(resultado.getText());
    } else if (error && error.name !== 'NotFoundException') {
      onError?.(error);
    }
  });
}

export function detenerEscaneo() {
  lector?.reset();
  lector = null;
}
