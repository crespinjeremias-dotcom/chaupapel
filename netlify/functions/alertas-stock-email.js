// Alerta de stock bajo por email (seccion 11, Plan Medio+): digest diario,
// no un email por cada venta que deja un producto por debajo del minimo
// -- eso mandaria decenas de mails por dia en un local con rotacion alta.
// Se dispara solo por el cron de netlify.toml (ver `schedule` ahi), nunca
// desde el cliente -- por eso necesita la service role key: no hay un
// usuario logueado de quien tomar un JWT, tiene que recorrer todas las
// organizaciones.
import { createClient } from '@supabase/supabase-js';
import { enviarEmail } from './lib/resend.js';
import { tieneFeatureEmail } from './lib/planes.js';

// NOTA: esta funcion no valida que la invocacion venga realmente del cron
// de Netlify (no pude confirmar contra la documentacion oficial, en este
// entorno, cual es la forma correcta y estable de verificarlo). Si alguien
// llama a esta URL a mano, en el peor caso se manda el mismo digest de
// stock bajo antes de tiempo -- no expone datos nuevos ni hace nada
// destructivo, asi que se acepta el riesgo por ahora. Si mas adelante hace
// falta cerrarlo del todo, la opcion mas simple es agregar un secreto
// propio (ej. `?token=...` contra una env var) en vez de confiar en un
// header de Netlify sin confirmar.
export async function handler() {
  const supabaseUrl = process.env.SUPABASE_URL;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!supabaseUrl || !serviceRoleKey) {
    return respuesta(500, { error: 'Falta configurar SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY en Netlify' });
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false } });

  const { data: locales, error: localesError } = await admin
    .from('locales')
    .select('id, nombre, organization_id, organizations(nombre, plan, plan_overrides, is_active)')
    .eq('alerta_stock_email', true)
    .eq('activo', true);
  if (localesError) return respuesta(500, { error: localesError.message });

  let localesConAlerta = 0;
  let emailsEnviados = 0;

  for (const local of locales) {
    if (local.organizations?.is_active === false) continue;
    if (!tieneFeatureEmail(local.organizations, 'email_stock_bajo')) continue;

    const { data: productos, error: productosError } = await admin
      .from('productos')
      .select('nombre, presentacion, unidad_medida, stock_actual, stock_minimo')
      .eq('local_id', local.id)
      .eq('activo', true)
      .is('deleted_at', null);
    if (productosError) {
      console.error(`No se pudo leer productos del local ${local.id}:`, productosError);
      continue;
    }

    // Mismo criterio que alertas-stock.html: stock actual en o por debajo
    // del minimo configurado para ese producto.
    const conAlerta = productos.filter((p) => Number(p.stock_actual) <= Number(p.stock_minimo));
    if (conAlerta.length === 0) continue;
    localesConAlerta++;

    const { data: adminsLocal, error: adminsError } = await admin
      .from('usuarios')
      .select('email')
      .eq('organization_id', local.organization_id)
      .eq('role', 'admin')
      .eq('status', 'approved');
    if (adminsError) {
      console.error(`No se pudieron leer los admins de la organizacion ${local.organization_id}:`, adminsError);
      continue;
    }
    const destinatarios = adminsLocal.map((a) => a.email).filter(Boolean);
    if (destinatarios.length === 0) continue;

    const filas = conAlerta
      .map(
        (p) =>
          `<li>${p.nombre}${p.presentacion ? ' · ' + p.presentacion : ''} — stock ${p.stock_actual} ${p.unidad_medida || ''} (mínimo ${p.stock_minimo})</li>`
      )
      .join('');

    try {
      await enviarEmail({
        to: destinatarios,
        subject: `Stock bajo — ${local.nombre} (${conAlerta.length} producto${conAlerta.length === 1 ? '' : 's'})`,
        html: `
          <h2>Productos con stock bajo</h2>
          <p><strong>${local.nombre}</strong></p>
          <ul>${filas}</ul>
        `,
      });
      emailsEnviados++;
    } catch (err) {
      console.error(`No se pudo enviar el email de stock bajo del local ${local.id}:`, err);
    }
  }

  return respuesta(200, { ok: true, localesRevisados: locales.length, localesConAlerta, emailsEnviados });
}

function respuesta(statusCode, data) {
  return {
    statusCode,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(data),
  };
}
