-- Cierre consolidado del dia para un local (seccion 10): agrega todos los
-- turnos de esa fecha. Es una foto persistida, no solo una vista calculada,
-- para que los reportes historicos no dependan de recalcular sobre turnos
-- que podrian mutar (ej. si un admin corrige algo despues).
create table cierres_diarios (
  id uuid primary key default gen_random_uuid(),
  local_id uuid not null references locales(id) on delete cascade,
  organization_id uuid not null references organizations(id) on delete cascade,
  fecha date not null,
  efectivo_esperado_total numeric not null default 0,
  efectivo_contado_total numeric not null default 0,
  transferencia_total numeric not null default 0,
  fiado_nuevo_total numeric not null default 0,
  diferencia_total numeric not null default 0,
  estado estado_turno_type not null default 'abierto',
  cerrado_por uuid references usuarios(id),
  cerrado_at timestamptz,
  created_at timestamptz not null default now(),
  unique (local_id, fecha)
);

create index idx_cierres_diarios_local on cierres_diarios(local_id, fecha);

-- Cierre mensual (seccion 9 y 10): incluye el gasto en mercaderia del mes
-- para dar una primera foto de ganancia bruta. Incluye costos de proveedores,
-- por eso su visibilidad se restringe a admin (informacion de margen).
create table cierres_mensuales (
  id uuid primary key default gen_random_uuid(),
  local_id uuid not null references locales(id) on delete cascade,
  organization_id uuid not null references organizations(id) on delete cascade,
  anio int not null,
  mes int not null check (mes between 1 and 12),
  total_vendido numeric not null default 0,
  total_cobrado numeric not null default 0,
  total_fiado_pendiente numeric not null default 0,
  total_gastos_mercaderia numeric not null default 0,
  ganancia_bruta numeric not null default 0,
  cerrado_por uuid references usuarios(id),
  cerrado_at timestamptz,
  created_at timestamptz not null default now(),
  unique (local_id, anio, mes)
);

create index idx_cierres_mensuales_local on cierres_mensuales(local_id, anio, mes);

alter table cierres_diarios enable row level security;
alter table cierres_mensuales enable row level security;

-- cierres_diarios: visible a todo el local (informacion operativa de caja,
-- no incluye margen ni costos de proveedores).
create policy cierres_diarios_select on cierres_diarios
  for select
  using (organization_id = current_org_id() and is_approved() and org_is_active()
         and (is_admin() or local_id = current_local_id()));

create policy cierres_diarios_insert on cierres_diarios
  for insert
  with check (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active());

create policy cierres_diarios_update on cierres_diarios
  for update
  using (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active())
  with check (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active());

-- cierres_mensuales: solo admin (incluye ganancia bruta / gasto en mercaderia).
create policy cierres_mensuales_select on cierres_mensuales
  for select
  using (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active());

create policy cierres_mensuales_insert on cierres_mensuales
  for insert
  with check (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active());

create policy cierres_mensuales_update on cierres_mensuales
  for update
  using (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active())
  with check (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active());
