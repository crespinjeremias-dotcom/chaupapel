# Diseño de Row Level Security — Fase 1

## Objetivo

Garantizar el aislamiento multi-tenant (sección 1: "los datos de una organización nunca son visibles para otra") directamente en Postgres, para que ningún bug de frontend pueda filtrar datos entre organizaciones — la seguridad no depende de que el JS filtre bien.

## Funciones helper (`supabase/migrations/..._auth_helpers.sql`)

Todas las policies se apoyan en un puñado de funciones `security definer`, `stable`, que leen la fila de `usuarios` del usuario autenticado (`auth.uid()`):

- `current_org_id()` — organización del usuario actual.
- `current_local_id()` — local del usuario actual (null si es admin).
- `is_admin()` — `role = 'admin'`.
- `is_approved()` — `status = 'approved'`.
- `org_is_active()` — `organizations.is_active` de su organización (corte de acceso del super-admin, sección 16).

`security definer` es necesario para que estas funciones puedan leer `usuarios` **sin volver a disparar las policies de `usuarios`** — si no fuera `security definer`, una policy de `usuarios` que llama a una función que hace `select ... from usuarios` generaría recursión. Al ser `security definer`, la función corre con los privilegios de su dueño (que en Supabase tiene `bypassrls`), evitando el problema.

## Patrón general (repetido en casi todas las tablas de negocio)

```
using (
  organization_id = current_org_id()
  and is_approved()
  and org_is_active()
  and (is_admin() or local_id = current_local_id())
)
```

Léase: la fila tiene que ser de tu organización, tu usuario tiene que estar aprobado, tu organización tiene que estar activa (al día con el SaaS), y además — sos admin (que ve todos los locales de su organización) o la fila es específicamente de tu local.

Esto cubre a la vez:
- Aislamiento entre organizaciones (columna `organization_id`).
- Diferencia de acceso admin vs. empleado (ve todos los locales vs. solo el propio).
- Corte de acceso por falta de pago (`org_is_active`) sin tener que tocar cada tabla individualmente si mañana cambia esa regla — está centralizado en la función.

## Excepciones al patrón general (y por qué)

- **`productos` / `categorias` / `proveedores` / `producto_proveedor` (insert/update/delete)**: solo admin, no el patrón genérico. La sección 2 es explícita: "Admin: Carga y edita productos, categorías, proveedores" — el empleado no edita el catálogo, solo vende y ajusta stock (`ajustes_stock` y `reposiciones_stock` sí siguen el patrón genérico, cualquier aprobado del local, porque la sección 6 habla de "admin/encargado" al reponer mercadería). Se corrigió en Fase 3 (productos/categorías) y Fase 4 (proveedores/producto_proveedor) — Fase 1 los había dejado con el patrón genérico por error.
- **`organizations`**: el `select` no exige `is_approved()` ni `org_is_active()` — el propio frontend necesita poder leer `is_active` para mostrar la pantalla de "cuenta suspendida" incluso si la organización está cortada.
- **`usuarios`**: cada usuario siempre puede ver **su propia fila**, independientemente de su `status` — si no, un empleado en estado `pending` no podría ni siquiera consultar que sigue pendiente de aprobación. El admin, además, ve todas las filas de su organización (para poder aprobar altas).
- **`turnos`**: un empleado solo ve/opera **sus propios turnos**, no los de sus compañeros del mismo local — el conteo de caja y las diferencias de un turno son información sensible sobre el desempeño de esa persona puntual. El admin sí ve todos los turnos del local.
- **`cierres_mensuales`**: visibilidad restringida a admin — incluye `total_gastos_mercaderia` y `ganancia_bruta`, información de costos/margen que no necesariamente debería ver cualquier empleado. (`cierres_diarios`, que es solo reconciliación de caja, sigue el patrón general.)
- **`ventas` (update)** y **`venta_items`/`venta_pagos` (update/delete)**: además del patrón general, se agrega la ventana de edición de 10-15 minutos de la sección 7 — un empleado (no admin) solo puede tocar una venta si es suya y fue creada hace menos de 15 minutos; pasado ese margen, o si es de otro empleado, solo el admin puede.

## Tablas sin `update`/`delete` (solo `insert`/`select`)

`reposiciones_stock`, `ajustes_stock`, `cuenta_corriente_movimientos`, `devoluciones_cambios` no tienen policy de `update` ni `delete`. Son movimientos contables: un error se corrige con un movimiento nuevo en sentido contrario, no reescribiendo el histórico. Esto es una decisión de diseño, no una limitación técnica — si en algún momento hace falta permitir corregir un typo reciente, se puede sumar una policy con ventana de tiempo similar a la de `ventas`.

## Alta de organización y de usuarios: por qué no es 100% RLS

`usuarios` **no tiene policy de `insert`** — no se permite insertar una fila directamente desde el cliente, ni para el admin fundador de una organización nueva ni para un empleado que se autoregistra con un código de invitación. La razón: una policy de insert solo puede validar columnas de la fila que se está insertando, y no hay forma de que la fila declare "este `organization_id`/`local_id` corresponden a una invitación real" sin exponer y confiar ciegamente en esos valores — cualquiera podría insertarse a sí mismo como `pending` en la organización de otro con solo adivinar su `organization_id` (un UUID, pero igual es una superficie que preferimos cerrar de raíz en vez de mitigar).

La resolución (a implementar en Fase 2) es que **toda** alta de usuario pase por una función `security definer`, que sí puede validar contra otras tablas antes de insertar:

- `crear_organizacion(...)`: crea la fila de `organizations` y la fila de `usuarios` (`role = 'admin'`, `status = 'approved'`) en un solo paso atómico. Es el único camino para que exista un admin.
- `redimir_invitacion(codigo, ...)`: busca el código en `invitaciones` (tabla a la que el empleado todavía no tiene acceso vía RLS normal, porque no tiene `organization_id` propio hasta este punto), valida que no esté vencido/usado, y recién ahí crea la fila de `usuarios` en estado `pending` con el `organization_id`/`local_id` que salen de la invitación — nunca de lo que mande el cliente.

Ambas funciones bypasean RLS porque corren con privilegios elevados (`security definer`, dueño con `bypassrls`), pero la validación de negocio (código válido, no vencido, no usado) queda adentro de la función, no delegada a una policy.

## Trigger anti-escalada de privilegios

Además de las policies, hay un trigger `prevent_privilege_escalation` en `usuarios` que bloquea que un usuario no-admin cambie `role`, `status`, `organization_id` o `local_id` en su propia fila, incluso a través de la policy `usuarios_update_self` (que por diseño permite que cada uno edite datos no sensibles de su propia fila, como nombre o teléfono). Es defensa en profundidad: aunque la policy de RLS ya es razonablemente restrictiva, este trigger asegura que ni un bug futuro en las policies abra esa puerta.

## `organizations.is_active`: protegido con trigger, no solo con policy (Fase 2)

Al probar el flujo de Auth en el navegador encontré que la policy `organizations_update` (que deja al admin editar su propia organización — necesaria para que pueda cambiar de plan, sección 16) también le permitía, sin querer, reactivar o desactivar su propia cuenta escribiendo `is_active`. Eso anula el sentido del corte de acceso manual del super-admin. RLS no puede restringir columna por columna dentro de una misma policy de `update`, así que se resolvió con un trigger (`prevent_is_active_change`, igual patrón que `prevent_privilege_escalation` en `usuarios`): bloquea cualquier cambio a `is_active` salvo que la request se haga con la `service_role` key (`auth.role() = 'service_role'`), que es el único camino que va a usar el panel de super-admin (Fase 15). Verificado en vivo: el admin puede cambiar `plan` pero no `is_active`.

## Panel de super-admin del SaaS (sección 16) — revisado en Fase 15

**Decisión revisada** (la versión anterior de esta sección decía que el super-admin no sería un rol reconocido por RLS en absoluto; se cambió al arrancar la Fase 15 con el primer caso de uso concreto — aprobación de cambios de plan):

El super-admin **sí es una identidad reconocida por RLS**, pero separada por completo del modelo `usuarios`/`organizations`: vive en una tabla nueva `super_admins (id references auth.users, nombre)`, sin `organization_id` (esa columna es `not null` en `usuarios`, así que un super-admin no puede ser una fila ahí sin inventar una organización dummy). Hay una función `is_super_admin()`, mismo patrón que `is_admin()`/`current_org_id()`, que resuelve `exists (select 1 from super_admins where id = auth.uid())`.

El acceso amplio se implementa con **policies aditivas**, nunca modificando las policies existentes: se sumaron `organizations_select_superadmin` y `organizations_update_superadmin` (ambas `using (is_super_admin())`), y las policies de la tabla nueva `solicitudes_cambio_plan` incluyen `is_super_admin()` en su condición de select. El aislamiento entre organizaciones normales (Admin/Empleado) no se tocó en ningún lado — es exactamente el mismo que antes de esta fase.

**`organizations.is_active` sigue siendo la excepción**: el trigger `prevent_is_active_change` (ver sección de arriba) exige `service_role`, no `is_super_admin()`. No se tocó al agregar este rol. Cuando se construya la función de activar/desactivar organización (pendiente, ver más abajo), va a necesitar una Netlify Function con la service role key — ese trigger seguiría bloqueando el intento aunque el usuario autenticado tenga `is_super_admin() = true`, a propósito: es una segunda capa de protección para la única columna que corta el acceso de un cliente entero.

Alta de la cuenta: no hay flujo de auto-registro. Se crea el usuario de Supabase Auth manualmente desde el dashboard (Authentication → Add user) y después se inserta a mano la fila correspondiente en `super_admins` — dos pasos deliberadamente manuales, coherente con "no me auto-registro como organización".

**Qué falta para el resto de la sección 16** (no se construyó en este primer paso, a propósito — "empezar de a poco"):
- Activar/desactivar organización por falta de pago: sigue atado a `service_role`, necesita la Netlify Function que todavía no existe (`netlify/functions/README.md`).
- Listado general de organizaciones, notificación de cierre de caja por email, etc.: quedan como próximas secciones del panel, con la navegación ya armada para sumarlas (`superadmin.html`).

## GRANT de tabla, además de RLS (Fase 2)

RLS filtra *filas*, pero Postgres exige por separado el permiso de tabla (`GRANT SELECT/INSERT/UPDATE/DELETE`) antes de siquiera evaluar las policies. Al probar el login en el navegador, la primera consulta real a `usuarios` devolvió `403 permission denied for table usuarios` — las migraciones de la Fase 1 se corrieron con un rol que no coincide con el que Supabase usa para aplicar sus grants automáticos del dashboard, así que el rol `authenticated` no tenía el permiso base. Se resolvió en `20260710090500_grants_authenticated.sql`, que además deja un `alter default privileges` para que las tablas que se creen de acá en adelante hereden el grant automáticamente sin tener que acordarse de repetir esto en cada fase.

## GRANTs por rol y EXECUTE de funciones (auditoría 2026-09-25)

Migración `20260925110000_fix_grants_service_role_y_funciones.sql`. Reglas vigentes:

- **`service_role`** (Netlify Functions: `toggle-organizacion`, `alertas-stock-email`) tiene BYPASSRLS pero **no** bypasea los GRANTs de tabla. El proyecto no autoexpone tablas nuevas a los roles de la API, y hasta esta migración solo `authenticated` tenía permisos: suspender una organización fallaba con `permission denied for table super_admins`. Ahora tiene `select/insert/update/delete` sobre `public` y un `alter default privileges` para las tablas nuevas.
- **`anon`** no tiene permisos sobre ninguna tabla ni puede ejecutar ninguna función propia, salvo `validar_codigo_activacion()` (el alta valida el código antes del `signUp`).
- **Toda RPC nueva** hay que dejarla explícitamente así (Postgres las crea ejecutables por PUBLIC): `revoke execute on function public.f(...) from public, anon; grant execute on function public.f(...) to authenticated;`. Las funciones que solo corre `pg_cron` (`purgar_locales_vencidos`) no se le otorgan a nadie.
- **Embeds de PostgREST**: si dos tablas tienen más de una FK entre sí, todo embed debe indicar la relación (`locales!usuarios_local_id_fkey(...)`), o falla con `PGRST201` para todos los usuarios. `usuarios` ↔ `locales` tiene dos (`usuarios.local_id` y `locales.eliminacion_solicitada_por`); otros pares con más de una: `ventas`↔`usuarios`, `invitaciones`↔`usuarios`, `devoluciones_cambios`↔`productos`. Antes de agregar una FK nueva entre dos tablas ya relacionadas, revisar los `select()` que las embeben.

## Auditoría de seguridad (2026-09-25, migración `20260925120000_hardening_seguridad.sql`)

Cada punto se reprodujo simulando al atacante (sesión `authenticated` con el JWT de un usuario real, en una transacción con rollback) antes de corregirlo. Reglas que quedan vigentes:

- **Las policies filtran filas, no columnas**: todo lo que un usuario puede escribir en su propia fila necesita además un trigger que fije las columnas sensibles. Guardas actuales: `organizations` (`plan`, `is_active`, `plan_overrides`, `trial_ends_at`, `codigo_activacion_id`), `usuarios` (`role`, `status`, `local_id`, `organization_id`), `ventas` (solo cambian `total`, `estado`, `anulada_*`; una venta anulada no se reactiva ni se toca su detalle), `turnos` (un turno cerrado solo lo toca un admin), `locales` (`archivado`, `bloqueado_por_plan`, `eliminar_en`). Todas tienen una bandera de sesión `app.bypass_*` para correcciones manuales desde el SQL editor.
- **Los triggers `security definer` que mueven stock o saldos (`aplicar_*`) actúan sobre el id que reciben**: por eso `validar_referencias_mismo_local()` exige que producto/cliente/venta/turno referenciados sean del mismo local y organización. Toda tabla nueva con FK a esas tablas debe agregar su trigger `trg_refs_*`.
- Las ventas solo se cargan en un turno abierto (`trg_validar_turno_abierto_venta`). **Decisión tomada (2026-09-26)**: no se exige que el turno sea del mismo usuario que vende, a propósito: el modo `compartida` de `locales.modo_turno` va a necesitar justamente eso, y bloquearlo ahora para desbloquearlo después es vaivén. Revisar al implementar ese modo.
- Cabeceras de seguridad en `netlify.toml` (sin CSP completa: probar página por página antes de activarla; postergado, no urgente).
- `alertas-stock-email` ya no se autoriza con el header `x-nf-event` (falsificable): exige siempre `ALERTAS_STOCK_SECRET` en el header `x-alertas-secret` y lo dispara pg_cron vía pg_net (migración `20260926090000_cron_alertas_stock.sql`; secretos en Vault).
- Dependencias de CDN fijadas a versión exacta: `supabase-js@2.110.5` (`supabaseClient.js`) y `xlsx@0.20.3` desde cdn.sheetjs.com (`excel.js`; 0.18.5 tenía prototype pollution y ReDoS y npm no publica versiones más nuevas).
- **Anotado para revisar con calma (no tocar ahora)**: `max_locales()` y `local_is_active()` aceptan el id de cualquier organización/local y devuelven info mínima (límite de locales / si está activo) de otras organizaciones. Impacto bajo, y varias policies dependen de ellas: cambiarlas es más riesgoso que el problema.

## Decisiones que quedan abiertas / a confirmar

Estas son supuestos razonables que tomé para no frenar la Fase 1, pero vale la pena que los confirmes:

1. **Visibilidad de `reposiciones_stock` (precio de costo) para empleados**: la dejé visible a cualquier empleado aprobado del local (patrón general), asumiendo que "reponer stock" es una tarea operativa normal, no exclusiva de un rol "encargado" que el documento no define formalmente. Si preferís que el costo de compra sea información solo-admin, es un cambio de una línea en la policy.
2. **`categorias` y `productos` por local, no por organización**: el documento dice que cada local tiene "su propio stock" — asumí que esto también aplica a categorías (cada local arma las suyas), en vez de compartir un catálogo de categorías a nivel organización. Si una organización con varios locales prefiere categorías compartidas, es un cambio de diseño (habría que mover `categorias` a nivel `organization_id` sin `local_id`).
3. **Clientes de cuenta corriente por local, no por organización**: mismo razonamiento — si una cadena quisiera que un cliente fiado en un local también se reconozca en otro local de la misma organización, habría que rediseñar `clientes` a nivel organización.
