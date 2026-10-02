// Limpieza de organizaciones de prueba (panel de super-admin, seccion 16).
// El borrado de los datos en si (locales, usuarios, ventas, productos, etc.)
// lo hace la RPC eliminar_organizacion_de_prueba() -- es security definer y
// ya revalida is_super_admin() por su cuenta, asi que se llama con el JWT
// de quien esta logueado (cliente con la anon key), no con la service role
// key. Lo UNICO que necesita la service role key aca es el paso final: borrar
// los usuarios de Supabase Auth que la RPC dejo huerfanos (auth.users no se
// puede tocar con una query SQL comun, hace falta la Admin API).
import { createClient } from '@supabase/supabase-js';
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './lib/supabaseAnon.js';

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

  const { organizationId } = body;
  if (!organizationId) {
    return respuesta(400, { error: 'Falta organizationId' });
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false } });

  // Mismo doble chequeo que toggle-organizacion.js: con service role no hay
  // ninguna policy de por medio, asi que se valida a mano antes de tocar nada.
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

  // El borrado real corre con el JWT del super-admin (no con la service
  // role) para que auth.uid() resuelva adentro de la funcion y su propio
  // chequeo de is_super_admin() (y el bloqueo de organizaciones con cobro
  // habilitado o con cobros ya registrados) se aplique de verdad.
  const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: { persistSession: false },
    global: { headers: { Authorization: `Bearer ${token}` } },
  });

  const { data: usuarioIds, error: rpcError } = await userClient.rpc('eliminar_organizacion_de_prueba', {
    p_organization_id: organizationId,
  });
  if (rpcError) {
    return respuesta(400, { error: rpcError.message });
  }

  // Los datos ya se borraron. Si algun auth.users queda huerfano porque esta
  // llamada falla a mitad de camino, no es grave -- es un usuario de auth
  // sin fila en usuarios, sin acceso a nada (storage/RLS ya no lo reconocen),
  // facil de reintentar o limpiar despues a mano.
  const authErrors = [];
  for (const usuarioId of usuarioIds || []) {
    const { error: deleteUserError } = await admin.auth.admin.deleteUser(usuarioId);
    if (deleteUserError) {
      authErrors.push({ id: usuarioId, error: deleteUserError.message });
    }
  }

  return respuesta(200, { ok: true, usuariosEliminados: usuarioIds || [], authErrors });
}

function respuesta(statusCode, data) {
  return {
    statusCode,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(data),
  };
}
