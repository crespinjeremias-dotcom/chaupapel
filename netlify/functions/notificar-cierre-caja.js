// Dispara el email de cierre de caja (seccion 11, Plan Completo) justo
// despues de que el admin cierra la caja del dia desde caja.html. Usa el
// JWT del admin que llama + la anon key, no la service role key -- dejar
// que RLS decida que puede leer es mas simple y mas seguro que reimplementar
// el chequeo a mano, y alcanza porque el cierre que se quiere notificar es
// exactamente el mismo que ese admin ya podia ver en caja.html.
import { createClient } from '@supabase/supabase-js';
import { enviarEmail } from './lib/resend.js';
import { tieneFeatureServer } from './lib/planes.js';
import { escapeHtml } from './lib/html.js';
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './lib/supabaseAnon.js';

export async function handler(event) {
  if (event.httpMethod !== 'POST') {
    return respuesta(405, { error: 'Metodo no permitido' });
  }

  const token = (event.headers.authorization || event.headers.Authorization || '').replace(/^Bearer\s+/i, '');
  if (!token) {
    return respuesta(401, { error: 'Falta autenticacion' });
  }

  let body;
  try {
    body = JSON.parse(event.body || '{}');
  } catch {
    return respuesta(400, { error: 'Body invalido' });
  }

  const { localId, fecha } = body;
  if (!localId || !fecha) {
    return respuesta(400, { error: 'Faltan datos (localId, fecha)' });
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: { persistSession: false },
    global: { headers: { Authorization: `Bearer ${token}` } },
  });

  const { data: local, error: localError } = await supabase
    .from('locales')
    .select('id, nombre, organization_id, alerta_cierre_caja_email, bloqueado_por_plan')
    .eq('id', localId)
    .maybeSingle();
  if (localError) return respuesta(500, { error: localError.message });
  if (!local) return respuesta(404, { error: 'Local no encontrado' });

  // En la practica esto no deberia pasar -- cerrarCajaDelDia() ya no puede
  // insertar en cierres_diarios para un local bloqueado (local_is_active()
  // en la policy de insert, migracion 20260911200000). Pero esta funcion es
  // un endpoint aparte que un caller podria golpear directo con un
  // localId/fecha viejos, asi que se revalida igual en vez de asumirlo.
  if (local.bloqueado_por_plan) {
    return respuesta(200, { ok: true, enviado: false });
  }

  // No es un error -- el toggle esta apagado, no hay nada que mandar.
  if (!local.alerta_cierre_caja_email) {
    return respuesta(200, { ok: true, enviado: false });
  }

  const { data: org, error: orgError } = await supabase
    .from('organizations')
    .select('plan, plan_overrides')
    .eq('id', local.organization_id)
    .maybeSingle();
  if (orgError) return respuesta(500, { error: orgError.message });
  // El toggle puede haber quedado prendido de antes de una baja de plan --
  // se revalida el feature server-side, no solo el toggle.
  if (!org || !tieneFeatureServer(org, 'email_cierre_caja')) {
    return respuesta(200, { ok: true, enviado: false });
  }

  const { data: cierre, error: cierreError } = await supabase
    .from('cierres_diarios')
    .select('*')
    .eq('local_id', localId)
    .eq('fecha', fecha)
    .maybeSingle();
  if (cierreError) return respuesta(500, { error: cierreError.message });
  if (!cierre) return respuesta(404, { error: 'Cierre no encontrado para ese local y fecha' });

  const { data: admins, error: adminsError } = await supabase
    .from('usuarios')
    .select('email')
    .eq('organization_id', local.organization_id)
    .eq('role', 'admin')
    .eq('status', 'approved');
  if (adminsError) return respuesta(500, { error: adminsError.message });

  const destinatarios = (admins || []).map((a) => a.email).filter(Boolean);
  if (destinatarios.length === 0) {
    return respuesta(200, { ok: true, enviado: false });
  }

  const formatoMoneda = (n) => `$${Number(n).toLocaleString('es-AR')}`;
  const html = `
    <h2>Cierre de caja — ${escapeHtml(local.nombre)}</h2>
    <p>Fecha: ${escapeHtml(fecha)}</p>
    <table cellpadding="6" style="border-collapse:collapse">
      <tr><td>Efectivo esperado</td><td>${formatoMoneda(cierre.efectivo_esperado_total)}</td></tr>
      <tr><td>Efectivo contado</td><td>${formatoMoneda(cierre.efectivo_contado_total)}</td></tr>
      <tr><td>Diferencia</td><td>${formatoMoneda(cierre.diferencia_total)}</td></tr>
      <tr><td>Transferencia</td><td>${formatoMoneda(cierre.transferencia_total)}</td></tr>
      <tr><td>Fiado nuevo</td><td>${formatoMoneda(cierre.fiado_nuevo_total)}</td></tr>
    </table>
  `;

  try {
    await enviarEmail({ to: destinatarios, subject: `Cierre de caja — ${local.nombre} (${fecha})`, html });
  } catch (err) {
    return respuesta(502, { error: `No se pudo enviar el email: ${err.message}` });
  }

  return respuesta(200, { ok: true, enviado: true });
}

function respuesta(statusCode, data) {
  return {
    statusCode,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(data),
  };
}
