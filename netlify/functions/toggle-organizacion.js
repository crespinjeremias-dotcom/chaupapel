// Activar/desactivar una organizacion por falta de pago (seccion 16). Es la
// unica operacion que sigue exigiendo la service role key -- el trigger
// prevent_is_active_change en la base bloquea cualquier otro camino, incluso
// para un usuario con is_super_admin() = true (ver supabase/migrations y
// docs/rls-design.md). Esta funcion es ese unico camino habilitado.
import { createClient } from '@supabase/supabase-js';

export async function handler(event) {
  if (event.httpMethod !== 'POST') {
    return respuesta(405, { error: 'Metodo no permitido' });
  }

  const supabaseUrl = process.env.SUPABASE_URL;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!supabaseUrl || !serviceRoleKey) {
    return respuesta(500, { error: 'Falta configurar SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY en Netlify' });
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

  const { organizationId, activo } = body;
  if (!organizationId || typeof activo !== 'boolean') {
    return respuesta(400, { error: 'Faltan datos (organizationId, activo)' });
  }

  // Cliente con service role: bypasea RLS por completo, por eso primero hay
  // que validar a mano que quien llama es realmente un super-admin -- no hay
  // ninguna policy de por medio en esta llamada.
  const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false } });

  const { data: userData, error: userError } = await admin.auth.getUser(token);
  if (userError || !userData?.user) {
    return respuesta(401, { error: 'Sesion invalida o vencida' });
  }

  const { data: superAdmin, error: superAdminError } = await admin
    .from('super_admins')
    .select('id')
    .eq('id', userData.user.id)
    .maybeSingle();
  if (superAdminError) {
    return respuesta(500, { error: superAdminError.message });
  }
  if (!superAdmin) {
    return respuesta(403, { error: 'No autorizado' });
  }

  const { error: updateError } = await admin.from('organizations').update({ is_active: activo }).eq('id', organizationId);
  if (updateError) {
    return respuesta(500, { error: updateError.message });
  }

  return respuesta(200, { ok: true });
}

function respuesta(statusCode, data) {
  return {
    statusCode,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(data),
  };
}
