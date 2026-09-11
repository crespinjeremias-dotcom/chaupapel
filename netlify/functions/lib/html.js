// Mismo escapeHtml que public/js/utils.js -- no se puede importar ese
// archivo directo desde una function (ver netlify/functions/lib/planes.js),
// asi que se duplica la implementacion, que es minima.
const ESCAPES_HTML = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };

export function escapeHtml(texto) {
  return String(texto ?? '').replace(/[&<>"']/g, (c) => ESCAPES_HTML[c]);
}
