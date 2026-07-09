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
│   └── rls-design.md        Estrategia de aislamiento multi-tenant (RLS)
├── supabase/
│   └── migrations/          Migraciones SQL, en orden de dependencia
├── public/                  Frontend (PWA)
└── netlify/
    └── functions/           Funciones serverless (emails, operaciones con service role key)
```

## Estado del proyecto

**Fase 1 completa**: modelo de datos, RLS y estructura de carpetas. Ver `docs/modelo-datos.md` y `docs/rls-design.md`.

## Aplicar las migraciones

Con el [Supabase CLI](https://supabase.com/docs/guides/cli):

```
supabase link --project-ref <project-ref>
supabase db push
```

Las migraciones están numeradas por timestamp y deben aplicarse en orden (así las lee `supabase db push` por default).
