# Aprobación de organizaciones nuevas — sección 16

Hasta ahora, registrarse creaba la organización y le daba acceso inmediato.
Se agrega el mismo rigor que ya existe para el alta de empleados (pending ->
aprobación del admin de la organización) y para los cambios de plan
(solicitud -> aprobación del super-admin): toda organización nueva nace
`pendiente` y no puede operar hasta que el super-admin la aprueba o la
rechaza.

## Campo de estado

`organizations.estado_aprobacion` (`estado_aprobacion_type`: `pendiente` /
`aprobada` / `rechazada`), mismo patrón que `estado_solicitud_type` de
`solicitudes_cambio_plan`. Las organizaciones que ya existían al agregar la
columna quedaron `aprobada` automáticamente (default `'aprobada'` en el
`ALTER TABLE ADD COLUMN`, cambiado a `'pendiente'` recién después para las
altas nuevas) — no hizo falta una migración de backfill aparte.

## Cómo convive con `org_is_active()`

En vez de sumar un segundo chequeo en cada una de las ~20 policies que ya
dependen de `org_is_active()` (`20260911200000_bloqueo_locales_por_plan.sql`,
Parte 3), se redefinió la función para que también exija
`estado_aprobacion = 'aprobada'`. Una organización pendiente o rechazada
queda bloqueada con exactamente el mismo rigor que una suspendida
(`is_active = false`), sin tocar ninguna otra policy.

La única diferencia entre los dos casos es el mensaje: `panel.html`
distingue `is_active === false` (cuenta suspendida) de
`estado_aprobacion !== 'aprobada'` (pendiente / rechazada) para no
confundir los dos motivos.

## Aprobar / rechazar

Dos RPC `security definer` (`aprobar_organizacion` / `rechazar_organizacion`),
calcadas de `aprobar_solicitud_plan`/`rechazar_solicitud_plan`: chequean
`is_super_admin()`, que el estado actual sea `pendiente`, y actualizan.
Un trigger (`prevent_estado_aprobacion_change_directo`, misma bandera de
sesión que `prevent_plan_change_directo`) bloquea cualquier `UPDATE` directo
a la columna -- inclusive del propio super-admin vía la policy
`organizations_update_superadmin`, que de otra forma se lo permitiría.

## Qué pasa si se rechaza

Decisión explícita: **no se borra nada**, ni la organización ni la cuenta
del admin que se registró (mismo criterio de "no borrado real" que el resto
del sistema). `estado_aprobacion` queda en `rechazada` para siempre, la
organización sigue bloqueada permanentemente y no hay ningún camino de
reintento automático ni UI para volver a pedir aprobación. Efecto práctico:
el email con el que se registró esa persona queda inutilizable para
siempre (no se borra `auth.users`) -- si quiere insistir, tiene que
contactar por fuera del sistema.

## Email al super-admin

Reutiliza la infraestructura de Resend de la sección 11
(`netlify/functions/lib/resend.js`). Se dispara desde el cliente justo
después de que `crear_organizacion()` RPC devuelve éxito
(`registrarOrganizacion()` en `public/js/auth.js`), llamando a la Netlify
Function `notificar-organizacion-nueva.js` -- mismo patrón que
`notificar-cierre-caja.js` (JWT del usuario recién creado + anon key, RLS
decide qué puede leer). Es best-effort: si falla, no hace fallar el
registro (la organización ya quedó creada, solo pendiente) -- el error solo
se loguea en la consola del cliente.

El destinatario es la variable de entorno `SUPER_ADMIN_EMAIL`, fija. No se
consulta la tabla `super_admins` (que no tiene el email -- vive en
`auth.users`) porque hoy hay un solo super-admin cargado a mano; si en algún
momento hay más de uno, esto tiene que cambiar a una consulta server-side
(`super_admins` + `auth.users`, vía service role) para que escale sola. Si
la variable no está seteada, la función no tiene ningún fallback razonable
que probar (a diferencia de `RESEND_FROM`) -- devuelve error 500 y lo
loguea bien visible en los logs de Netlify.

## Panel de super-admin

Pestaña nueva "Altas pendientes" en `superadmin.html`, calcada de la
pestaña "Cambios de plan" que ya existía: tabla con las organizaciones
`pendiente`, nombre y email del admin fundador (requirió una policy nueva,
`usuarios_select_superadmin`, aditiva -- el super-admin antes solo podía
leer `organizations` y `solicitudes_cambio_plan`), y botones Aprobar /
Rechazar que llaman a las RPC. La pestaña "Organizaciones" (listado general)
también muestra el estado de aprobación cuando no es `aprobada`, y en ese
caso oculta el botón de suspender/reactivar (no tiene sentido todavía).
