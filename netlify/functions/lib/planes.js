// Espeja PLAN_MINIMO_POR_FEATURE de public/js/planes.js -- no se puede
// importar ese archivo directo aca porque supabaseClient.js (del que
// depende) importa @supabase/supabase-js desde una URL de CDN, algo que
// Node no sabe resolver fuera del navegador. Si se agrega o cambia un
// feature de plan relacionado con email, actualizar los dos lugares.
const ORDEN_PLAN = { basico: 0, medio: 1, completo: 2 };

const PLAN_MINIMO_POR_FEATURE = {
  email_stock_bajo: 'medio',
  email_cierre_caja: 'completo',
};

export function tieneFeatureEmail(organization, feature) {
  const override = organization?.plan_overrides?.[feature];
  if (override === true || override === false) return override;

  const plan = organization?.plan || 'basico';
  const minimo = PLAN_MINIMO_POR_FEATURE[feature];
  return ORDEN_PLAN[plan] >= ORDEN_PLAN[minimo];
}
