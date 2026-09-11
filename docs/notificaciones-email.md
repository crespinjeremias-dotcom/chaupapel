# Notificaciones por email — Fase 9

Implementa lo que quedaba pendiente de la sección 11: alerta de stock bajo
por email (Plan Medio+) y notificación de cierre de caja por email (Plan
Completo). Ver también `netlify/functions/README.md` para el detalle de
cada función.

## Servicio de email: Resend

Se evaluaron Resend, SendGrid y Mailgun (presentadas y aprobadas por el
usuario antes de implementar). Se eligió Resend por ser el más simple de
integrar (sin revisión de "sender identity" como SendGrid, sin necesitar
dominio verificado desde el día uno como Mailgun) y porque su free tier
(3.000 emails/mes) sobra para el volumen esperado acá (alertas por
organización, no marketing masivo). Se llama a su API REST directo por
`fetch` (`netlify/functions/lib/resend.js`) en vez de sumar su SDK como
dependencia — es una sola llamada, no lo justifica.

## Dos funciones, dos modelos de autorización distintos

- **`notificar-cierre-caja.js`**: la dispara el cliente (admin logueado)
  justo después de cerrar la caja del día (`caja.html`). Usa el JWT de quien
  llama + la anon key, no la service role key — dejar que RLS decida qué
  puede leer es más simple y más seguro que reimplementar el chequeo a
  mano, y alcanza porque el cierre que se quiere notificar es exactamente
  el mismo que ese admin ya podía ver en `caja.html`.
- **`alertas-stock-email.js`**: la dispara únicamente el cron de Netlify, no
  hay un usuario logueado de quien tomar un JWT porque tiene que recorrer
  **todas** las organizaciones en una sola corrida. Por eso sí necesita la
  service role key, igual que `toggle-organizacion.js`.

## Por qué un digest diario y no un email por evento (stock bajo)

Un producto puede quedar por debajo del mínimo en cualquier venta y seguir
ahí por días hasta que se repone — mandar un email cada vez que se vende
una unidad más de un producto ya en alerta inundaría al admin. Se optó por
un cron diario (`netlify.toml`, 12:00 UTC = 9am Argentina) que manda un
solo resumen por local con todo lo que sigue en alerta ese día. El cierre
de caja, en cambio, es un evento puntual (una vez por local por día) — ahí
sí tiene sentido notificar al toque.

## Feature flags de plan nuevos

`public/js/planes.js` (`PLAN_MINIMO_POR_FEATURE`): `email_stock_bajo`
(Medio) y `email_cierre_caja` (Completo), tal como los define la sección
15. `netlify/functions/lib/planes.js` espeja el mismo mapa para esas dos
claves — no se puede importar `planes.js` directo desde una function
porque `supabaseClient.js` importa `@supabase/supabase-js` desde una URL
de CDN, y Node no resuelve imports por URL. **Si se agrega o cambia el
plan mínimo de alguno de estos dos features, hay que actualizar los dos
archivos.**

## Los toggles por local ya existían en el modelo de datos

`locales.alerta_stock_email` y `locales.alerta_cierre_caja_email` ya
estaban en el schema desde la Fase 1 (ver `docs/modelo-datos.md`), pero no
había ninguna UI para prenderlos ni nada que efectivamente mandara el
email. Se agregó el control en "Mis locales" (`panel.html`), gateado por
la misma `tieneFeature` que el resto del panel — si el plan no incluye el
feature, el checkbox correspondiente ni se muestra (no solo se
deshabilita). También se revalida server-side (`tieneFeatureServer`) por si
el toggle quedó prendido de antes de una baja de plan.

## Destinatarios

Se le manda a todos los `usuarios` con `role = 'admin'` y
`status = 'approved'` de la organización dueña del local — no solo al
admin fundador. Un local puede tener más de un admin (la spec no lo
restringe), y no hay forma de distinguir "el encargado de este local en
particular" del resto de admins con el modelo de datos actual.

## Qué falta / qué no se pudo verificar sin acceso a internet desde este entorno

- **No se pudo confirmar la sintaxis de `netlify.toml` para el cron
  (`[functions."alertas-stock-email"]` + `schedule`) ni el header
  `x-nf-event: schedule` que usa `alertas-stock-email.js` para reconocer una
  invocación programada, contra la documentación oficial de Netlify vigente
  — este entorno no tiene salida a internet para chequearlo.** Verificar en
  el dashboard de Netlify después del primer deploy que el schedule haya
  quedado registrado (Site settings → Functions → `alertas-stock-email`), y
  que la función efectivamente corre sola sin necesitar `ALERTAS_STOCK_SECRET`.
- El riesgo si el chequeo del header no funciona y alguien encuentra la URL
  y la llama a mano es bajo: solo un digest de stock bajo mandado antes de
  tiempo, no expone datos nuevos ni hace nada destructivo.
- No probado en vivo end-to-end (no hay forma de mandar un email real desde
  este entorno). Falta: configurar `RESEND_API_KEY` (y `RESEND_FROM` con un
  dominio verificado, para poder mandarle a los admins reales y no solo al
  dueño de la cuenta de Resend) en Netlify, activar algún toggle de local en
  "Mis locales", y verificar que el email llega.
- Plantilla de email: por ahora HTML mínimo inline en cada función, sin
  diseño (logo, colores de marca). Es cosmético, no bloquea la
  funcionalidad — mismo criterio que ya se usó para las plantillas de
  Supabase Auth en `docs/auth-design.md`.
