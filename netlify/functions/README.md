# netlify/functions/

Funciones serverless de Netlify, usadas para lo que no puede (o no debe) resolverse desde el cliente:

- Envío de emails de alerta de stock bajo (sección 11).
- Envío de email de notificación de cierre de caja (sección 11, plan Completo).
- Operaciones que requieran la **service role key** de Supabase (bypasea RLS por completo), como activar/desactivar una organización (`organizations.is_active`, sección 16) — ver el trigger `prevent_is_active_change`.

Nada acá todavía — se implementa junto con el módulo de Notificaciones (Fase 9) y el resto del panel de super-admin (Fase 15).

Nota: no todo el panel de super-admin depende de esto. La aprobación de cambios de plan (primer caso de uso de Fase 15) se resolvió sin Netlify Functions, con RLS (tabla `super_admins` + función `is_super_admin()` + policies aditivas) — ver `docs/rls-design.md`. Esta carpeta es para lo que RLS específicamente no puede resolver, como `is_active`.
