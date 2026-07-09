-- Organizacion = cliente que se suscribe al SaaS. Todo el resto de las tablas
-- cuelga, directa o indirectamente, de organization_id (aislamiento multi-tenant).
create table organizations (
  id uuid primary key default gen_random_uuid(),
  nombre text not null,
  plan plan_type not null default 'basico',
  plan_overrides jsonb not null default '{}'::jsonb,  -- excepciones puntuales a las features del plan, si hicieran falta
  is_active boolean not null default true,             -- corte de acceso manual (seccion 16)
  trial_ends_at timestamptz,
  created_at timestamptz not null default now()
);

comment on column organizations.plan_overrides is 'Overrides puntuales de feature flags por organizacion, por fuera de lo que da el plan contratado. Vacio en el caso normal.';
comment on column organizations.is_active is 'Lo apaga el super-admin del SaaS (panel seccion 16) por falta de pago. No relacionado con el rol admin de la organizacion.';
