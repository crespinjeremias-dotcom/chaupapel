-- Local = sucursal de una organizacion. Stock, proveedores, empleados y caja
-- son independientes entre locales de una misma organizacion (spec seccion 1).
create table locales (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  nombre text not null,
  modo_turno modo_turno_type not null default 'individual',
  alerta_stock_email boolean not null default false,
  alerta_cierre_caja_email boolean not null default false,
  activo boolean not null default true,
  created_at timestamptz not null default now()
);

create index idx_locales_organization on locales(organization_id);

comment on column locales.modo_turno is 'Configurable por el admin (seccion 2): individual = cada empleado abre su propio turno; compartida = una sola cuenta abierta todo el dia.';
