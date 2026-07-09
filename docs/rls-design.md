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

## Panel de super-admin del SaaS (sección 16)

El panel de super-admin (Fase 15) **no es un rol dentro de RLS** — no hay un `role = 'superadmin'` en `usuarios`. Las operaciones de super-admin (activar/desactivar una organización) se hacen con la **service role key** de Supabase desde una Netlify Function, que bypasea RLS por completo. Es un panel operado por fuera del modelo multi-tenant, no un usuario más de alguna organización.

## Decisiones que quedan abiertas / a confirmar

Estas son supuestos razonables que tomé para no frenar la Fase 1, pero vale la pena que los confirmes:

1. **Visibilidad de `reposiciones_stock` (precio de costo) para empleados**: la dejé visible a cualquier empleado aprobado del local (patrón general), asumiendo que "reponer stock" es una tarea operativa normal, no exclusiva de un rol "encargado" que el documento no define formalmente. Si preferís que el costo de compra sea información solo-admin, es un cambio de una línea en la policy.
2. **`categorias` y `productos` por local, no por organización**: el documento dice que cada local tiene "su propio stock" — asumí que esto también aplica a categorías (cada local arma las suyas), en vez de compartir un catálogo de categorías a nivel organización. Si una organización con varios locales prefiere categorías compartidas, es un cambio de diseño (habría que mover `categorias` a nivel `organization_id` sin `local_id`).
3. **Clientes de cuenta corriente por local, no por organización**: mismo razonamiento — si una cadena quisiera que un cliente fiado en un local también se reconozca en otro local de la misma organización, habría que rediseñar `clientes` a nivel organización.
