import { obtenerVentaConDetalle } from './ventas.js';
import { escapeHtml } from './utils.js';

const ETIQUETA_METODO = { efectivo: 'Efectivo', transferencia: 'Transferencia' };

// Comprobante no fiscal dentro de un modal de la misma pagina. Antes era
// comprobante.html abierto con target="_blank": en el TWA (APK) eso saca a
// quien vende de la app y lo tira a una pestana de Chrome con barra de URL.
// Tampoco se puede resolver con un iframe: netlify.toml manda
// X-Frame-Options: DENY / frame-ancestors 'none' en todo el sitio, asi que
// el iframe quedaria en blanco en produccion (aunque en local, sin esas
// cabeceras, parezca andar). Por eso se dibuja directo en el DOM.
function asegurarModal() {
  let overlay = document.getElementById('modal-comprobante');
  if (overlay) return overlay;

  overlay = document.createElement('div');
  overlay.className = 'modal-overlay';
  overlay.id = 'modal-comprobante';
  overlay.hidden = true;
  overlay.innerHTML = `
    <div class="modal modal-comprobante">
      <p class="mensaje-error no-imprimir" id="error-comprobante" hidden></p>
      <p class="texto-suave no-imprimir" id="cargando-comprobante">Cargando comprobante...</p>
      <div class="comprobante" id="comprobante" hidden>
        <h1 id="c-local"></h1>
        <p class="c-fecha" id="c-fecha"></p>
        <p class="c-vendedor" id="c-vendedor"></p>
        <table class="c-tabla-items">
          <thead>
            <tr><th>Producto</th><th>Cant.</th><th>P. unit.</th><th>Subtotal</th></tr>
          </thead>
          <tbody id="c-items"></tbody>
        </table>
        <div class="c-total"><span>Total</span><span id="c-total-valor"></span></div>
        <p class="c-pago" id="c-pago"></p>
        <p class="c-leyenda">Comprobante no válido como factura.</p>
      </div>
      <div class="modal-acciones no-imprimir">
        <button type="button" class="boton-secundario" id="btn-cerrar-comprobante">Cerrar</button>
        <button type="button" class="boton-primario" id="btn-imprimir-comprobante" disabled>Imprimir / Guardar como PDF</button>
      </div>
    </div>
  `;
  document.body.appendChild(overlay);

  overlay.addEventListener('click', (e) => {
    if (e.target === overlay) cerrarComprobante();
  });
  overlay.querySelector('#btn-cerrar-comprobante').addEventListener('click', cerrarComprobante);
  overlay.querySelector('#btn-imprimir-comprobante').addEventListener('click', () => window.print());
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && !overlay.hidden) cerrarComprobante();
  });
  return overlay;
}

export function cerrarComprobante() {
  const overlay = document.getElementById('modal-comprobante');
  if (overlay) overlay.hidden = true;
  document.body.classList.remove('comprobante-abierto');
}

export async function mostrarComprobante(ventaId, { nombreLocal = '' } = {}) {
  const overlay = asegurarModal();
  const errorEl = overlay.querySelector('#error-comprobante');
  const cargandoEl = overlay.querySelector('#cargando-comprobante');
  const comprobanteEl = overlay.querySelector('#comprobante');
  const btnImprimir = overlay.querySelector('#btn-imprimir-comprobante');

  errorEl.hidden = true;
  cargandoEl.hidden = false;
  comprobanteEl.hidden = true;
  btnImprimir.disabled = true;
  document.body.classList.add('comprobante-abierto');
  overlay.hidden = false;

  try {
    const { venta, items, pagos } = await obtenerVentaConDetalle(ventaId);

    overlay.querySelector('#c-local').textContent = nombreLocal;
    overlay.querySelector('#c-fecha').textContent = new Date(venta.fecha).toLocaleString('es-AR');
    overlay.querySelector('#c-vendedor').textContent = `Atendido por: ${venta.usuarios?.nombre || '—'}`;
    overlay.querySelector('#c-items').innerHTML = items
      .map(
        (it) => `
        <tr>
          <td>${escapeHtml(it.productos?.nombre || 'Producto eliminado')}</td>
          <td>${it.cantidad}</td>
          <td>$${Number(it.precio_unitario).toLocaleString('es-AR')}</td>
          <td>$${Number(it.subtotal).toLocaleString('es-AR')}</td>
        </tr>`
      )
      .join('');
    overlay.querySelector('#c-total-valor').textContent = `$${Number(venta.total).toLocaleString('es-AR')}`;
    overlay.querySelector('#c-pago').textContent = venta.es_fiado
      ? `Fiado — cliente: ${venta.clientes?.nombre || '—'}`
      : pagos.map((p) => `${ETIQUETA_METODO[p.metodo]}: $${Number(p.monto).toLocaleString('es-AR')}`).join(' · ');

    comprobanteEl.hidden = false;
    btnImprimir.disabled = false;
  } catch (err) {
    errorEl.textContent = err.message;
    errorEl.hidden = false;
  } finally {
    cargandoEl.hidden = true;
  }
}
