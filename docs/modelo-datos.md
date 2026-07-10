# Modelo de datos — Fase 1

Este documento describe el modelo de datos implementado en `supabase/migrations/`. Cada tabla existe para resolver un punto puntual de `spec.md`; se referencia la sección correspondiente entre paréntesis.

## Convención general

Casi todas las tablas "de negocio" tienen **`organization_id` y `local_id` denormalizados**, aunque en teoría `local_id` ya implica la organización (via `locales.organization_id`). Es una decisión deliberada: evita joins dentro de cada policy de RLS (que corren en *cada* fila de *cada* query) y hace que la regla de aislamiento sea idéntica y fácil de auditar en todas las tablas. El costo es un poco de redundancia y la obligación de escribir ambos campos al insertar — asumible a esta escala.

## Tablas fundacionales

### `organizations`
El cliente que se suscribe (sección 1). Tiene `plan` (básico/medio/completo) y `plan_overrides` (jsonb) para excepciones puntuales sin crear una versión de código distinta (sección 15). `is_active` es el corte de acceso manual del super-admin (sección 16), independiente del rol admin de la organización.

### `locales`
Sucursales de una organización (sección 1). `modo_turno` (`individual` / `compartida`) es la configuración por local de la sección 2. Los flags de email (`alerta_stock_email`, `alerta_cierre_caja_email`) viven acá porque son configuración operativa del local, no del producto ni de la organización entera.

### `usuarios`
Perfil de aplicación 1 a 1 con `auth.users` (mismo `id`). Guarda `organization_id`, `local_id` (null para admin, que ve todos los locales), `role` (admin/empleado) y `status` (pending/approved/rejected, sección 3). `current_session_id` y `last_login_at` son la base de datos para la sesión única por dispositivo (sección 3) — la lógica de invalidar la sesión anterior se implementa en Fase 2 con la Admin API de Supabase.

### `invitaciones`
Código de invitación que genera un admin para que un empleado se autoregistre (sección 3). La validación del código por parte de alguien que todavía no tiene fila en `usuarios` no puede pasar por RLS normal (no tiene `organization_id` propio todavía) — se resuelve con una función `security definer` a implementar en Fase 2 (`redimir_invitacion`), que valida el código y crea la fila de `usuarios` en estado `pending` de forma atómica.

## Catálogo

### `categorias` / `productos`
Un producto pertenece a un local (no a toda la organización), reflejando que el stock es independiente por local (sección 1). Campos principales según sección 4: `stock_actual`, `stock_minimo` (por producto, no global), `precio_venta_actual`, `ultimo_precio_costo` (se completa solo desde la última reposición), `codigo_barras` (único por local, índice parcial), `perecedero` + `fecha_vencimiento` + `alerta_vencimiento_dias`. Hay un índice GIN con `pg_trgm` sobre `nombre` para el autocompletado de búsqueda.

### `historial_precios_venta`
Regla transversal de la sección 1 y 4: **el precio de venta nunca se pisa**. Cada fila es un tramo de vigencia (`vigente_desde` / `vigente_hasta`, null = tramo actual). Se puebla solo, vía trigger sobre `productos` — no hay insert/update manual desde el cliente. Importante: esta tabla es para *auditoría histórica* de precios; el congelamiento del precio en cada venta puntual lo hace `venta_items.precio_unitario` directamente (ver más abajo), no depende de esta tabla.

### `proveedores` / `producto_proveedor`
Proveedores por local (carga manual, sección 5). `producto_proveedor` es la relación muchos a muchos, con `precio_referencia` opcional. No existe proveedor "principal": si un producto tiene varios, se elige cuál en cada reposición.

## Stock

### `reposiciones_stock`
Entrada de mercadería (sección 6): cantidad, proveedor, precio de costo pagado. Un trigger `aplicar_reposicion_stock` suma la cantidad a `productos.stock_actual` y actualiza `productos.ultimo_precio_costo`. La tabla en sí *es* el historial de compras que alimenta el "gasto en mercadería" del cierre mensual.

### `ajustes_stock`
Mermas / correcciones manuales (sección 4): `cantidad` con signo, `motivo` de una lista cerrada (`rotura`, `vencido`, `robo`, `error_conteo`, `otro`), con `comentario` obligatorio solo para `otro` (constraint a nivel de tabla). Trigger `aplicar_ajuste_stock` actualiza `productos.stock_actual`.

Ninguna de las dos tablas admite `update`/`delete`: son movimientos contables, se corrigen con un movimiento nuevo en sentido contrario, no reescribiendo el pasado.

## Turnos y ventas

### `turnos`
Caja de un empleado (o de la cuenta compartida) durante su turno (sección 2 y 10). Guarda `efectivo_esperado`, `efectivo_contado`, `transferencia_esperada`, `diferencia`. La "caja diaria consolidada del local" de la sección 10 **no es una fila propia**: se calcula agregando turnos por `local_id` + fecha (ver `cierres_diarios` para la versión persistida de ese cálculo).

### `ventas` / `venta_items` / `venta_pagos`
- `ventas`: cabecera (local, turno, usuario, cliente si es fiado, estado activa/editada/anulada, total).
- `venta_items`: `precio_unitario` es el **precio congelado** al momento de la venta — no se recalcula nunca a partir de `productos.precio_venta_actual`. `subtotal` es una columna generada (`cantidad * precio_unitario`).
- `venta_pagos`: hasta 2 filas por venta (combinación efectivo + transferencia, sección 7). Una venta fiada no tiene filas acá — ver `cuenta_corriente_movimientos`.

Triggers: insertar/editar/borrar un `venta_item` ajusta `productos.stock_actual` automáticamente (`aplicar_stock_venta_item`). Anular una venta (`estado = 'anulada'`) repone el stock de todos sus items (`aplicar_anulacion_venta`). **Punto abierto**: qué pasa con el movimiento de cuenta corriente si se anula una venta fiada — no se implementó automáticamente porque depende de si ya hubo pagos parciales sobre ese fiado; a resolver en el diseño de Fase 6.

## Cuenta corriente de clientes

### `clientes`
Por local (sección 9). `saldo` es un campo cacheado: positivo = el cliente debe (fiado), negativo = el local le debe (saldo a favor). Se mantiene por trigger, la fuente de verdad real es `cuenta_corriente_movimientos`.

### `cuenta_corriente_movimientos`
Un movimiento por evento: `fiado_nuevo`, `cobro_fiado`, `saldo_favor_generado`, `saldo_favor_usado`. `monto` siempre positivo; el trigger `aplicar_movimiento_cuenta_corriente` decide el signo del efecto sobre `clientes.saldo` según el `tipo`. `turno_id` en un `cobro_fiado` es lo que permite que ese cobro compute en la caja del turno en que efectivamente se cobró (sección 9, el ejemplo numérico del documento).

## Devoluciones y reclamos

### `devoluciones_cambios`
Devolución simple o cambio de producto (sección 8). El producto devuelto **nunca vuelve a stock** (se descarta) — por eso no hay trigger que lo reponga. Si es un `cambio`, el producto nuevo sí resta stock (trigger `aplicar_stock_devolucion_cambio`). Si la diferencia de precio se deja como `saldo_pendiente`, el mismo trigger genera automáticamente el movimiento correspondiente en `cuenta_corriente_movimientos` (`fiado_nuevo` si el cliente debe pagar de más, `saldo_favor_generado` si es al revés) — reutilizando el módulo de fiado, tal como pide la sección 8.

### `reclamos_proveedor`
Devolución de mercadería al proveedor (sección 5 y 8). `producto_id` es nullable para el caso de "lote completo" sin discriminar ítem. `estado` (`pendiente` / `repuesto`) es lo que se muestra en la ficha del proveedor.

## Cierres de caja

### `cierres_diarios`
Foto persistida del cierre consolidado de un local en una fecha (sección 10), agregando sus turnos. Se guarda como tabla (no como vista) para que los reportes históricos no dependan de recalcular sobre turnos que podrían mutar más adelante.

### `cierres_mensuales`
Incluye `total_gastos_mercaderia` y `ganancia_bruta` (sección 6 y 10). Al incluir información de costos/margen, su visibilidad en RLS está restringida a admin (ver diseño de RLS).

## Sobre el plan / feature flags (sección 15)

No hay una tabla `planes` ni `features` separada: `organizations.plan` es un enum (`basico`/`medio`/`completo`) y el mapeo de qué funciones incluye cada plan vive en el código de la aplicación (front y back), no en la base. Es a propósito: la sección 15 pide explícitamente que esto sea una segmentación comercial sobre un único modelo de datos, no tablas ni ramas de código distintas por plan. `plan_overrides` (jsonb) queda disponible para excepciones puntuales por organización si hiciera falta, sin tener que crear un plan nuevo.

## Lo que falta para completar el modelo de negocio (a resolver en fases siguientes)

- ~~Función `crear_organizacion(...)`~~ y ~~`redimir_invitacion(codigo, ...)`~~ y ~~sesión única por dispositivo~~: implementadas en Fase 2, ver `docs/auth-design.md`.
- Qué pasa con la cuenta corriente al anular una venta fiada que ya tuvo pagos parciales (Fase 6).
- Cálculo/población de `cierres_diarios` y `cierres_mensuales` (job o acción manual del admin) — las tablas están listas, falta la lógica que las llena (Fase 7).
- **Selector de local para admin en organizaciones multi-local** (Fase 3, pendiente de Fase 13): el admin no tiene `local_id` propio (ve todos los locales de su organización), así que al día de hoy, cuando crea un producto o categoría, el frontend usa automáticamente el primer local de la organización — no hay todavía un selector para elegir a cuál local pertenece lo que está cargando. Como Básico/Medio son de 1 local, no afecta a la mayoría de los casos; hay que resolverlo cuando se construya el soporte multi-local (Fase 13).
