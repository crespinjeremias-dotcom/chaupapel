import { logout } from './auth.js';
import { listarLocales } from './empleados.js';
import { obtenerLocalActivo, establecerLocalActivo } from './localActivo.js';
import { escapeHtml } from './utils.js';

// Construye la lista de items del menu segun rol. Los items marcados
// proximamente quedan visibles pero deshabilitados -- todavia no existe esa
// pantalla (Fases futuras), y prefiero mostrar la estructura completa que
// pide el menu antes que ocultar secciones sin avisar que van a existir.
function construirItems(usuario) {
  const esAdmin = usuario.role === 'admin';
  const items = [];

  if (esAdmin) items.push({ label: 'Dashboard', href: 'panel.html' });

  items.push({ label: 'Panel de ventas', href: 'ventas.html' });
  items.push({ label: esAdmin ? 'Historial de ventas' : 'Historial de mis ventas', href: 'historial-ventas.html' });

  if (usuario.locales?.fiado_habilitado !== false) {
    items.push({ label: 'Cuenta corriente de clientes', href: 'clientes.html' });
  }

  items.push({ label: esAdmin ? 'Productos' : 'Productos y reposición de stock', href: 'productos.html' });
  if (esAdmin) items.push({ label: 'Proveedores', href: 'proveedores.html' });

  items.push({ label: esAdmin ? 'Caja' : 'Cierre de turno', href: esAdmin ? 'caja.html' : 'ventas.html' });
  items.push({ label: 'Alertas de stock bajo', href: 'alertas-stock.html' });

  if (esAdmin) {
    items.push({ label: 'Reportes y estadísticas', href: 'reportes.html' });
    items.push({ label: 'Gestión de empleados', href: 'panel.html' });
    items.push({ label: 'Configuración del local', proximamente: true });
  }

  return items;
}

export async function montarMenu(usuario) {
  const header = document.querySelector('.app-header');
  if (!header) return;

  const items = construirItems(usuario);

  // Selector de local activo (seccion 1 y 13, multi-local): solo tiene
  // sentido si el admin realmente tiene mas de un local. Se guarda en
  // localStorage y recarga la pagina para que la logica de cada pantalla
  // (que lee obtenerLocalActivo al iniciar) tome el cambio.
  let locales = [];
  if (usuario.role === 'admin') {
    try {
      locales = await listarLocales();
    } catch {
      // si falla, simplemente no se muestra el selector
    }
  }

  const boton = document.createElement('button');
  boton.type = 'button';
  boton.className = 'boton-hamburguesa';
  boton.setAttribute('aria-label', 'Abrir menú');
  boton.innerHTML = '<span></span><span></span><span></span>';
  header.insertBefore(boton, header.firstChild);

  const overlay = document.createElement('div');
  overlay.className = 'menu-overlay';
  overlay.hidden = true;

  const drawer = document.createElement('div');
  drawer.className = 'menu-drawer';
  drawer.hidden = true;

  const nombreLocal = usuario.locales?.nombre || usuario.organizations?.nombre || 'Menú';

  const itemsHtml = items
    .map((item) => {
      if (item.proximamente) {
        const etiqueta = typeof item.proximamente === 'string' ? item.proximamente : 'Próximamente';
        return `<li><span class="menu-item-proximamente">${item.label}<span class="etiqueta">${etiqueta}</span></span></li>`;
      }
      return `<li><a href="${item.href}">${item.label}</a></li>`;
    })
    .join('');

  const selectorLocalHtml =
    locales.length > 1
      ? `<div class="menu-selector-local">
           <label for="menu-select-local">Local activo</label>
           <select id="menu-select-local">
             ${locales.map((l) => `<option value="${l.id}">${escapeHtml(l.nombre)}</option>`).join('')}
           </select>
         </div>`
      : '';

  drawer.innerHTML = `
    <div class="menu-drawer-header">
      <h2>${nombreLocal}</h2>
      <button type="button" id="menu-btn-cerrar" aria-label="Cerrar menú">×</button>
    </div>
    ${selectorLocalHtml}
    <ul class="menu-lista">
      ${itemsHtml}
      <li class="menu-separador"></li>
      <li class="menu-cerrar-sesion"><button type="button" id="menu-btn-logout">Cerrar sesión</button></li>
    </ul>
  `;

  document.body.appendChild(overlay);
  document.body.appendChild(drawer);

  if (locales.length > 1) {
    const selectLocal = drawer.querySelector('#menu-select-local');
    selectLocal.value = obtenerLocalActivo(locales);
    selectLocal.addEventListener('change', () => {
      establecerLocalActivo(selectLocal.value);
      window.location.reload();
    });
  }

  function abrir() {
    overlay.hidden = false;
    drawer.hidden = false;
  }
  function cerrar() {
    overlay.hidden = true;
    drawer.hidden = true;
  }

  boton.addEventListener('click', abrir);
  overlay.addEventListener('click', cerrar);
  drawer.querySelector('#menu-btn-cerrar').addEventListener('click', cerrar);
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') cerrar();
  });
  drawer.querySelector('#menu-btn-logout').addEventListener('click', async () => {
    await logout();
    window.location.href = 'index.html';
  });
}
