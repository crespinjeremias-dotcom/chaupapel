# netlify/functions/

Funciones serverless de Netlify, usadas para lo que no puede (o no debe) resolverse desde el cliente:

- Envío de emails de alerta de stock bajo (sección 11).
- Envío de email de notificación de cierre de caja (sección 11, plan Completo).
- Operaciones que requieran la **service role key** de Supabase (bypasea RLS), como el panel de super-admin (sección 16: activar/desactivar organizaciones).

Nada acá todavía — se implementa junto con el módulo de Notificaciones (Fase 9) y el panel de super-admin (Fase 15).
