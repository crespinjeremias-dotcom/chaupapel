# Especificación funcional — Sistema de gestión de productos y contabilidad para locales (tipo almacén)

## 0. Contexto para quien retoma este proyecto

Este documento resume el relevamiento funcional completo de una app pensada para digitalizar la gestión de locales tipo almacén/kiosco de barrio (stock, proveedores, ventas y caja), reemplazando el registro en papel. El relevamiento ya está cerrado; el siguiente paso es el **diseño técnico**: modelo de base de datos, arquitectura y desarrollo del código.

**Antecedente técnico relevante**: quien desarrolla este proyecto ya tiene experiencia previa con **Supabase + Netlify** en un proyecto de gestión de turnos que está funcionando en producción. Es el stack candidato natural para continuar (Postgres con Row Level Security es un buen fit para el modelo multi-tenant que se describe más abajo), pero queda abierto a revisión técnica.

**Alcance del sistema**: es una herramienta de **gestión interna** (stock, ventas, caja). No emite comprobantes fiscales ni se integra con sistemas de facturación electrónica — eso queda fuera del alcance del desarrollo actual (aunque, ver sección 16, la arquitectura queda preparada para sumarlo más adelante sin rediseñar lo ya construido).

**Modelo de negocio**: es un producto **SaaS multi-tenant** por suscripción — varios locales/negocios independientes contratan el servicio, cada uno con sus datos completamente aislados de los demás. Un mismo cliente (dueño o cadena) puede tener uno o varios locales bajo su misma cuenta.

---

## 1. Estructura general (multi-tenant)

- **Organización / Cuenta** = el cliente que se suscribe al servicio.
- Una Organización puede tener **uno o varios Locales**.
- Cada Local tiene: su propio stock, sus propios proveedores, sus propios empleados y su propia caja diaria — todo independiente entre locales, aunque pertenezcan a la misma organización.
- Los datos de una Organización **nunca son visibles** para otra Organización (aislamiento total).
- El admin de una organización con varios locales puede:
  - Ver el detalle de cada local por separado.
  - Ver un **dashboard consolidado** que suma las cajas/movimientos de todos sus locales juntos.

---

## 2. Roles y usuarios

Dos roles:

### Admin / Dueño
- Carga y edita productos, categorías, proveedores.
- Aprueba el alta de las cuentas de los empleados.
- Ve todo: stock, ventas, caja, reportes, de todos los locales de su organización.
- Es el único que puede editar/anular una venta fuera de la ventana de tiempo permitida.
- Configura las alertas (stock mínimo por producto, vencimientos, notificaciones).
- Configura si los turnos son con cuenta individual por empleado o cuenta compartida (ver más abajo).

### Empleado
- Tiene su propia cuenta, creada mediante un proceso de auto-registro + aprobación del admin (ver sección 3).
- Carga las ventas durante su turno.
- Recibe alertas de stock bajo.
- Realiza el cierre de caja de su turno.
- No accede a la configuración general del sistema ni a los datos de otros locales.

### Modo de manejo de turnos (configurable por el admin, por local)
1. **Cuenta individual por empleado (modo recomendado)**: cada empleado inicia sesión con su propia cuenta y abre su propio turno con caja en cero, carga sus ventas, y cierra su turno al finalizar. Todas las cajas individuales del día suman a una **caja diaria consolidada del local**. Da trazabilidad: se sabe exactamente qué empleado cargó cada venta.
2. **Cuenta compartida**: una sola cuenta que queda abierta durante todo el día, sin distinguir entre empleados que se turnan. Más simple, pero sin trazabilidad por persona.

---

## 3. Registro y acceso de usuarios

### Login (admin y empleados por igual)
- Campos: **email o número de teléfono** + contraseña.
- Botón "Iniciar sesión".
- Debajo: link/botón **"Registrarse"** y link/botón **"Olvidé mi contraseña"**.

### Alta de una organización nueva (auto-servicio)
- Un local nuevo entra al link público del sistema y se registra por sí mismo como **organización/admin**, sin necesidad de que el dueño del SaaS intervenga (elige o le queda asignado un plan). Ver también sección 16.
- Una vez adentro, ese admin da de alta a sus empleados.

### Alta de un empleado (única vez, por invitación + aprobación)
1. El admin genera un **código de invitación** (o link) único de su organización y se lo pasa al empleado (ej. por WhatsApp).
2. El empleado se registra con su propio mail + contraseña, ingresando ese código — así el sistema asocia automáticamente la cuenta nueva a la organización correcta.
3. La solicitud queda **pendiente de aprobación** en el panel del admin.
4. El admin la aprueba con un clic, y recién ahí el empleado tiene acceso real al sistema.

### Login vs. apertura de turno
- Son **dos pasos separados**: primero se inicia sesión (puede ser solo para consultar algo, como stock), y después hay un botón aparte de **"Iniciar turno"** para arrancar a vender.
- En el modo de cuenta compartida, cualquiera que entre a esa cuenta puede iniciar un turno o simplemente usar el sistema sin abrir uno (ej. para completar stock).

### Cambio de turno en el mismo dispositivo
Cuando varios empleados comparten una misma tablet/PC del mostrador: se cierra sesión del empleado anterior → vuelve la pantalla de login → el siguiente empleado inicia sesión y abre su propio turno.

### Recuperación de contraseña
Con el botón "Olvidé mi contraseña": se envía un código al mail o número cargado, para poder restablecerla. Válido tanto para admin como para empleados.

### Sesiones simultáneas
Si un usuario ya tiene una sesión abierta en otro dispositivo y trata de iniciar sesión en uno nuevo, el sistema muestra una alerta ("ya hay una sesión abierta en otro dispositivo") con la opción de cerrar esa sesión anterior y continuar en el dispositivo actual.

---

## 4. Módulo: Productos e inventario

Cada producto tiene los siguientes campos (todos editables después de la carga inicial):

- **Nombre** (ej: "Coca Cola")
- **Tamaño/presentación** (ej: 1,25 — puede variar por producto)
- **Unidad de medida** (unidad, litros, kg, gramos, etc.)
- **Categoría** (almacén, lácteos, bebidas, limpieza, etc. — configurable)
- **Perecedero / no perecedero** (checkbox al cargar el producto)
- **Fecha de vencimiento** (si aplica)
- **Alerta de vencimiento**: opcional y configurable por producto — "avisar X días antes de vencer", o desactivada.
- **Stock actual**
- **Stock mínimo**: configurable **por producto individual** (no es un número global). Ejemplo: Coca Cola puede tener un mínimo de 20 unidades, trapos de piso un mínimo de 5, porque tienen rotación distinta.
- **Precio de venta actual**
- **Último precio de costo**: campo de referencia rápida que se completa solo, tomando el precio de la última reposición de stock registrada (ver sección 6). No reemplaza al historial completo de compras, es solo un dato rápido en la ficha del producto.
- **Código de barras** (opcional, si el producto lo tiene)

### Historial de precios de venta
- **El precio nunca se pisa**: cada vez que se actualiza el precio de venta de un producto, el sistema guarda el precio anterior con fecha de vigencia.
- Cada venta registra el precio al que se vendió en ese momento exacto (no el precio actual del producto). Esto es indispensable para que el cierre de caja de días/meses anteriores siga cuadrando aunque los precios hayan cambiado después.

### Búsqueda de productos (al momento de vender)
Dos métodos en paralelo (el local usa el que tenga a mano):
1. **Código de barras**: lectura con pistola lectora física o con la cámara del celular/tablet.
2. **Buscador por nombre con autocompletado**: método universal para locales sin lector.

Este buscador (el que usa el empleado al vender) **solo busca productos**, nunca proveedores.

### Ajuste manual de stock (mermas, errores)
Botón "Ajustar stock" dentro de la ficha del producto, para los casos donde el stock cambia sin ser una venta:
- Cantidad (suma o resta)
- **Motivo obligatorio**, de una lista predefinida: Rotura/daño, Vencido, Robo/faltante, Error de conteo, Otro (este último con comentario obligatorio)
- Campo de comentario adicional libre (opcional salvo en "Otro")
- Queda registrado con fecha y el usuario que lo hizo, formando un historial de movimientos de stock fuera de las ventas normales.

### Vinculación con proveedores
En la ficha del producto se puede ver la lista de proveedores que lo proveen (la vinculación en sí se gestiona desde la pantalla de Proveedores, ver sección 5). No se muestra el precio del proveedor por defecto, salvo un campo opcional de **"precio de referencia"**, para cuando el proveedor maneja un precio más o menos fijo.

### Lote
Se evaluó incluir número de lote (trazabilidad de partidas de mercadería), pero **se descartó** por ser innecesario para la escala de un almacén de barrio.

---

## 5. Módulo: Proveedores

Carga completamente manual, hecha por cada local que use el sistema. Campos del proveedor:

- Nombre
- Teléfono / WhatsApp de contacto
- Email (opcional)
- Dirección (opcional)
- **Notas libres** (ej: "entrega los martes", "la yerba la trae los jueves")

### Relación con productos
- Un proveedor puede proveer **varios productos**, y un producto puede tener **varios proveedores** (relación muchos a muchos).
- La vinculación producto-proveedor se gestiona **desde la pantalla de Proveedores**: el admin elige qué productos provee cada proveedor.
- No existe un proveedor "principal" por producto — si hay más de uno, el admin elige cuál usó cada vez que repone stock.

### Ficha del proveedor
Muestra un listado de los productos vinculados a ese proveedor, junto con la **fecha de la última reposición de stock** de cada uno.

### Reclamos y devoluciones al proveedor
Cuando el local devuelve mercadería a un proveedor (producto defectuoso o lote completo — ver sección 8), queda un estado visible en la pantalla de ese proveedor: **"reclamo realizado / pendiente de reposición"**.

---

## 6. Módulo: Reposición de stock

Acción para cargar mercadería nueva que llega al local. Accesible **tanto desde Productos como desde Proveedores** (misma acción, dos puntos de entrada).

### Flujo
1. Se dispara típicamente cuando el sistema avisa stock bajo de un producto (aunque también se puede hacer sin ese disparador).
2. El admin/encargado ingresa: cantidad que llegó, proveedor al que se le compró, y precio de costo pagado en esa compra.
3. El stock del producto sube automáticamente con esa cantidad.
4. El sistema guarda ese gasto asociado al proveedor y a la fecha (queda en el historial de compras).
5. En el **cierre de caja mensual**, aparece un total de "gastos en mercadería/proveedores del mes", separado de los ingresos por ventas — dando una primera foto de ganancia bruta (ventas − compras).

---

## 7. Módulo: Ventas (punto de venta)

### Flujo de carga de una venta
1. El empleado busca el producto (por nombre o código de barras).
2. Selecciona la cantidad vendida.
3. El sistema calcula el total automáticamente y descuenta del stock.
4. El empleado selecciona el **método de pago**: puede ser una combinación de hasta dos métodos por venta (ej: parte efectivo, parte transferencia) — o marcarla como **fiado** (ver sección 9).
5. La venta queda registrada en un historial.

### Edición / anulación de ventas
- El empleado puede editar o anular una venta **solo dentro de una ventana de 10-15 minutos** después de cargada.
- Pasado ese tiempo, la venta queda bloqueada para el empleado y **solo el admin** puede modificarla.

### Historial de ventas
Registro de todas las ventas, consultable con filtro (especialmente vista mensual).

---

## 8. Módulo: Devoluciones y cambios

Aplica únicamente por un **motivo real de producto** (rotura, vencido, defectuoso, etc.) — **no existe la devolución por arrepentimiento**, ya que no es una práctica habitual en almacenes/kioscos de alimentos.

### Cliente devuelve o cambia un producto
- Se registra vinculado a la venta original, con motivo.
- El producto devuelto **siempre resta del stock** (se descarta, no vuelve a venderse), sin excepciones.
- **Cambio por otro producto** (puede ser de otra marca o precio distinto): se busca el producto nuevo y se vincula a la compra original.
  - Si hay **diferencia de precio**, el sistema la muestra y ofrece dos caminos, a elección del momento:
    1. **Resolver ahora**: el cliente paga la diferencia (si el nuevo cuesta más) o se le devuelve en efectivo (si cuesta menos) — como cerrar una venta normal, sin dejar nada pendiente.
    2. **Dejarlo como saldo**: queda anotado como saldo a favor o en contra a nombre del cliente, usando el mismo módulo de cuenta corriente que el fiado (sección 9). En este caso hace falta pedir el nombre del cliente para poder registrarlo.

### Local devuelve mercadería a un proveedor
- Se registra motivo + producto(s), o el lote completo.
- El stock de esos productos se resta (ya no están disponibles para vender).
- Queda marcado como **"pendiente de reposición"** en la ficha de ese proveedor (sección 5), a la espera de que traiga el cambio.

---

## 9. Módulo: Cuenta corriente de clientes (fiado y saldo a favor)

Funcionalidad opcional (activable/desactivable por el negocio), pensada originalmente para el fiado típico de almacén de barrio, y que también absorbe los saldos a favor que puedan surgir de un cambio de producto (sección 8).

### Fiado (el cliente debe)
- El empleado carga una venta marcada como **"fiado"**, asociada a un nombre de cliente.
- El producto **descuenta del stock** igual que cualquier venta.
- El monto **no suma a la caja del día** — va a una cuenta de "cuentas por cobrar" asociada a ese cliente.
- Cuando el cliente paga (total o parcial), ese pago se carga como ingreso del día en que se cobra, con su método de pago, y se descuenta del saldo pendiente.

### Saldo a favor (el local le debe al cliente)
- Surge cuando, en un cambio de producto con diferencia de precio a favor del cliente, se elige dejarlo pendiente en vez de devolver el efectivo en el momento (sección 8).
- Se descuenta la próxima vez que ese cliente compre, o se le devuelve cuando corresponda.

### Cómo impacta en la caja (ejemplo numérico de referencia)

**Día 1 — ventas del día:**

| Concepto | Monto |
|---|---|
| Ventas cobradas en efectivo | $10.000 |
| Ventas cobradas por transferencia | $5.000 |
| Ventas nuevas a fiado (no cobradas hoy) | $3.000 |
| Cobro de un fiado de días anteriores (pagado hoy en efectivo) | $2.000 |

**Lo que el sistema muestra al cerrar caja:**
- Efectivo esperado = $10.000 (contado) + $2.000 (cobro fiado viejo) = **$12.000**
- Transferencia esperada = **$5.000**
- Fiado nuevo generado hoy (pendiente de cobro) = **$3.000**
- Total vendido hoy (cobrado o no) = **$18.000**

**A nivel mensual, la misma lógica pero acumulada:**
- Total vendido en el mes = suma de todas las ventas del mes (cobradas o no).
- Total efectivamente cobrado (efectivo + transferencia) = ventas de contado del mes + cobros de fiados (incluso de meses anteriores).
- Saldo total de fiado pendiente = deuda acumulada no cobrada (puede incluir meses anteriores).

Esto permite que la caja **nunca "no cierre"** por culpa del fiado: siempre queda separado como una cuenta a cobrar aparte.

### Reporte
Saldo pendiente total y por cliente (tanto deuda como saldo a favor).

---

## 10. Módulo: Caja (cierre de turno)

### Flujo de cierre de caja
1. Durante el turno, el empleado carga ventas con su método de pago correspondiente (incluyendo fiado si aplica).
2. Al finalizar el turno, el sistema calcula automáticamente cuánto debería haber en efectivo y en transferencia.
3. El empleado cuenta el efectivo físico y lo ingresa al sistema.
4. El sistema compara: si coincide, cierra sin observaciones; si no, queda registrada la diferencia (sobrante/faltante), visible para el admin.

### Caja consolidada
En modo de cuentas individuales por empleado, todas las cajas de los distintos turnos del día se consolidan en una caja diaria total del local, sin perder el detalle de qué correspondió a cada turno.

### Cierre mensual
Además de lo ya descripto en la sección 9, incluye el total de **gastos en mercadería/proveedores del mes** (sección 6), para tener una primera foto de ganancia bruta.

---

## 11. Módulo: Notificaciones y alertas

### Alerta de stock bajo
- Se dispara cuando el stock de un producto baja del mínimo configurado para ese producto.
- Dos canales independientes entre sí (activables por separado, cualquier combinación):
  1. Aviso dentro de la app.
  2. Email al dueño/encargado.
- No se incluye WhatsApp (requeriría un servicio externo con costo por mensaje; no forma parte del MVP).

### Alerta de vencimiento próximo
Configurable por producto (activar/desactivar y días de anticipación).

### Notificación de cierre de caja por email
Aviso al admin cuando se cierra una caja (no todos los locales lo van a querer, por eso se ubica en un plan más alto — ver sección 15).

### Dónde se muestran las alertas
Todas agrupadas en una sección central de alertas/dashboard (stock bajo, productos por vencer, reclamos a proveedores pendientes).

---

## 12. Módulo: Reportes y estadísticas

- Historial de ventas, filtrable (especialmente vista mensual).
- Productos más vendidos, con filtro por franja horaria.
- Estadística mensual automática del negocio.
- Productos por vencer (integrado en el dashboard de alertas).
- Cierres de caja históricos (diarios y mensuales, incluyendo gasto en mercadería).
- Reporte de cuenta corriente de clientes: saldo pendiente y a favor, total y por cliente.
- Historial de ajustes de stock (mermas) con motivo.
- Exportación a Excel: ventas, cierres de caja, stock.
- Importación de productos vía Excel: carga masiva para no tener que cargar producto por producto al arrancar.

*(Nota: se descartó explícitamente un reporte de "ventas por empleado" — no es una función solicitada).*

---

## 13. Comprobante no fiscal

Al cerrar una venta, el sistema puede generar un **resumen de compra** (nombre del local, fecha, productos, cantidades, precios, total) para mostrar o entregar al cliente — en pantalla, para imprimir con una impresora térmica si el local tiene una, o descargar como PDF. Lleva la leyenda **"Comprobante no válido como factura"**. No tiene ningún dato fiscal (sin CAE, sin datos de ARCA) — es solo un respaldo interno de la compra.

---

## 14. Dispositivos

El sistema debe funcionar bien en cualquier dispositivo sin depender de uno en particular: celular personal del empleado, celular provisto por el local, tablet, o PC/notebook del local. Diseño responsive es un requisito central.

---

## 15. Modelo de planes de suscripción

Se definieron **3 planes**, armados a partir de qué tan imprescindible es cada función para un almacén/kiosco de barrio típico. Las funciones más "core" van en el plan más económico; las más avanzadas o que solo aplican a negocios más grandes, en los planes más altos.

**Importante para el diseño técnico**: esta es una segmentación **comercial**, no debe traducirse en versiones distintas del código. Implementarlo con un sistema de **feature flags por organización** (un campo que indica el plan contratado, validado en front/back para mostrar u ocultar módulos). Todos los clientes comparten el mismo sistema y modelo de datos.

### Plan Básico
Para el almacén/kiosco chico, atendido por el dueño solo o con poco personal fijo.
- Carga de productos (nombre, categoría, precio, stock)
- Registro de ventas con descuento automático de stock
- Cierre de caja diario (efectivo/transferencia esperado vs. contado)
- Alerta de stock bajo (solo dentro de la app)
- Búsqueda de productos por nombre
- Listado de proveedores
- Historial de ventas mensual
- Cuenta corriente de clientes (fiado y saldo a favor) — se incluye desde este plan por ser una práctica muy típica del almacén de barrio chico
- 1 local, cuenta de usuario única (sin perfiles individuales por empleado)

### Plan Medio
Para locales con empleados rotando turnos y/o que manejan productos perecederos.
Todo lo del Plan Básico, más:
- Alerta de stock bajo también por email
- Lectura de código de barras (cámara o lector físico)
- Fecha de vencimiento por producto + alertas configurables
- Cuentas individuales por empleado (turnos con trazabilidad y caja diaria consolidada)
- Importación/exportación de productos vía Excel
- Sigue siendo 1 local

### Plan Completo
Para locales que ya facturan más en serio, quieren métricas del negocio, o tienen más de un local.
Todo lo del Plan Medio, más:
- Estadísticas y productos más vendidos (por franja horaria)
- Notificación de cierre de caja por email
- Soporte multi-local con dashboard consolidado

### Funciones que van en los 3 planes por igual (no son un diferencial comercial)
Son parte del motor interno del sistema, necesarias en cualquier plan para que la operación diaria y la caja funcionen correctamente:
- Historial de precios de venta (nunca se pisa)
- Ventana de edición/anulación de ventas de 10-15 minutos
- Ajuste manual de stock por mermas
- Reposición de stock (con registro de costo y gasto en mercadería)
- Devoluciones y cambios de producto

### Pendiente de definir (no bloquea el desarrollo)
- Precio en pesos de cada plan (referencia de mercado: un competidor directo, KioscoSoft, cobra desde aprox. $29.000 ARS/mes para un comercio chico de un solo local; la idea es arrancar por debajo de ese valor como estrategia de entrada).
- Duración del período de prueba gratuita (referencia de mercado: 7 días).

---

## 16. Gestión de la propia suscripción SaaS (panel del dueño del sistema)

Esto no es una funcionalidad que use el cliente final (el almacén), sino la operación propia del negocio.

- **Alta de organizaciones**: auto-servicio. Un local nuevo se registra por sí solo (sección 3), sin intervención manual del dueño del SaaS.
- **Instalación**: al ser un sistema web, no hay instalador tradicional. Se implementa como **PWA (Progressive Web App)**: desde el navegador, tanto en PC como en celular/tablet, hay una opción de "Instalar aplicación" que crea un ícono como si fuera un programa/app nativa. No es obligatorio instalarlo para usar el sistema, queda como comodidad opcional.
- **Cobro de la suscripción**: manual, vía alias/QR de una billetera virtual. Ciclo de pago del **día 1 al 15 de cada mes**. Pasado el día 15, se aplica un recargo (10-15%, número final a definir junto con el precio de cada plan).
- **Corte de acceso por falta de pago**: manual — se evalúa caso por caso con el cliente, sin automatización. Requiere un panel de super-admin con un botón para activar/desactivar el acceso de una organización.
- **Cambio de plan**: el propio admin de cada organización puede subir o bajar de plan (Básico/Medio/Completo) desde su panel, sin intervención del dueño del SaaS.
- **Nota de escalabilidad futura**: si más adelante se necesita sumar facturación fiscal (integración con ARCA) para algún local, es viable agregarla como un módulo adicional sin rediseñar lo ya construido — cada venta ya guarda toda la información necesaria (productos, cantidades, precios, fecha, total) gracias al historial de precios.

---

## 17. Resumen de flujos clave (para referencia rápida)

**Flujo de venta simple:**
Empleado busca producto (nombre o código de barras) → selecciona cantidad → sistema calcula total y descuenta stock → empleado indica método(s) de pago → venta queda registrada (editable 10-15 min).

**Flujo de venta a fiado:**
Empleado carga venta → selecciona "fiado" → ingresa nombre del cliente → stock se descuenta → monto va a cuenta por cobrar del cliente.

**Flujo de cobro de fiado:**
Cliente paga → se busca su cuenta pendiente → se registra el pago con su método → se suma a la caja del día en que se cobra → se descuenta del saldo pendiente.

**Flujo de cierre de caja:**
Sistema calcula efectivo y transferencia esperados → empleado cuenta efectivo físico → sistema compara → cierra caja (con o sin diferencia registrada).

**Flujo de alerta de stock bajo:**
Venta o ajuste descuenta stock → stock queda por debajo del mínimo del producto → se dispara notificación in-app y/o email, según lo activado.

**Flujo de reposición de stock:**
Se detecta stock bajo (o el admin decide reponer) → se carga cantidad + proveedor + precio de costo → stock sube → gasto queda registrado para el reporte mensual.

**Flujo de ajuste de stock (merma):**
Se detecta una diferencia (rotura, vencimiento, faltante) → se carga +/- cantidad con motivo → queda en el historial de movimientos.

**Flujo de devolución/cambio de producto:**
Cliente trae un producto con problema → se vincula a la venta original con motivo → stock resta → si es un cambio por otro producto con diferencia de precio, se resuelve en el momento o se deja como saldo en la cuenta corriente del cliente.

**Flujo de alta de empleado:**
Admin genera código de invitación → empleado se registra con mail/contraseña + código → queda pendiente → admin aprueba → empleado puede iniciar sesión y abrir turno.

**Flujo multi-local:**
Admin de organización con varios locales → entra a dashboard consolidado → puede entrar al detalle de cualquier local individual.

---

## 18. Stack técnico recomendado

Quien desarrolla este proyecto ya tiene un proyecto previo en producción (gestión de turnos, nombre interno "CopiaCrew") construido con: **HTML + CSS + JavaScript plano (sin frameworks)**, **Supabase** como backend (Postgres + Auth), **Netlify** para hosting, **Netlify Functions** para lógica de servidor (usadas ahí para el envío de emails de confirmación), y ya cuenta con **manifest.json + service worker (PWA)** configurados y funcionando.

**Recomendación: continuar con el mismo enfoque para este proyecto nuevo**, por las siguientes razones:
- Ya está probado en producción, sin fricción de aprendizaje de un framework nuevo.
- El desarrollo se delega en Claude Code, por lo que las ventajas de productividad que da un framework para quien escribe el código a mano pesan menos acá.
- El aislamiento entre organizaciones (multi-tenant) se resuelve a nivel de base de datos con **Row Level Security de Supabase**, es independiente del lenguaje de frontend elegido.
- Se puede reutilizar directamente el PWA (instalación como app, sección 16) y las Netlify Functions ya construidas (útiles para los emails de alertas de stock bajo y cierre de caja, sección 11), ahorrando desarrollo desde cero.

**Único punto de atención**: este sistema tiene bastantes más pantallas y módulos interconectados que el proyecto anterior (productos, ventas, caja, fiado, proveedores, reportes, planes). En HTML/JS plano esto puede volverse difícil de mantener si no se organiza bien desde el arranque. La recomendación técnica es pedirle explícitamente a Claude Code que **organice el JavaScript en módulos separados por función** (por ejemplo, `productos.js`, `ventas.js`, `caja.js`, `proveedores.js`, `fiado.js`, con funciones compartidas para la conexión a Supabase y utilidades comunes), en vez de mezclar toda la lógica dentro de cada archivo HTML.

### Resumen del stack a comunicar
- **Frontend**: HTML + CSS + JavaScript plano (sin frameworks), organizado en módulos por función.
- **Backend**: Supabase (Postgres + Auth + Row Level Security para el aislamiento multi-tenant).
- **Hosting**: Netlify, con Netlify Functions para el envío de emails (alertas, notificaciones).
- **Instalación**: PWA (manifest.json + service worker), reutilizando la base ya construida en el proyecto anterior.
- Librerías puntuales a evaluar cuando se necesiten: lectura de código de barras por cámara, y una librería para exportar/importar Excel.

---

## 19. Puntos que quedan abiertos para definir en la etapa de diseño técnico

- Número exacto del recargo por pago tardío de la suscripción (10-15%, a definir junto con el precio final de cada plan).
- Precio en pesos de cada plan (Básico/Medio/Completo).
- Nombre/marca del producto.
- Diseño visual/UI concreto (más allá del requisito de ser responsive).