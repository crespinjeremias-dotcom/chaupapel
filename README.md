# chaupapel — Sistema de gestión para almacenes (SaaS multi-tenant)

Sistema de gestión de stock, ventas y caja para locales tipo almacén/kiosco de barrio. Ver `spec.md` para la especificación funcional completa (19 secciones).

## Stack

- **Frontend**: HTML + CSS + JavaScript plano, sin frameworks, organizado en módulos por función.
- **Backend**: Supabase (Postgres + Auth + Row Level Security para el aislamiento multi-tenant).
- **Hosting**: Netlify, con Netlify Functions para envío de emails.
- **Instalación**: PWA (manifest.json + service worker).

## Estructura de carpetas

```
chaupapel/
├── spec.md                  Especificación funcional completa
├── docs/                    Documentación de diseño técnico
│   ├── modelo-datos.md      Tablas, columnas, relaciones y por qué de cada una
│   ├── rls-design.md        Estrategia de aislamiento multi-tenant (RLS)
│   └── auth-design.md       Decisiones del flujo de autenticación (Fase 2)
├── supabase/
│   └── migrations/          Migraciones SQL, en orden de dependencia
├── public/                  Frontend (PWA)
└── netlify/
    └── functions/           Funciones serverless (emails, operaciones con service role key)
```

## Estado del proyecto

- **Fase 1 completa**: modelo de datos, RLS y estructura de carpetas.
- **Fase 2 completa**: Auth (login, registro de organización, invitación/aprobación de empleados, recuperación de contraseña, sesión única por dispositivo). Ver `docs/auth-design.md`.

Proyecto de Supabase en uso: `chaupapel` (ref `mptcnzpgztbiespxpbnp`), ya linkeado.

## Aplicar las migraciones

Con el [Supabase CLI](https://supabase.com/docs/guides/cli):

```
supabase link --project-ref mptcnzpgztbiespxpbnp
supabase db push
```

Las migraciones están numeradas por timestamp y deben aplicarse en orden (así las lee `supabase db push` por default). El `supabase/config.toml` (auth: confirmación de email desactivada, `site_url`/redirect URLs) se sincroniza con `supabase config push`.

## Probar el frontend localmente

```
python -m http.server 8888 --directory public
```

y abrir `http://localhost:8888`. `public/js/supabaseClient.js` ya tiene la URL y la anon key del proyecto (la anon key es pública por diseño, la protección real es RLS — la `service_role` key nunca va acá).
