import { supabase } from './supabaseClient.js';

// Segmentacion comercial (seccion 15): NO son versiones distintas del
// codigo, es un feature flag por organizacion. Cada feature tiene el plan
// minimo que la incluye (segun el spec); plan_overrides permite excepciones
// puntuales por organizacion (ej. destrabar algo para un cliente puntual sin
// subirle el plan entero).
export const PLANES = ['basico', 'medio', 'completo'];
export const PLAN_LABEL = { basico: 'Básico', medio: 'Medio', completo: 'Completo' };

const ORDEN_PLAN = { basico: 0, medio: 1, completo: 2 };

const PLAN_MINIMO_POR_FEATURE = {
  codigo_barras: 'medio', // lectura de codigo de barras por camara o lector fisico
  vencimiento: 'medio', // fecha de vencimiento por producto + alertas
  excel: 'medio', // import/export de productos via Excel
  estadisticas: 'completo', // productos mas vendidos, franja horaria
  multi_local: 'completo', // dashboard consolidado de mas de un local
};

// true/false fuerza el flag sin importar el plan; undefined cae al plan
// contratado. usuario.organizations.plan_overrides es un jsonb, puede venir
// vacio ({}) en el caso normal.
export function tieneFeature(usuario, feature) {
  const override = usuario?.organizations?.plan_overrides?.[feature];
  if (override === true || override === false) return override;

  const plan = usuario?.organizations?.plan || 'basico';
  const minimo = PLAN_MINIMO_POR_FEATURE[feature];
  if (!minimo) return true; // feature sin restriccion de plan (parte del core)
  return ORDEN_PLAN[plan] >= ORDEN_PLAN[minimo];
}

// Cambio de plan con aprobacion (seccion 15 y 16): el admin ya no cambia su
// propio plan directo (eso permitia auto-upgrade gratis sin pasar por el
// cobro manual) -- ahora crea una solicitud pendiente. La aprueba/rechaza el
// super-admin desde su panel (ver js/superadmin.js).
export async function solicitarCambioPlan({ organizationId, planActual, planSolicitado, usuarioId }) {
  const { error } = await supabase.from('solicitudes_cambio_plan').insert({
    organization_id: organizationId,
    plan_actual: planActual,
    plan_solicitado: planSolicitado,
    solicitado_por: usuarioId,
  });
  if (error) throw error;
}

// La solicitud mas reciente de la organizacion -- alcanza para mostrar "esta
// pendiente" o "la ultima fue rechazada" sin necesitar un historial completo
// en el panel del admin.
export async function obtenerUltimaSolicitudPlan(organizationId) {
  const { data, error } = await supabase
    .from('solicitudes_cambio_plan')
    .select('*')
    .eq('organization_id', organizationId)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  if (error) throw error;
  return data;
}
