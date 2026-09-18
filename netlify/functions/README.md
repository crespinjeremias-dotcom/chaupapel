# netlify/functions/

Funciones serverless de Netlify, usadas para lo que no puede (o no debe) resolverse desde el cliente:

- Envío de emails de alerta de stock bajo (sección 11).
- Envío de email de notificación de cierre de caja (sección 11, plan Completo).
- Envío de email al super-admin cuando se registra una organización nueva (sección 16, gate de aprobación).
- Operaciones que requieran la **service role key** de Supabase (bypasea RLS por completo), como activar/desactivar una organización (`organizations.is_active`, sección 16) — ver el trigger `prevent_is_active_change`.

## `toggle-organizacion.js`

Activa/desactiva `organizations.is_active`. Valida el JWT del caller contra
`super_admins` usando la service role key (bypasea RLS a propósito, por eso
la validación manual antes de tocar nada) y recién ahí hace el update.

Variables de entorno que necesita, configuradas en Netlify (Site settings →
Environment variables), **nunca** en el código ni en el repo:
- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY` (la service role key real — no la anon key
  que ya usa `public/js/supabaseClient.js`)

Las dependencias de las funciones (ej. `@supabase/supabase-js`) van en el
`package.json` de la **raíz del proyecto**, no en uno propio de esta carpeta
-- Netlify no instala automáticamente el `package.json` de una función salvo
que se agregue un plugin aparte, así que la raíz es el lugar correcto (y el
que recomienda el propio mensaje de error de Netlify si esto se rompe).
Cualquier función nueva que se agregue acá debe usar esa misma dependencia
compartida, no declarar la suya.

## `notificar-cierre-caja.js`

Dispara el email de cierre de caja (sección 11, Plan Completo) justo después
de `cerrarCajaDelDia` (`caja.html`). Usa el JWT del admin que llama + la
**anon key** (no la service role key) — deja que RLS decida qué puede leer,
y alcanza porque el cierre que se notifica es el mismo que ese admin ya
podía ver en `caja.html`. Si el toggle del local (`alerta_cierre_caja_email`)
está apagado, o el plan de la organización no incluye el feature, no manda
nada y responde `200 { ok: true, enviado: false }` — no es un error.

## `notificar-organizacion-nueva.js`

Avisa por email al super-admin de la plataforma (`SUPER_ADMIN_EMAIL`) cuando
se registra una organización nueva (sección 16, gate de aprobación). La
dispara el cliente justo después de que `crear_organizacion()` RPC devuelve
éxito en `registrarOrganizacion()` (`public/js/auth.js`) -- mismo patrón que
`notificar-cierre-caja.js`: JWT del usuario recién creado + anon key, deja
que RLS decida qué puede leer (leer la propia organización y su admin
funciona igual aunque esté pendiente de aprobación -- `organizations_select`
y `usuarios_select` no tienen condición de `org_is_active()`). Si falla, no
hace fallar el registro: la organización ya quedó creada igual, solo
pendiente. Ver `docs/aprobacion-organizaciones.md` para el resto del diseño
(campo de estado, RPCs de aprobar/rechazar, qué pasa si se rechaza).

## `alertas-stock-email.js`

Digest diario (cron en `netlify.toml`, 12:00 UTC = 9am Argentina) de
productos con stock bajo por local, para organizaciones con el toggle
`alerta_stock_email` prendido (parte de Basico desde que se eliminó el Plan
Medio). No hay un usuario logueado del
que tomar un JWT — recorre todas las organizaciones en una sola corrida —
por eso sí usa la service role key, igual que `toggle-organizacion.js`. Ver
`docs/notificaciones-email.md` para el detalle de las decisiones (servicio
de email elegido, por qué digest y no email por evento, y qué falta
verificar en vivo contra el dashboard de Netlify).

Variables de entorno adicionales que necesitan estas tres funciones:
- `RESEND_API_KEY` (obligatoria — sin esto ninguna puede mandar un email).
- `RESEND_FROM` (opcional; sin esto usa el remitente sandbox de Resend, que
  solo entrega a la casilla del dueño de la cuenta — hace falta un dominio
  verificado en Resend y esta variable para mandarle a los admins reales).
- `ALERTAS_STOCK_SECRET` (opcional; permite invocar `alertas-stock-email` a
  mano con `?secret=...` mientras se prueba el setup, sin depender de que el
  cron ya esté andando).
- `SUPER_ADMIN_EMAIL` (obligatoria para `notificar-organizacion-nueva.js` —
  sin esto esa función devuelve error 500 y lo loguea bien visible, no hay
  ningún fallback razonable como con `RESEND_FROM`. Hoy alcanza con una sola
  dirección porque hay un solo super-admin cargado a mano; si en el futuro
  hay más de uno, hay que reemplazar esto por una consulta a `super_admins`
  + `auth.users` vía service role).

Nota: no todo el panel de super-admin depende de Netlify Functions. La
aprobación de cambios de plan se resolvió sin esto, con RLS (tabla
`super_admins` + función `is_super_admin()` + policies aditivas) — ver
`docs/rls-design.md`. Esta carpeta es solo para lo que RLS específicamente
no puede resolver, como `is_active`.
