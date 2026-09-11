# netlify/functions/

Funciones serverless de Netlify, usadas para lo que no puede (o no debe) resolverse desde el cliente:

- Envío de emails de alerta de stock bajo (sección 11).
- Envío de email de notificación de cierre de caja (sección 11, plan Completo).
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

Envía el email de "se cerró la caja del día" (sección 11, Plan Completo).
La llama `js/caja.js` (`notificarCierreCaja`) justo después de que
`cerrarCajaDelDia` confirma el cierre. A diferencia de `toggle-organizacion.js`
**no** usa la service role key: arma un cliente de Supabase con el JWT de
quien llama y deja que RLS decida qué puede leer (es el mismo cierre que ya
podía ver en `caja.html`, no hay nada que bypasear). Si el local tiene
`alerta_cierre_caja_email` en `false`, o la organización no tiene el plan
(`email_cierre_caja`, mínimo Completo), responde `200` sin mandar nada — no
es un error.

## `alertas-stock-email.js`

Digest diario (no por-evento) de productos con stock bajo, uno por local que
tenga `alerta_stock_email` activado y el plan lo permita (`email_stock_bajo`,
mínimo Medio). Se dispara solo por el cron configurado en `netlify.toml`
(`[functions."alertas-stock-email"]`, 12:00 UTC = 9am Argentina) — recorre
todas las organizaciones, por eso sí necesita la service role key. No valida
que la invocación venga realmente del scheduler de Netlify (ver comentario
en el archivo) — si hace falta cerrar eso, la opción más simple es un
secreto propio en vez de confiar en un header de Netlify sin confirmar
contra la documentación oficial.

Ambas funciones de email comparten `lib/resend.js` (llama a la API de Resend
por `fetch`, sin sumar su SDK como dependencia) y `lib/planes.js` (espeja
`PLAN_MINIMO_POR_FEATURE` de `public/js/planes.js` — hay que mantener los dos
sincronizados a mano, ver el comentario ahí).

Variables de entorno adicionales que necesitan (mismo lugar, Site settings →
Environment variables):
- `RESEND_API_KEY`
- `EMAIL_FROM` (opcional) — remitente a usar una vez que haya un dominio
  propio verificado en Resend. Sin esto cae a `onboarding@resend.dev`, que
  Resend limita a mandar solo a la casilla con la que se creó la cuenta —
  sirve para probar, no para producción con clientes reales.

Nota: no todo el panel de super-admin depende de Netlify Functions. La
aprobación de cambios de plan se resolvió sin esto, con RLS (tabla
`super_admins` + función `is_super_admin()` + policies aditivas) — ver
`docs/rls-design.md`. Esta carpeta es solo para lo que RLS específicamente
no puede resolver, como `is_active`.
