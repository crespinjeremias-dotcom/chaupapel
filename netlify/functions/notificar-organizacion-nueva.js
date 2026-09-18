// Avisa por email al super-admin de la plataforma cuando se registra una
// organizacion nueva (seccion 16, gate de aprobacion). La dispara el cliente
// justo despues de que crear_organizacion() RPC devuelve exito en
// registrarOrganizacion() (auth.js) -- mismo patron que
// notificar-cierre-caja.js: JWT del usuario recien creado + anon key, RLS
// decide que puede leer (organizations_select / usuarios_select ya dejan
// leer la propia organizacion aunque este pendiente de aprobacion, no tienen
// condicion de org_is_active()).
import { createClient } from '@supabase/supabase-js';
import { enviarEmail } from './lib/resend.js';
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

  const { organizationId } = body;
  if (!organizationId) {
    return respuesta(400, { error: 'Falta organizationId' });
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: { persistSession: false },
    global: { headers: { Authorization: `Bearer ${token}` } },
  });

  const { data: org, error: orgError } = await supabase
    .from('organizations')
    .select('id, nombre, estado_aprobacion')
    .eq('id', organizationId)
    .maybeSingle();
  if (orgError) return respuesta(500, { error: orgError.message });
  if (!org) return respuesta(404, { error: 'Organizacion no encontrada' });

  // No es un error -- si ya se resolvio (o esta funcion se llama de nuevo por
  // las dudas) no hay nada que avisar de nuevo.
  if (org.estado_aprobacion !== 'pendiente') {
    return respuesta(200, { ok: true, enviado: false });
  }

  const { data: admin, error: adminError } = await supabase
    .from('usuarios')
    .select('nombre, email, telefono')
    .eq('organization_id', organizationId)
    .eq('role', 'admin')
    .maybeSingle();
  if (adminError) return respuesta(500, { error: adminError.message });

  const superAdminEmail = process.env.SUPER_ADMIN_EMAIL;
  if (!superAdminEmail) {
    // Sin destinatario no hay a quien avisar -- a diferencia del remitente
    // (RESEND_FROM), aca no hay ningun fallback razonable que probar: si
    // esto se ve en los logs, el super-admin nunca se va a enterar de que
    // hay una organizacion pendiente de aprobacion sin entrar a mirar el
    // panel a mano.
    console.error(
      '########################################################\n' +
      '# ALERTA: falta configurar SUPER_ADMIN_EMAIL en Netlify.\n' +
      '# No se pudo avisar por email de una organizacion nueva\n' +
      `# pendiente de aprobacion (${org.nombre}, id ${org.id}).\n` +
      '########################################################'
    );
    return respuesta(500, { error: 'Falta configurar SUPER_ADMIN_EMAIL en las variables de entorno de Netlify' });
  }

  const html = `
    <h2>Organización nueva pendiente de aprobación</h2>
    <p><strong>${escapeHtml(org.nombre)}</strong></p>
    <table cellpadding="6" style="border-collapse:collapse">
      <tr><td>Admin</td><td>${escapeHtml(admin?.nombre || '—')}</td></tr>
      <tr><td>Email</td><td>${escapeHtml(admin?.email || '—')}</td></tr>
      <tr><td>Teléfono</td><td>${escapeHtml(admin?.telefono || '—')}</td></tr>
    </table>
    <p>Entrá al panel del sistema para aprobarla o rechazarla.</p>
  `;

  try {
    await enviarEmail({ to: [superAdminEmail], subject: `Organización pendiente de aprobación — ${org.nombre}`, html });
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
