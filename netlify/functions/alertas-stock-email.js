// Digest diario de stock bajo (seccion 11, parte de Basico desde que se
// elimino el Plan Medio), disparado por el cron de netlify.toml (12:00 UTC
// = 9am Argentina). Un producto puede quedar
// por debajo del minimo en cualquier venta y seguir ahi por dias hasta que
// se repone -- mandar un email cada vez que se vende una unidad mas de un
// producto ya en alerta inundaria al admin, por eso es un resumen diario y
// no un email por evento.
//
// No hay un usuario logueado de quien tomar un JWT -- tiene que recorrer
// todas las organizaciones en una sola corrida -- por eso usa la service
// role key, igual que toggle-organizacion.js.
import { createClient } from '@supabase/supabase-js';
import { enviarEmail } from './lib/resend.js';
import { tieneFeatureServer } from './lib/planes.js';
import { escapeHtml } from './lib/html.js';

export async function handler(event) {
  // Netlify marca las invocaciones de un scheduled function con este header.
  // No pudimos verificar esto contra la documentacion oficial de Netlify
  // desde este entorno de desarrollo -- confirmar en el dashboard (Site
  // settings -> Functions -> alertas-stock-email) despues del primer deploy
  // que el cron haya quedado registrado, y que esta funcion efectivamente
  // corra sola. ALERTAS_STOCK_SECRET es la via de escape para probarla a
  // mano mientras tanto (GET .../alertas-stock-email?secret=...). El riesgo
  // de que alguien la invoque igual sin ninguna de las dos cosas es bajo: en
  // el peor caso, un digest de stock bajo mandado antes de tiempo -- no
  // expone datos nuevos ni hace nada destructivo.
  const esInvocacionProgramada = event.headers['x-nf-event'] === 'schedule';
  const secreto = process.env.ALERTAS_STOCK_SECRET;
  const pasaSecretoManual = Boolean(secreto) && event.queryStringParameters?.secret === secreto;
  if (!esInvocacionProgramada && !pasaSecretoManual) {
    return respuesta(403, { error: 'No autorizado' });
  }

  const supabaseUrl = process.env.SUPABASE_URL;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!supabaseUrl || !serviceRoleKey) {
    return respuesta(500, { error: 'Falta configurar SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY en Netlify' });
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false } });

  const { data: locales, error: localesError } = await admin
    .from('locales')
    .select('id, nombre, organization_id, bloqueado_por_plan, organizations(plan, plan_overrides, is_active)')
    .eq('alerta_stock_email', true)
    .eq('activo', true);
  if (localesError) return respuesta(500, { error: localesError.message });

  // bloqueado_por_plan (seccion 15) no se resetea solo cuando se apaga el
  // toggle -- un local puede quedar bloqueado con alerta_stock_email todavia
  // en true. local_is_active() no esta en las policies de select (solo en
  // insert/update/delete, ver migracion 20260911200000), asi que hay que
  // chequear la columna a mano aca.
  const localesElegibles = (locales || []).filter(
    (l) => !l.bloqueado_por_plan && l.organizations?.is_active !== false && tieneFeatureServer(l.organizations, 'email_stock_bajo')
  );

  let digestsEnviados = 0;
  for (const local of localesElegibles) {
    const { data: productos, error: productosError } = await admin
      .from('productos')
      .select('nombre, presentacion, stock_actual, stock_minimo, unidad_medida')
      .eq('local_id', local.id)
      .eq('activo', true)
      .is('deleted_at', null);
    if (productosError) {
      console.error(`alertas-stock-email: error leyendo productos del local ${local.id}: ${productosError.message}`);
      continue;
    }

    const conAlerta = (productos || []).filter((p) => Number(p.stock_actual) <= Number(p.stock_minimo));
    if (conAlerta.length === 0) continue;

    const { data: admins, error: adminsError } = await admin
      .from('usuarios')
      .select('email')
      .eq('organization_id', local.organization_id)
      .eq('role', 'admin')
      .eq('status', 'approved');
    if (adminsError) {
      console.error(`alertas-stock-email: error leyendo admins de la organizacion ${local.organization_id}: ${adminsError.message}`);
      continue;
    }
    const destinatarios = (admins || []).map((a) => a.email).filter(Boolean);
    if (destinatarios.length === 0) continue;

    const filas = conAlerta
      .map(
        (p) => `
        <tr>
          <td>${escapeHtml(p.nombre)}${p.presentacion ? ' · ' + escapeHtml(p.presentacion) : ''}</td>
          <td>${p.stock_actual} ${escapeHtml(p.unidad_medida || '')}</td>
          <td>${p.stock_minimo}</td>
        </tr>`
      )
      .join('');
    const html = `
      <h2>Stock bajo — ${escapeHtml(local.nombre)}</h2>
      <p>${conAlerta.length} producto${conAlerta.length === 1 ? '' : 's'} por debajo del stock mínimo:</p>
      <table cellpadding="6" style="border-collapse:collapse">
        <tr><th align="left">Producto</th><th align="left">Stock actual</th><th align="left">Mínimo</th></tr>
        ${filas}
      </table>
    `;

    try {
      await enviarEmail({ to: destinatarios, subject: `Stock bajo — ${local.nombre}`, html });
      digestsEnviados++;
    } catch (err) {
      console.error(`alertas-stock-email: error enviando el digest del local ${local.id}: ${err.message}`);
    }
  }

  return respuesta(200, { ok: true, digestsEnviados });
}

function respuesta(statusCode, data) {
  return {
    statusCode,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(data),
  };
}
