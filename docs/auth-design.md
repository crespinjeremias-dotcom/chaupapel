# Auth — Fase 2

## Decisión: login solo por email

La spec pedía login por email o teléfono. Se resolvió con el usuario: el teléfono se guarda como dato de contacto (`usuarios.telefono`), pero login y recuperación de contraseña son siempre por email, usando Supabase Auth nativo. Login por teléfono real requeriría contratar un proveedor SMS (Twilio o similar) con costo por mensaje — se descartó para no sumar un gasto variable ni una dependencia externa antes del primer cliente pagando. Si en algún momento hace falta, se puede sumar después sin rediseñar nada (es aditivo).

## Confirmación de email: desactivada

El proyecto de Supabase venía con `enable_confirmations = true` por defecto. Se desactivó (`supabase/config.toml`, sección `[auth.email]`) porque la spec no menciona un paso de "confirmá tu email" en ningún lado, y ya existe una instancia de confirmación humana en el flujo de empleados (aprobación del admin, sección 3). Para el admin fundador de una organización no hay ningún paso de revisión — es el que paga, se confía directo. Con la confirmación activada, `supabase.auth.signUp()` no devuelve una sesión activa hasta que el usuario clickea el link del mail, lo cual hubiera roto el flujo de "signUp → RPC que crea la organización en el mismo paso".

## Por qué `crear_organizacion` y `redimir_invitacion` son funciones, no inserts directos

Ver [rls-design.md](rls-design.md#alta-de-organización-y-de-usuarios-por-qué-no-es-100-rls). En resumen: `usuarios` no tiene policy de insert, toda alta pasa por una función `security definer` que puede validar contra otras tablas (código de invitación válido, no vencido, no usado) antes de crear la fila.

## Asignación de local en el alta de empleado

La invitación (sección 3) asocia al empleado a una organización, no necesariamente a un local específico — la spec no lo menciona. Se resolvió así: si la organización tiene un solo local, `redimir_invitacion` se lo asigna automáticamente. Si tiene varios, el empleado queda con `local_id = null` hasta que el admin lo elija al aprobar (el panel se lo pide antes de habilitar el botón "Aprobar"). Un constraint (`usuarios_empleado_approved_requiere_local`) impide que quede en estado `approved` sin local asignado, para que no exista un usuario "fantasma" con acceso aprobado pero sin ningún dato visible.

## Sesión única por dispositivo

No hay forma de *bloquear* un login por esto — la spec pide mostrar una alerta con opción de cerrar la sesión anterior, no impedir el nuevo login. Implementado así:

1. Login normal (`supabase.auth.signInWithPassword`).
2. El front decodifica el `session_id` del JWT recién emitido y llama a la función `registrar_sesion(session_id)`, que compara contra `usuarios.current_session_id` guardado la vez anterior y lo actualiza.
3. Si había un `session_id` distinto guardado, se muestra un aviso en pantalla (no un `confirm()` nativo del navegador, para que la UI sea consistente y testeable) con dos opciones: "cerrar sesión anterior" (`supabase.auth.signOut({ scope: 'others' })`, invalida todos los refresh tokens salvo el actual) o "mantener ambas" (no hace nada más).

Limitación conocida y aceptada para el MVP: si se abren tres sesiones seguidas sin cerrar ninguna, solo se detecta la más reciente contra la anterior inmediata — no hay un registro de *todas* las sesiones abiertas, solo de la última. Alcanza para el caso de uso real (alguien se olvidó de cerrar sesión en la PC del local y ahora entra desde su celular).

## Hallazgos al probar en el navegador (ver también rls-design.md)

- **`organizations.is_active` editable por el propio admin**: bug real encontrado probando el flujo — se corrigió con un trigger que solo permite tocar esa columna con la `service_role` key.
- **Faltaba `GRANT` a nivel tabla para `authenticated`**: RLS por sí sola no alcanza, Postgres exige el permiso de tabla antes. Corregido y dejado automático para tablas futuras.

## Qué falta (no bloquea Fase 2, pendiente para más adelante)

- Probar el flujo completo de "restablecer contraseña" con un link real de email (no se pudo simular sin acceso a una casilla real en este entorno de pruebas). El código sigue el patrón estándar de Supabase (`onAuthStateChange` con evento `PASSWORD_RECOVERY`), pero no quedó verificado en vivo end-to-end.
- Plantillas de email de Supabase (confirmación, recuperación) están con el diseño default — personalizarlas es cosmético, no bloquea funcionalidad.
- Panel de super-admin para manejar `is_active` (Fase 15).
