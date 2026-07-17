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

Pendiente: envío de emails de alerta de stock bajo y de cierre de caja
(sección 11, Fase 9) — necesita además elegir un servicio de correo.

Nota: no todo el panel de super-admin depende de Netlify Functions. La
aprobación de cambios de plan se resolvió sin esto, con RLS (tabla
`super_admins` + función `is_super_admin()` + policies aditivas) — ver
`docs/rls-design.md`. Esta carpeta es solo para lo que RLS específicamente
no puede resolver, como `is_active`.
