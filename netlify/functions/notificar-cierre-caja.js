// Notificacion de cierre de caja por email (seccion 11, Plan Completo).
// La llama caja.html justo despues de que cerrarCajaDelDia() (js/caja.js)
// confirma el cierre -- ver comentario alli sobre por que es "dispara y
// olvida" desde el cliente.
//
// A diferencia de toggle-organizacion.js, esta funcion NO necesita la
// service role key: arma un cliente de Supabase con el JWT de quien llama
// y deja que RLS decida que puede leer. Es exactamente el mismo cierre que
// ya pudo ver en caja.html (cierres_diarios_select ya exige admin de esa
// organizacion), asi que no hay nada nuevo que bypasear.
import { createClient } from '@supabase/supabase-js';
import { enviarEmail } from './lib/resend.js';
import { tieneFeatureEmail } from './lib/planes.js';

// Misma anon key publica que public/js/supabaseClient.js -- no es un
// secreto (se manda al navegador de cualquier visitante), la proteccion
// real sigue siendo RLS.
const SUPABASE_ANON_KEY =
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1wdGNuenBnenRiaWVzcHhwYm5wIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODM2NDA2OTEsImV4cCI6MjA5OTIxNjY5MX0.2dcfZTgvwy9Fb-amRlyyNBO-uGaUc7DFh4CW-S9ORx4';

export async function handler(event) {
  if (event.httpMethod !== 'POST') {
    return respuesta(405, { error: 'Metodo no permitido' });
  }

  const supabaseUrl = process.env.SUPABASE_URL;
  if (!supabaseUrl) {
    return respuesta(500, { error: 'Falta configurar SUPABASE_URL en Netlify' });
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

  const cliente = createClient(supabaseUrl, SUPABASE_ANON_KEY, {
    auth: { persistSession: false },
    global: { headers: { Authorization: `Bearer ${token}` } },
  });

  const { data: cierre, error: cierreError } = await cliente
    .from('cierres_diarios')
    .select(
      'efectivo_esperado_total, efectivo_contado_total, transferencia_total, fiado_nuevo_total, diferencia_total, ' +
        'locales(nombre, alerta_cierre_caja_email), organizations(nombre, plan, plan_overrides)'
    )
    .eq('local_id', localId)
    .eq('fecha', fecha)
    .maybeSingle();
  if (cierreError) return respuesta(500, { error: cierreError.message });
  // Si esto da null no es necesariamente un error: puede ser que el que
  // llama no sea admin de esa organizacion (RLS lo filtra en silencio) o
  // que el cierre todavia no se haya guardado. En ningun caso corresponde
  // mandar un email.
  if (!cierre) return respuesta(200, { ok: true, enviado: false, motivo: 'cierre_no_encontrado' });

  if (!cierre.locales?.alerta_cierre_caja_email) {
    return respuesta(200, { ok: true, enviado: false, motivo: 'desactivado' });
  }
  if (!tieneFeatureEmail(cierre.organizations, 'email_cierre_caja')) {
    return respuesta(200, { ok: true, enviado: false, motivo: 'plan' });
  }

  const { data: admins, error: adminsError } = await cliente
    .from('usuarios')
    .select('email')
    .eq('role', 'admin')
    .eq('status', 'approved');
  if (adminsError) return respuesta(500, { error: adminsError.message });

  const destinatarios = admins.map((a) => a.email).filter(Boolean);
  if (destinatarios.length === 0) {
    return respuesta(200, { ok: true, enviado: false, motivo: 'sin_destinatarios' });
  }

  const formatoMoneda = (n) => `$${Number(n).toLocaleString('es-AR')}`;
  const fechaLabel = new Date(fecha + 'T00:00:00').toLocaleDateString('es-AR');

  try {
    await enviarEmail({
      to: destinatarios,
      subject: `Caja cerrada — ${cierre.locales.nombre} (${fechaLabel})`,
      html: `
        <h2>Se cerró la caja del día</h2>
        <p><strong>${cierre.locales.nombre}</strong> — ${fechaLabel}</p>
        <ul>
          <li>Efectivo esperado: ${formatoMoneda(cierre.efectivo_esperado_total)}</li>
          <li>Efectivo contado: ${formatoMoneda(cierre.efectivo_contado_total)}</li>
          <li>Diferencia: ${formatoMoneda(cierre.diferencia_total)}</li>
          <li>Transferencia: ${formatoMoneda(cierre.transferencia_total)}</li>
          <li>Fiado nuevo del día: ${formatoMoneda(cierre.fiado_nuevo_total)}</li>
        </ul>
      `,
    });
  } catch (err) {
    return respuesta(502, { error: err.message });
  }

  return respuesta(200, { ok: true, enviado: true, destinatarios: destinatarios.length });
}

function respuesta(statusCode, data) {
  return {
    statusCode,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(data),
  };
}
