import { supabase } from './supabaseClient.js';

export const ESTADO_COBRO_LABEL = { pendiente: 'Pendiente', pagado: 'Pagado', vencido: 'Vencido', exento: 'Exento' };
export const ESTADO_COBRO_CLASE = { pendiente: 'estado-editada', pagado: 'estado-activa', vencido: 'estado-anulada', exento: 'saldo-al-dia' };

// Precios vigentes de los dos planes. Los lee cualquier usuario aprobado
// (planes_precios_select) o el super-admin; los edita solo el super-admin.
export async function listarPreciosPlanes() {
  const { data, error } = await supabase.from('planes_precios').select('plan, precio_mensual, updated_at').order('plan');
  if (error) throw error;
  return data;
}

export async function actualizarPrecioPlan(plan, precioMensual) {
  const { error } = await supabase.from('planes_precios').update({ precio_mensual: precioMensual }).eq('plan', plan);
  if (error) throw error;
}

// Historial de cobros de la propia organizacion (cobros_select_org).
export async function listarCobrosOrganizacion(organizationId) {
  const { data, error } = await supabase
    .from('cobros')
    .select('*')
    .eq('organization_id', organizationId)
    .order('periodo', { ascending: false });
  if (error) throw error;
  return data;
}

// Sube el comprobante a Storage y despues linkea la ruta en la fila del
// cobro via RPC (subir_comprobante_cobro) -- dos pasos porque el insert a
// Storage y el update de la tabla los autorizan policies distintas.
export async function subirComprobante(cobroId, organizationId, file) {
  const extension = (file.name.split('.').pop() || 'bin').toLowerCase();
  const ruta = `${organizationId}/${cobroId}-${Date.now()}.${extension}`;

  const { error: uploadError } = await supabase.storage.from('comprobantes-pago').upload(ruta, file, { upsert: false });
  if (uploadError) throw uploadError;

  const { error: rpcError } = await supabase.rpc('subir_comprobante_cobro', { p_cobro_id: cobroId, p_path: ruta });
  if (rpcError) throw rpcError;
}

// Super-admin: todos los cobros de todas las organizaciones (cobros_select_superadmin).
export async function listarCobrosSuperadmin() {
  const { data, error } = await supabase
    .from('cobros')
    .select('*, organizations(nombre)')
    .order('periodo', { ascending: false })
    .order('created_at', { ascending: false });
  if (error) throw error;
  return data;
}

export async function actualizarEstadoCobro(cobroId, estado) {
  const { error } = await supabase.rpc('actualizar_estado_cobro', { p_cobro_id: cobroId, p_estado: estado });
  if (error) throw error;
}

// URL firmada de un comprobante para que el super-admin lo vea (el bucket es
// privado). Vence a los 60 segundos -- alcanza para abrir la pestana.
export async function obtenerUrlComprobante(path) {
  const { data, error } = await supabase.storage.from('comprobantes-pago').createSignedUrl(path, 60);
  if (error) throw error;
  return data.signedUrl;
}

// Boton de respaldo (seccion 16): corre lo mismo que el cron del dia 1, por
// si un mes falla o hace falta regenerar. Solo super-admin (RPC lo valida).
export async function generarCobrosMensuales() {
  const { error } = await supabase.rpc('generar_cobros_mensuales_manual');
  if (error) throw error;
}
