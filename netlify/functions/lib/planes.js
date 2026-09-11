// Espejo minimo de PLAN_MINIMO_POR_FEATURE (public/js/planes.js), solo para
// los dos features que estas functions necesitan validar server-side. No se
// puede importar planes.js directo desde una function porque importa
// supabaseClient.js, que a su vez importa @supabase/supabase-js por URL de
// CDN -- Node no resuelve imports por URL.
//
// Si se agrega o cambia el plan minimo de email_stock_bajo o
// email_cierre_caja en public/js/planes.js, hay que actualizar este archivo
// tambien.
// Plan Medio eliminado (seccion 15): ver public/js/planes.js.
const ORDEN_PLAN = { basico: 0, completo: 1 };

const PLAN_MINIMO_POR_FEATURE = {
  email_stock_bajo: 'basico',
  email_cierre_caja: 'completo',
};

export function tieneFeatureServer(organization, feature) {
  const override = organization?.plan_overrides?.[feature];
  if (override === true || override === false) return override;

  const plan = organization?.plan || 'basico';
  const minimo = PLAN_MINIMO_POR_FEATURE[feature];
  if (!minimo) return true;
  return ORDEN_PLAN[plan] >= ORDEN_PLAN[minimo];
}
