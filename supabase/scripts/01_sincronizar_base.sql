-- SINCRONIZAR BASE: lleva la base al estado que espera el codigo, aplicando SOLO las
-- migraciones de supabase/migrations/ que todavia no estan reflejadas (cada una se detecta
-- con un "marcador": existe tal tabla / columna / funcion / policy), en orden, y anota
-- cada una en supabase_migrations.schema_migrations (la tabla que usa el CLI de Supabase).
--
-- Es idempotente: se puede correr las veces que haga falta; lo que ya esta se saltea.
-- Corre todo como una sola consulta: si algo falla, no queda nada a medias (pegame el error).
-- El resultado final (ultima tabla) dice que se aplico ahora y que ya estaba.
--
-- Supone que la base esta en un estado "prefijo" de la lista de migraciones (se aplicaron
-- en orden hasta cierto punto). Corre primero 00_diagnostico_migraciones.sql: si ves
-- migraciones "FALTA" entre otras ya aplicadas (huecos), avisame antes de correr esto.

create schema if not exists supabase_migrations;
create table if not exists supabase_migrations.schema_migrations (
  version text not null primary key,
  statements text[],
  name text
);

create temp table if not exists _mig_log (version text, nombre text, accion text);
truncate _mig_log;

-- ======================================================================
-- 20260709120000 extensions_types
-- ======================================================================
do $mig$
begin
  if not (to_regtype('public.estado_reclamo_type') is not null) then
    execute $mig_body$
create extension if not exists "pgcrypto";   -- gen_random_uuid()
create extension if not exists "pg_trgm";    -- busqueda por nombre (autocompletado productos/clientes)

create type plan_type as enum ('basico', 'medio', 'completo');
create type modo_turno_type as enum ('individual', 'compartida');
create type user_role_type as enum ('admin', 'empleado');
create type user_status_type as enum ('pending', 'approved', 'rejected');
create type motivo_ajuste_type as enum ('rotura', 'vencido', 'robo', 'error_conteo', 'otro');
create type estado_turno_type as enum ('abierto', 'cerrado');
create type estado_venta_type as enum ('activa', 'editada', 'anulada');
create type metodo_pago_type as enum ('efectivo', 'transferencia');
create type tipo_movimiento_cc_type as enum ('fiado_nuevo', 'cobro_fiado', 'saldo_favor_generado', 'saldo_favor_usado');
create type tipo_devolucion_type as enum ('devolucion', 'cambio');
create type resolucion_cambio_type as enum ('resuelto_ahora', 'saldo_pendiente');
create type estado_reclamo_type as enum ('pendiente', 'repuesto');
    $mig_body$;
    insert into _mig_log values ('20260709120000', 'extensions_types', 'aplicada ahora');
  else
    insert into _mig_log values ('20260709120000', 'extensions_types', 'ya estaba');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260709120000', 'extensions_types') on conflict (version) do nothing;

-- ======================================================================
-- 20260709120100 organizations
-- ======================================================================
do $mig$
begin
  if not (to_regclass('public.organizations') is not null) then
    execute $mig_body$
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
    $mig_body$;
    insert into _mig_log values ('20260709120100', 'organizations', 'aplicada ahora');
  else
    insert into _mig_log values ('20260709120100', 'organizations', 'ya estaba');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260709120100', 'organizations') on conflict (version) do nothing;

-- ======================================================================
-- 20260709120200 locales
-- ======================================================================
do $mig$
begin
  if not (to_regclass('public.locales') is not null) then
    execute $mig_body$
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
    $mig_body$;
    insert into _mig_log values ('20260709120200', 'locales', 'aplicada ahora');
  else
    insert into _mig_log values ('20260709120200', 'locales', 'ya estaba');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260709120200', 'locales') on conflict (version) do nothing;

-- ======================================================================
-- 20260709120300 usuarios
-- ======================================================================
do $mig$
begin
  if not (to_regclass('public.usuarios') is not null) then
    execute $mig_body$
create table usuarios (
  id uuid primary key references auth.users(id) on delete cascade,
  organization_id uuid not null references organizations(id) on delete cascade,
  local_id uuid references locales(id) on delete set null,
  role user_role_type not null default 'empleado',
  status user_status_type not null default 'pending',
  nombre text not null,
  email text,
  telefono text,
  current_session_id uuid,      -- session_id del JWT activo, para forzar sesion unica por dispositivo
  last_login_at timestamptz,
  created_at timestamptz not null default now()
);

create index idx_usuarios_organization on usuarios(organization_id);
create index idx_usuarios_local on usuarios(local_id);

comment on column usuarios.local_id is 'Null para admin (ve todos los locales de su organizacion). Obligatorio en la practica para empleado.';
comment on column usuarios.status is 'pending = esperando aprobacion del admin tras registrarse con codigo de invitacion. El admin de una organizacion nueva se crea directamente en approved.';
comment on column usuarios.current_session_id is 'Usado por el flujo de "sesion unica por dispositivo" (seccion 3): al loguear se compara/reemplaza contra la sesion activa anterior.';
    $mig_body$;
    insert into _mig_log values ('20260709120300', 'usuarios', 'aplicada ahora');
  else
    insert into _mig_log values ('20260709120300', 'usuarios', 'ya estaba');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260709120300', 'usuarios') on conflict (version) do nothing;

-- ======================================================================
-- 20260709120400 auth_helpers
-- ======================================================================
do $mig$
begin
  if not (exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace where ns.nspname = 'public' and p.proname = 'org_is_active')) then
    execute $mig_body$
create or replace function public.current_org_id()
returns uuid
language sql
security definer
stable
set search_path = public
as $$
  select organization_id from usuarios where id = auth.uid();
$$;

create or replace function public.current_local_id()
returns uuid
language sql
security definer
stable
set search_path = public
as $$
  select local_id from usuarios where id = auth.uid();
$$;

create or replace function public.current_role()
returns user_role_type
language sql
security definer
stable
set search_path = public
as $$
  select role from usuarios where id = auth.uid();
$$;

create or replace function public.is_admin()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select coalesce((select role = 'admin' from usuarios where id = auth.uid()), false);
$$;

create or replace function public.is_approved()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select coalesce((select status = 'approved' from usuarios where id = auth.uid()), false);
$$;

create or replace function public.org_is_active()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select coalesce(
    (select o.is_active from organizations o where o.id = (select organization_id from usuarios where id = auth.uid())),
    false
  );
$$;

comment on function public.current_org_id() is 'Organizacion del usuario autenticado actual, segun su fila en usuarios.';
comment on function public.is_approved() is 'true solo si el usuario ya paso la aprobacion del admin (no aplica a la fila propia en usuarios, que siempre debe ser visible para poder consultar el estado pending).';
    $mig_body$;
    insert into _mig_log values ('20260709120400', 'auth_helpers', 'aplicada ahora');
  else
    insert into _mig_log values ('20260709120400', 'auth_helpers', 'ya estaba');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260709120400', 'auth_helpers') on conflict (version) do nothing;

-- ======================================================================
-- 20260709120500 rls_core
-- ======================================================================
do $mig$
begin
  if not (exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'locales' and policyname = 'locales_select')) then
    execute $mig_body$
alter table organizations enable row level security;
alter table locales enable row level security;
alter table usuarios enable row level security;

create policy organizations_select on organizations
  for select
  using (id = current_org_id());

create policy organizations_insert on organizations
  for insert
  with check (auth.uid() is not null);

create policy organizations_update on organizations
  for update
  using (id = current_org_id() and is_admin())
  with check (id = current_org_id() and is_admin());

create policy locales_select on locales
  for select
  using (organization_id = current_org_id() and is_approved());

create policy locales_insert on locales
  for insert
  with check (organization_id = current_org_id() and is_admin() and is_approved());

create policy locales_update on locales
  for update
  using (organization_id = current_org_id() and is_admin() and is_approved())
  with check (organization_id = current_org_id() and is_admin() and is_approved());

create policy usuarios_select on usuarios
  for select
  using (id = auth.uid() or (organization_id = current_org_id() and is_admin()));

create policy usuarios_update_self on usuarios
  for update
  using (id = auth.uid())
  with check (id = auth.uid());

create policy usuarios_update_admin on usuarios
  for update
  using (organization_id = current_org_id() and is_admin())
  with check (organization_id = current_org_id() and is_admin());

create or replace function public.prevent_privilege_escalation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if is_admin() then
    return new;
  end if;

  if new.role is distinct from old.role
     or new.status is distinct from old.status
     or new.organization_id is distinct from old.organization_id
     or new.local_id is distinct from old.local_id then
    raise exception 'No autorizado para modificar role, status, organization_id o local_id';
  end if;

  return new;
end;
$$;

create trigger trg_prevent_privilege_escalation
  before update on usuarios
  for each row
  execute function public.prevent_privilege_escalation();
    $mig_body$;
    insert into _mig_log values ('20260709120500', 'rls_core', 'aplicada ahora');
  else
    insert into _mig_log values ('20260709120500', 'rls_core', 'ya estaba');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260709120500', 'rls_core') on conflict (version) do nothing;

-- ======================================================================
-- 20260709120600 invitaciones
-- ======================================================================
do $mig$
begin
  if not (to_regclass('public.invitaciones') is not null) then
    execute $mig_body$
create table invitaciones (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  local_id uuid references locales(id) on delete cascade,
  codigo text not null unique,
  creado_por uuid not null references usuarios(id),
  usado_por uuid references usuarios(id),
  usado_at timestamptz,
  expira_at timestamptz,
  created_at timestamptz not null default now()
);

create index idx_invitaciones_organization on invitaciones(organization_id);

alter table invitaciones enable row level security;

create policy invitaciones_select on invitaciones
  for select
  using (organization_id = current_org_id() and is_approved());

create policy invitaciones_insert on invitaciones
  for insert
  with check (organization_id = current_org_id() and is_admin() and is_approved());

create policy invitaciones_update on invitaciones
  for update
  using (organization_id = current_org_id() and is_admin() and is_approved())
  with check (organization_id = current_org_id() and is_admin() and is_approved());

create policy invitaciones_delete on invitaciones
  for delete
  using (organization_id = current_org_id() and is_admin() and is_approved());

comment on table invitaciones is 'La validacion del codigo por parte de un empleado sin sesion "de organizacion" todavia se hace via una funcion security definer (redimir_invitacion, a implementar en Fase 2), no via estas policies.';
    $mig_body$;
    insert into _mig_log values ('20260709120600', 'invitaciones', 'aplicada ahora');
  else
    insert into _mig_log values ('20260709120600', 'invitaciones', 'ya estaba');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260709120600', 'invitaciones') on conflict (version) do nothing;

-- ======================================================================
-- 20260709120700 categorias_productos
-- ======================================================================
do $mig$
begin
  if not (to_regclass('public.productos') is not null) then
    execute $mig_body$
create table categorias (
  id uuid primary key default gen_random_uuid(),
  local_id uuid not null references locales(id) on delete cascade,
  organization_id uuid not null references organizations(id) on delete cascade,
  nombre text not null,
  created_at timestamptz not null default now(),
  unique (local_id, nombre)
);

create table productos (
  id uuid primary key default gen_random_uuid(),
  local_id uuid not null references locales(id) on delete cascade,
  organization_id uuid not null references organizations(id) on delete cascade,
  categoria_id uuid references categorias(id) on delete set null,
  nombre text not null,
  presentacion text,
  unidad_medida text,
  perecedero boolean not null default false,
  fecha_vencimiento date,
  alerta_vencimiento_dias int,
  stock_actual numeric not null default 0,
  stock_minimo numeric not null default 0,
  precio_venta_actual numeric not null default 0 check (precio_venta_actual >= 0),
  ultimo_precio_costo numeric,
  codigo_barras text,
  activo boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_productos_local on productos(local_id);
create index idx_productos_categoria on productos(categoria_id);
create unique index idx_productos_codigo_barras on productos(local_id, codigo_barras) where codigo_barras is not null;
create index idx_productos_nombre_trgm on productos using gin (nombre gin_trgm_ops);

comment on column productos.ultimo_precio_costo is 'Se completa solo con el precio_costo de la ultima reposicion de stock (trigger en reposiciones_stock). Dato de referencia rapida, no reemplaza el historial de compras.';
comment on column productos.stock_actual is 'Mantenido por triggers de reposiciones_stock, ajustes_stock y venta_items. No se escribe a mano desde el front salvo a traves de esas tablas.';

alter table categorias enable row level security;
alter table productos enable row level security;

create policy categorias_select on categorias
  for select
  using (organization_id = current_org_id() and is_approved() and org_is_active()
         and (is_admin() or local_id = current_local_id()));

create policy categorias_insert on categorias
  for insert
  with check (organization_id = current_org_id() and is_approved() and org_is_active()
              and (is_admin() or local_id = current_local_id()));

create policy categorias_update on categorias
  for update
  using (organization_id = current_org_id() and is_approved() and org_is_active()
         and (is_admin() or local_id = current_local_id()))
  with check (organization_id = current_org_id() and is_approved() and org_is_active()
              and (is_admin() or local_id = current_local_id()));

create policy categorias_delete on categorias
  for delete
  using (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active());

create policy productos_select on productos
  for select
  using (organization_id = current_org_id() and is_approved() and org_is_active()
         and (is_admin() or local_id = current_local_id()));

create policy productos_insert on productos
  for insert
  with check (organization_id = current_org_id() and is_approved() and org_is_active()
              and (is_admin() or local_id = current_local_id()));

create policy productos_update on productos
  for update
  using (organization_id = current_org_id() and is_approved() and org_is_active()
         and (is_admin() or local_id = current_local_id()))
  with check (organization_id = current_org_id() and is_approved() and org_is_active()
              and (is_admin() or local_id = current_local_id()));
    $mig_body$;
    insert into _mig_log values ('20260709120700', 'categorias_productos', 'aplicada ahora');
  else
    insert into _mig_log values ('20260709120700', 'categorias_productos', 'ya estaba');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260709120700', 'categorias_productos') on conflict (version) do nothing;

-- ======================================================================
-- 20260709120800 historial_precios_venta
-- ======================================================================
do $mig$
begin
  if not (to_regclass('public.historial_precios_venta') is not null) then
    execute $mig_body$
create table historial_precios_venta (
  id uuid primary key default gen_random_uuid(),
  producto_id uuid not null references productos(id) on delete cascade,
  local_id uuid not null references locales(id) on delete cascade,
  organization_id uuid not null references organizations(id) on delete cascade,
  precio numeric not null check (precio >= 0),
  vigente_desde timestamptz not null default now(),
  vigente_hasta timestamptz,
  created_at timestamptz not null default now()
);

create index idx_historial_precios_producto on historial_precios_venta(producto_id);

alter table historial_precios_venta enable row level security;

create policy historial_precios_select on historial_precios_venta
  for select
  using (organization_id = current_org_id() and is_approved() and org_is_active()
         and (is_admin() or local_id = current_local_id()));

create or replace function public.registrar_historial_precio()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    insert into historial_precios_venta (producto_id, local_id, organization_id, precio, vigente_desde)
    values (new.id, new.local_id, new.organization_id, new.precio_venta_actual, now());
    return new;
  end if;

  if new.precio_venta_actual is distinct from old.precio_venta_actual then
    update historial_precios_venta
      set vigente_hasta = now()
      where producto_id = new.id and vigente_hasta is null;

    insert into historial_precios_venta (producto_id, local_id, organization_id, precio, vigente_desde)
    values (new.id, new.local_id, new.organization_id, new.precio_venta_actual, now());
  end if;

  return new;
end;
$$;

create trigger trg_registrar_historial_precio_insert
  after insert on productos
  for each row
  execute function public.registrar_historial_precio();

create trigger trg_registrar_historial_precio_update
  after update on productos
  for each row
  execute function public.registrar_historial_precio();
    $mig_body$;
    insert into _mig_log values ('20260709120800', 'historial_precios_venta', 'aplicada ahora');
  else
    insert into _mig_log values ('20260709120800', 'historial_precios_venta', 'ya estaba');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260709120800', 'historial_precios_venta') on conflict (version) do nothing;

-- ======================================================================
-- 20260709120900 proveedores
-- ======================================================================
do $mig$
begin
  if not (to_regclass('public.producto_proveedor') is not null) then
    execute $mig_body$
create table proveedores (
  id uuid primary key default gen_random_uuid(),
  local_id uuid not null references locales(id) on delete cascade,
  organization_id uuid not null references organizations(id) on delete cascade,
  nombre text not null,
  telefono text,
  email text,
  direccion text,
  notas text,
  activo boolean not null default true,
  created_at timestamptz not null default now()
);

create index idx_proveedores_local on proveedores(local_id);

create table producto_proveedor (
  id uuid primary key default gen_random_uuid(),
  producto_id uuid not null references productos(id) on delete cascade,
  proveedor_id uuid not null references proveedores(id) on delete cascade,
  local_id uuid not null references locales(id) on delete cascade,
  organization_id uuid not null references organizations(id) on delete cascade,
  precio_referencia numeric,
  created_at timestamptz not null default now(),
  unique (producto_id, proveedor_id)
);

create index idx_producto_proveedor_producto on producto_proveedor(producto_id);
create index idx_producto_proveedor_proveedor on producto_proveedor(proveedor_id);

alter table proveedores enable row level security;
alter table producto_proveedor enable row level security;

create policy proveedores_select on proveedores
  for select
  using (organization_id = current_org_id() and is_approved() and org_is_active()
         and (is_admin() or local_id = current_local_id()));

create policy proveedores_insert on proveedores
  for insert
  with check (organization_id = current_org_id() and is_approved() and org_is_active()
              and (is_admin() or local_id = current_local_id()));

create policy proveedores_update on proveedores
  for update
  using (organization_id = current_org_id() and is_approved() and org_is_active()
         and (is_admin() or local_id = current_local_id()))
  with check (organization_id = current_org_id() and is_approved() and org_is_active()
              and (is_admin() or local_id = current_local_id()));

create policy producto_proveedor_select on producto_proveedor
  for select
  using (organization_id = current_org_id() and is_approved() and org_is_active()
         and (is_admin() or local_id = current_local_id()));

create policy producto_proveedor_insert on producto_proveedor
  for insert
  with check (organization_id = current_org_id() and is_approved() and org_is_active()
              and (is_admin() or local_id = current_local_id()));

create policy producto_proveedor_delete on producto_proveedor
  for delete
  using (organization_id = current_org_id() and is_approved() and org_is_active()
         and (is_admin() or local_id = current_local_id()));
    $mig_body$;
    insert into _mig_log values ('20260709120900', 'proveedores', 'aplicada ahora');
  else
    insert into _mig_log values ('20260709120900', 'proveedores', 'ya estaba');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260709120900', 'proveedores') on conflict (version) do nothing;

-- ======================================================================
-- 20260709121000 stock_movimientos
-- ======================================================================
do $mig$
begin
  if not (to_regclass('public.ajustes_stock') is not null) then
    execute $mig_body$
create table reposiciones_stock (
  id uuid primary key default gen_random_uuid(),
  producto_id uuid not null references productos(id),
  proveedor_id uuid not null references proveedores(id),
  local_id uuid not null references locales(id) on delete cascade,
  organization_id uuid not null references organizations(id) on delete cascade,
  cantidad numeric not null check (cantidad > 0),
  precio_costo numeric not null check (precio_costo >= 0),
  usuario_id uuid not null references usuarios(id),
  fecha timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create index idx_reposiciones_producto on reposiciones_stock(producto_id);
create index idx_reposiciones_proveedor on reposiciones_stock(proveedor_id);
create index idx_reposiciones_local_fecha on reposiciones_stock(local_id, fecha);

create table ajustes_stock (
  id uuid primary key default gen_random_uuid(),
  producto_id uuid not null references productos(id),
  local_id uuid not null references locales(id) on delete cascade,
  organization_id uuid not null references organizations(id) on delete cascade,
  cantidad numeric not null check (cantidad <> 0),
  motivo motivo_ajuste_type not null,
  comentario text,
  usuario_id uuid not null references usuarios(id),
  created_at timestamptz not null default now(),
  check (motivo <> 'otro' or comentario is not null)
);

create index idx_ajustes_producto on ajustes_stock(producto_id);
create index idx_ajustes_local on ajustes_stock(local_id);

alter table reposiciones_stock enable row level security;
alter table ajustes_stock enable row level security;

create policy reposiciones_select on reposiciones_stock
  for select
  using (organization_id = current_org_id() and is_approved() and org_is_active()
         and (is_admin() or local_id = current_local_id()));

create policy reposiciones_insert on reposiciones_stock
  for insert
  with check (organization_id = current_org_id() and is_approved() and org_is_active()
              and (is_admin() or local_id = current_local_id()));

create policy ajustes_select on ajustes_stock
  for select
  using (organization_id = current_org_id() and is_approved() and org_is_active()
         and (is_admin() or local_id = current_local_id()));

create policy ajustes_insert on ajustes_stock
  for insert
  with check (organization_id = current_org_id() and is_approved() and org_is_active()
              and (is_admin() or local_id = current_local_id()));

create or replace function public.aplicar_reposicion_stock()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update productos
    set stock_actual = stock_actual + new.cantidad,
        ultimo_precio_costo = new.precio_costo,
        updated_at = now()
    where id = new.producto_id;
  return new;
end;
$$;

create trigger trg_aplicar_reposicion_stock
  after insert on reposiciones_stock
  for each row
  execute function public.aplicar_reposicion_stock();

create or replace function public.aplicar_ajuste_stock()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update productos
    set stock_actual = stock_actual + new.cantidad,
        updated_at = now()
    where id = new.producto_id;
  return new;
end;
$$;

create trigger trg_aplicar_ajuste_stock
  after insert on ajustes_stock
  for each row
  execute function public.aplicar_ajuste_stock();
    $mig_body$;
    insert into _mig_log values ('20260709121000', 'stock_movimientos', 'aplicada ahora');
  else
    insert into _mig_log values ('20260709121000', 'stock_movimientos', 'ya estaba');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260709121000', 'stock_movimientos') on conflict (version) do nothing;

-- ======================================================================
-- 20260709121100 turnos
-- ======================================================================
do $mig$
begin
  if not (to_regclass('public.turnos') is not null) then
    execute $mig_body$
create table turnos (
  id uuid primary key default gen_random_uuid(),
  local_id uuid not null references locales(id) on delete cascade,
  organization_id uuid not null references organizations(id) on delete cascade,
  usuario_id uuid not null references usuarios(id),
  fecha_apertura timestamptz not null default now(),
  fecha_cierre timestamptz,
  estado estado_turno_type not null default 'abierto',
  efectivo_esperado numeric,
  efectivo_contado numeric,
  transferencia_esperada numeric,
  diferencia numeric,
  created_at timestamptz not null default now()
);

create index idx_turnos_local_fecha on turnos(local_id, fecha_apertura);
create index idx_turnos_usuario on turnos(usuario_id);

alter table turnos enable row level security;

create policy turnos_select on turnos
  for select
  using (organization_id = current_org_id() and is_approved() and org_is_active()
         and (is_admin() or (local_id = current_local_id() and usuario_id = auth.uid())));

create policy turnos_insert on turnos
  for insert
  with check (organization_id = current_org_id() and is_approved() and org_is_active()
              and usuario_id = auth.uid()
              and (is_admin() or local_id = current_local_id()));

create policy turnos_update on turnos
  for update
  using (organization_id = current_org_id() and is_approved() and org_is_active()
         and (is_admin() or (local_id = current_local_id() and usuario_id = auth.uid())))
  with check (organization_id = current_org_id() and is_approved() and org_is_active()
              and (is_admin() or (local_id = current_local_id() and usuario_id = auth.uid())));

comment on table turnos is 'La consolidacion "caja diaria del local" (seccion 10) se calcula agregando turnos por local_id+fecha, no es una fila propia; ver cierres_diarios para el cierre consolidado persistido.';
    $mig_body$;
    insert into _mig_log values ('20260709121100', 'turnos', 'aplicada ahora');
  else
    insert into _mig_log values ('20260709121100', 'turnos', 'ya estaba');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260709121100', 'turnos') on conflict (version) do nothing;

-- ======================================================================
-- 20260709121200 clientes
-- ======================================================================
do $mig$
begin
  if not (to_regclass('public.clientes') is not null) then
    execute $mig_body$
create table clientes (
  id uuid primary key default gen_random_uuid(),
  local_id uuid not null references locales(id) on delete cascade,
  organization_id uuid not null references organizations(id) on delete cascade,
  nombre text not null,
  telefono text,
  saldo numeric not null default 0,
  activo boolean not null default true,
  created_at timestamptz not null default now()
);

create index idx_clientes_local on clientes(local_id);
create index idx_clientes_nombre_trgm on clientes using gin (nombre gin_trgm_ops);

alter table clientes enable row level security;

create policy clientes_select on clientes
  for select
  using (organization_id = current_org_id() and is_approved() and org_is_active()
         and (is_admin() or local_id = current_local_id()));

create policy clientes_insert on clientes
  for insert
  with check (organization_id = current_org_id() and is_approved() and org_is_active()
              and (is_admin() or local_id = current_local_id()));

create policy clientes_update on clientes
  for update
  using (organization_id = current_org_id() and is_approved() and org_is_active()
         and (is_admin() or local_id = current_local_id()))
  with check (organization_id = current_org_id() and is_approved() and org_is_active()
              and (is_admin() or local_id = current_local_id()));

comment on column clientes.saldo is 'Cache mantenido por el trigger de cuenta_corriente_movimientos. La fuente de verdad es la suma de esos movimientos.';
    $mig_body$;
    insert into _mig_log values ('20260709121200', 'clientes', 'aplicada ahora');
  else
    insert into _mig_log values ('20260709121200', 'clientes', 'ya estaba');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260709121200', 'clientes') on conflict (version) do nothing;

-- ======================================================================
-- 20260709121300 ventas
-- ======================================================================
do $mig$
begin
  if not (to_regclass('public.venta_pagos') is not null) then
    execute $mig_body$
create table ventas (
  id uuid primary key default gen_random_uuid(),
  local_id uuid not null references locales(id) on delete cascade,
  organization_id uuid not null references organizations(id) on delete cascade,
  turno_id uuid not null references turnos(id),
  usuario_id uuid not null references usuarios(id),
  cliente_id uuid references clientes(id),
  es_fiado boolean not null default false,
  estado estado_venta_type not null default 'activa',
  total numeric not null default 0 check (total >= 0),
  fecha timestamptz not null default now(),
  anulada_por uuid references usuarios(id),
  anulada_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (not es_fiado or cliente_id is not null)
);

create index idx_ventas_local_fecha on ventas(local_id, fecha);
create index idx_ventas_turno on ventas(turno_id);
create index idx_ventas_cliente on ventas(cliente_id);

create table venta_items (
  id uuid primary key default gen_random_uuid(),
  venta_id uuid not null references ventas(id) on delete cascade,
  producto_id uuid not null references productos(id),
  local_id uuid not null references locales(id) on delete cascade,
  organization_id uuid not null references organizations(id) on delete cascade,
  cantidad numeric not null check (cantidad > 0),
  precio_unitario numeric not null check (precio_unitario >= 0),
  subtotal numeric generated always as (cantidad * precio_unitario) stored,
  created_at timestamptz not null default now()
);

create index idx_venta_items_venta on venta_items(venta_id);
create index idx_venta_items_producto on venta_items(producto_id);

create table venta_pagos (
  id uuid primary key default gen_random_uuid(),
  venta_id uuid not null references ventas(id) on delete cascade,
  local_id uuid not null references locales(id) on delete cascade,
  organization_id uuid not null references organizations(id) on delete cascade,
  metodo metodo_pago_type not null,
  monto numeric not null check (monto > 0),
  created_at timestamptz not null default now()
);

create index idx_venta_pagos_venta on venta_pagos(venta_id);

alter table ventas enable row level security;
alter table venta_items enable row level security;
alter table venta_pagos enable row level security;

create policy ventas_select on ventas
  for select
  using (organization_id = current_org_id() and is_approved() and org_is_active()
         and (is_admin() or local_id = current_local_id()));

create policy ventas_insert on ventas
  for insert
  with check (organization_id = current_org_id() and is_approved() and org_is_active()
              and usuario_id = auth.uid()
              and (is_admin() or local_id = current_local_id()));

create policy ventas_update on ventas
  for update
  using (organization_id = current_org_id() and is_approved() and org_is_active()
         and (is_admin()
              or (local_id = current_local_id()
                  and usuario_id = auth.uid()
                  and created_at > now() - interval '15 minutes')))
  with check (organization_id = current_org_id() and is_approved() and org_is_active()
              and (is_admin() or local_id = current_local_id()));

create policy venta_items_select on venta_items
  for select
  using (organization_id = current_org_id() and is_approved() and org_is_active()
         and (is_admin() or local_id = current_local_id()));

create policy venta_items_insert on venta_items
  for insert
  with check (organization_id = current_org_id() and is_approved() and org_is_active()
              and (is_admin() or local_id = current_local_id()));

create policy venta_items_update on venta_items
  for update
  using (organization_id = current_org_id() and is_approved() and org_is_active()
         and (is_admin() or (
           local_id = current_local_id()
           and exists (
             select 1 from ventas v
             where v.id = venta_items.venta_id
               and v.usuario_id = auth.uid()
               and v.created_at > now() - interval '15 minutes'
           )
         )))
  with check (organization_id = current_org_id() and is_approved() and org_is_active()
              and (is_admin() or local_id = current_local_id()));

create policy venta_items_delete on venta_items
  for delete
  using (organization_id = current_org_id() and is_approved() and org_is_active()
         and (is_admin() or (
           local_id = current_local_id()
           and exists (
             select 1 from ventas v
             where v.id = venta_items.venta_id
               and v.usuario_id = auth.uid()
               and v.created_at > now() - interval '15 minutes'
           )
         )));

create policy venta_pagos_select on venta_pagos
  for select
  using (organization_id = current_org_id() and is_approved() and org_is_active()
         and (is_admin() or local_id = current_local_id()));

create policy venta_pagos_insert on venta_pagos
  for insert
  with check (organization_id = current_org_id() and is_approved() and org_is_active()
              and (is_admin() or local_id = current_local_id()));

create policy venta_pagos_delete on venta_pagos
  for delete
  using (organization_id = current_org_id() and is_approved() and org_is_active()
         and (is_admin() or (
           local_id = current_local_id()
           and exists (
             select 1 from ventas v
             where v.id = venta_pagos.venta_id
               and v.usuario_id = auth.uid()
               and v.created_at > now() - interval '15 minutes'
           )
         )));

create or replace function public.aplicar_stock_venta_item()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    update productos set stock_actual = stock_actual - new.cantidad, updated_at = now()
      where id = new.producto_id;
    return new;
  elsif tg_op = 'UPDATE' then
    update productos set stock_actual = stock_actual + old.cantidad - new.cantidad, updated_at = now()
      where id = new.producto_id;
    return new;
  elsif tg_op = 'DELETE' then
    update productos set stock_actual = stock_actual + old.cantidad, updated_at = now()
      where id = old.producto_id;
    return old;
  end if;
  return null;
end;
$$;

create trigger trg_aplicar_stock_venta_item
  after insert or update of cantidad or delete on venta_items
  for each row
  execute function public.aplicar_stock_venta_item();

create or replace function public.aplicar_anulacion_venta()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.estado = 'anulada' and old.estado is distinct from 'anulada' then
    update productos p
      set stock_actual = p.stock_actual + vi.total_cantidad,
          updated_at = now()
      from (
        select producto_id, sum(cantidad) as total_cantidad
        from venta_items
        where venta_id = new.id
        group by producto_id
      ) vi
      where vi.producto_id = p.id;
  end if;
  return new;
end;
$$;

create trigger trg_aplicar_anulacion_venta
  after update of estado on ventas
  for each row
  execute function public.aplicar_anulacion_venta();
    $mig_body$;
    insert into _mig_log values ('20260709121300', 'ventas', 'aplicada ahora');
  else
    insert into _mig_log values ('20260709121300', 'ventas', 'ya estaba');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260709121300', 'ventas') on conflict (version) do nothing;

-- ======================================================================
-- 20260709121400 cuenta_corriente_movimientos
-- ======================================================================
do $mig$
begin
  if not (to_regclass('public.cuenta_corriente_movimientos') is not null) then
    execute $mig_body$
create table cuenta_corriente_movimientos (
  id uuid primary key default gen_random_uuid(),
  cliente_id uuid not null references clientes(id) on delete cascade,
  local_id uuid not null references locales(id) on delete cascade,
  organization_id uuid not null references organizations(id) on delete cascade,
  tipo tipo_movimiento_cc_type not null,
  monto numeric not null check (monto > 0),
  venta_id uuid references ventas(id),
  turno_id uuid references turnos(id),   -- turno en el que se cobro, para que compute en la caja de ese dia
  metodo_pago metodo_pago_type,          -- solo aplica a cobro_fiado
  usuario_id uuid not null references usuarios(id),
  fecha timestamptz not null default now(),
  created_at timestamptz not null default now(),
  check (tipo <> 'cobro_fiado' or (metodo_pago is not null and turno_id is not null))
);

create index idx_cc_movimientos_cliente on cuenta_corriente_movimientos(cliente_id);
create index idx_cc_movimientos_local_fecha on cuenta_corriente_movimientos(local_id, fecha);

alter table cuenta_corriente_movimientos enable row level security;

create policy cc_movimientos_select on cuenta_corriente_movimientos
  for select
  using (organization_id = current_org_id() and is_approved() and org_is_active()
         and (is_admin() or local_id = current_local_id()));

create policy cc_movimientos_insert on cuenta_corriente_movimientos
  for insert
  with check (organization_id = current_org_id() and is_approved() and org_is_active()
              and (is_admin() or local_id = current_local_id()));

create or replace function public.aplicar_movimiento_cuenta_corriente()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  delta numeric;
begin
  delta := case new.tipo
    when 'fiado_nuevo' then new.monto
    when 'cobro_fiado' then -new.monto
    when 'saldo_favor_generado' then -new.monto
    when 'saldo_favor_usado' then new.monto
  end;

  update clientes set saldo = saldo + delta where id = new.cliente_id;
  return new;
end;
$$;

create trigger trg_aplicar_movimiento_cuenta_corriente
  after insert on cuenta_corriente_movimientos
  for each row
  execute function public.aplicar_movimiento_cuenta_corriente();
    $mig_body$;
    insert into _mig_log values ('20260709121400', 'cuenta_corriente_movimientos', 'aplicada ahora');
  else
    insert into _mig_log values ('20260709121400', 'cuenta_corriente_movimientos', 'ya estaba');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260709121400', 'cuenta_corriente_movimientos') on conflict (version) do nothing;

-- ======================================================================
-- 20260709121500 devoluciones_reclamos
-- ======================================================================
do $mig$
begin
  if not (to_regclass('public.reclamos_proveedor') is not null) then
    execute $mig_body$
create table devoluciones_cambios (
  id uuid primary key default gen_random_uuid(),
  venta_id uuid not null references ventas(id),
  local_id uuid not null references locales(id) on delete cascade,
  organization_id uuid not null references organizations(id) on delete cascade,
  tipo tipo_devolucion_type not null,
  producto_original_id uuid not null references productos(id),
  cantidad numeric not null check (cantidad > 0),
  motivo text not null,
  producto_nuevo_id uuid references productos(id),
  cantidad_nueva numeric check (cantidad_nueva is null or cantidad_nueva > 0),
  diferencia_precio numeric,          -- positivo = paga el cliente, negativo = a favor del cliente
  resolucion resolucion_cambio_type,
  cliente_id uuid references clientes(id),
  usuario_id uuid not null references usuarios(id),
  fecha timestamptz not null default now(),
  created_at timestamptz not null default now(),
  check (tipo = 'devolucion' or (producto_nuevo_id is not null and cantidad_nueva is not null)),
  check (resolucion is distinct from 'saldo_pendiente' or (cliente_id is not null and diferencia_precio is not null and diferencia_precio <> 0))
);

create index idx_devoluciones_venta on devoluciones_cambios(venta_id);
create index idx_devoluciones_local on devoluciones_cambios(local_id);

create table reclamos_proveedor (
  id uuid primary key default gen_random_uuid(),
  proveedor_id uuid not null references proveedores(id),
  producto_id uuid references productos(id),
  local_id uuid not null references locales(id) on delete cascade,
  organization_id uuid not null references organizations(id) on delete cascade,
  cantidad numeric check (cantidad is null or cantidad > 0),
  motivo text not null,
  estado estado_reclamo_type not null default 'pendiente',
  usuario_id uuid not null references usuarios(id),
  fecha timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create index idx_reclamos_proveedor on reclamos_proveedor(proveedor_id);

alter table devoluciones_cambios enable row level security;
alter table reclamos_proveedor enable row level security;

create policy devoluciones_select on devoluciones_cambios
  for select
  using (organization_id = current_org_id() and is_approved() and org_is_active()
         and (is_admin() or local_id = current_local_id()));

create policy devoluciones_insert on devoluciones_cambios
  for insert
  with check (organization_id = current_org_id() and is_approved() and org_is_active()
              and (is_admin() or local_id = current_local_id()));

create policy reclamos_select on reclamos_proveedor
  for select
  using (organization_id = current_org_id() and is_approved() and org_is_active()
         and (is_admin() or local_id = current_local_id()));

create policy reclamos_insert on reclamos_proveedor
  for insert
  with check (organization_id = current_org_id() and is_approved() and org_is_active()
              and (is_admin() or local_id = current_local_id()));

create policy reclamos_update on reclamos_proveedor
  for update
  using (organization_id = current_org_id() and is_approved() and org_is_active()
         and (is_admin() or local_id = current_local_id()))
  with check (organization_id = current_org_id() and is_approved() and org_is_active()
              and (is_admin() or local_id = current_local_id()));

create or replace function public.aplicar_stock_devolucion_cambio()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.tipo = 'cambio' then
    update productos set stock_actual = stock_actual - new.cantidad_nueva, updated_at = now()
      where id = new.producto_nuevo_id;
  end if;

  if new.resolucion = 'saldo_pendiente' then
    insert into cuenta_corriente_movimientos
      (cliente_id, local_id, organization_id, tipo, monto, venta_id, usuario_id, fecha)
    values (
      new.cliente_id, new.local_id, new.organization_id,
      case when new.diferencia_precio >= 0 then 'fiado_nuevo' else 'saldo_favor_generado' end,
      abs(new.diferencia_precio),
      new.venta_id, new.usuario_id, new.fecha
    );
  end if;

  return new;
end;
$$;

create trigger trg_aplicar_stock_devolucion_cambio
  after insert on devoluciones_cambios
  for each row
  execute function public.aplicar_stock_devolucion_cambio();

create or replace function public.aplicar_stock_reclamo_proveedor()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.producto_id is not null and new.cantidad is not null then
    update productos set stock_actual = stock_actual - new.cantidad, updated_at = now()
      where id = new.producto_id;
  end if;
  return new;
end;
$$;

create trigger trg_aplicar_stock_reclamo_proveedor
  after insert on reclamos_proveedor
  for each row
  execute function public.aplicar_stock_reclamo_proveedor();
    $mig_body$;
    insert into _mig_log values ('20260709121500', 'devoluciones_reclamos', 'aplicada ahora');
  else
    insert into _mig_log values ('20260709121500', 'devoluciones_reclamos', 'ya estaba');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260709121500', 'devoluciones_reclamos') on conflict (version) do nothing;

-- ======================================================================
-- 20260709121600 cierres_caja
-- ======================================================================
do $mig$
begin
  if not (to_regclass('public.cierres_mensuales') is not null) then
    execute $mig_body$
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
    $mig_body$;
    insert into _mig_log values ('20260709121600', 'cierres_caja', 'aplicada ahora');
  else
    insert into _mig_log values ('20260709121600', 'cierres_caja', 'ya estaba');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260709121600', 'cierres_caja') on conflict (version) do nothing;

-- ======================================================================
-- 20260709121700 updated_at_triggers
-- ======================================================================
do $mig$
begin
  if not (exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace where ns.nspname = 'public' and p.proname = 'set_updated_at')) then
    execute $mig_body$
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger trg_productos_updated_at
  before update on productos
  for each row
  execute function public.set_updated_at();

create trigger trg_ventas_updated_at
  before update on ventas
  for each row
  execute function public.set_updated_at();
    $mig_body$;
    insert into _mig_log values ('20260709121700', 'updated_at_triggers', 'aplicada ahora');
  else
    insert into _mig_log values ('20260709121700', 'updated_at_triggers', 'ya estaba');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260709121700', 'updated_at_triggers') on conflict (version) do nothing;

-- ======================================================================
-- 20260710090000 invitaciones_codigo_default
-- ======================================================================
do $mig$
begin
  if not (exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace where ns.nspname = 'public' and p.proname = 'generar_codigo_invitacion')) then
    execute $mig_body$
create or replace function public.generar_codigo_invitacion()
returns text
language sql
volatile
as $$
  select upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));
$$;

alter table invitaciones alter column codigo set default generar_codigo_invitacion();
    $mig_body$;
    insert into _mig_log values ('20260710090000', 'invitaciones_codigo_default', 'aplicada ahora');
  else
    insert into _mig_log values ('20260710090000', 'invitaciones_codigo_default', 'ya estaba');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260710090000', 'invitaciones_codigo_default') on conflict (version) do nothing;

-- ======================================================================
-- 20260710090100 fn_crear_organizacion
-- ======================================================================
do $mig$
begin
  if not (exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace where ns.nspname = 'public' and p.proname = 'crear_organizacion')) then
    execute $mig_body$
create or replace function public.crear_organizacion(
  p_nombre text,
  p_nombre_admin text,
  p_telefono text default null
)
returns table (organization_id uuid, local_id uuid)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_local_id uuid;
  v_email text;
begin
  if auth.uid() is null then
    raise exception 'Se requiere estar autenticado (auth.signUp) antes de crear la organizacion';
  end if;

  if exists (select 1 from usuarios where id = auth.uid()) then
    raise exception 'Este usuario ya tiene una organizacion asociada';
  end if;

  select email into v_email from auth.users where id = auth.uid();

  insert into organizations (nombre) values (p_nombre) returning id into v_org_id;
  insert into locales (organization_id, nombre) values (v_org_id, p_nombre) returning id into v_local_id;

  insert into usuarios (id, organization_id, local_id, role, status, nombre, email, telefono)
  values (auth.uid(), v_org_id, null, 'admin', 'approved', p_nombre_admin, v_email, p_telefono);

  return query select v_org_id, v_local_id;
end;
$$;

comment on function public.crear_organizacion is 'local_id del admin queda null a proposito: el admin ve todos los locales de su organizacion (usuarios.local_id, seccion 2), no esta atado a uno solo.';
    $mig_body$;
    insert into _mig_log values ('20260710090100', 'fn_crear_organizacion', 'aplicada ahora');
  else
    insert into _mig_log values ('20260710090100', 'fn_crear_organizacion', 'ya estaba');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260710090100', 'fn_crear_organizacion') on conflict (version) do nothing;

-- ======================================================================
-- 20260710090200 fn_redimir_invitacion
-- ======================================================================
do $mig$
begin
  if not (exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace where ns.nspname = 'public' and p.proname = 'redimir_invitacion')) then
    execute $mig_body$
create or replace function public.redimir_invitacion(
  p_codigo text,
  p_nombre text,
  p_telefono text default null
)
returns table (organization_nombre text, local_nombre text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_invitacion invitaciones%rowtype;
  v_email text;
  v_local_id uuid;
  v_locales_count int;
begin
  if auth.uid() is null then
    raise exception 'Se requiere estar autenticado (auth.signUp) antes de redimir la invitacion';
  end if;

  if exists (select 1 from usuarios where id = auth.uid()) then
    raise exception 'Este usuario ya tiene una organizacion asociada';
  end if;

  select * into v_invitacion
    from invitaciones
    where codigo = upper(trim(p_codigo))
      and usado_por is null
      and (expira_at is null or expira_at > now())
    for update;

  if not found then
    raise exception 'Codigo de invitacion invalido, vencido o ya utilizado';
  end if;

  select email into v_email from auth.users where id = auth.uid();

  v_local_id := v_invitacion.local_id;
  if v_local_id is null then
    select count(*) into v_locales_count from locales where organization_id = v_invitacion.organization_id;
    if v_locales_count = 1 then
      select id into v_local_id from locales where organization_id = v_invitacion.organization_id;
    end if;
  end if;

  insert into usuarios (id, organization_id, local_id, role, status, nombre, email, telefono)
  values (auth.uid(), v_invitacion.organization_id, v_local_id, 'empleado', 'pending', p_nombre, v_email, p_telefono);

  update invitaciones set usado_por = auth.uid(), usado_at = now() where id = v_invitacion.id;

  return query
    select o.nombre, l.nombre
    from organizations o
    left join locales l on l.id = v_local_id
    where o.id = v_invitacion.organization_id;
end;
$$;
    $mig_body$;
    insert into _mig_log values ('20260710090200', 'fn_redimir_invitacion', 'aplicada ahora');
  else
    insert into _mig_log values ('20260710090200', 'fn_redimir_invitacion', 'ya estaba');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260710090200', 'fn_redimir_invitacion') on conflict (version) do nothing;

-- ======================================================================
-- 20260710090300 usuarios_local_requerido
-- ======================================================================
do $mig$
begin
  if not (exists (select 1 from pg_constraint where conname = 'usuarios_empleado_approved_requiere_local')) then
    execute $mig_body$
alter table usuarios
  add constraint usuarios_empleado_approved_requiere_local
  check (role = 'admin' or status <> 'approved' or local_id is not null);
    $mig_body$;
    insert into _mig_log values ('20260710090300', 'usuarios_local_requerido', 'aplicada ahora');
  else
    insert into _mig_log values ('20260710090300', 'usuarios_local_requerido', 'ya estaba');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260710090300', 'usuarios_local_requerido') on conflict (version) do nothing;

-- ======================================================================
-- 20260710090400 fn_registrar_sesion
-- ======================================================================
do $mig$
begin
  if not (exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace where ns.nspname = 'public' and p.proname = 'registrar_sesion')) then
    execute $mig_body$
create or replace function public.registrar_sesion(p_session_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_previa uuid;
begin
  if auth.uid() is null then
    raise exception 'Se requiere estar autenticado';
  end if;

  select current_session_id into v_previa from usuarios where id = auth.uid();

  update usuarios
    set current_session_id = p_session_id,
        last_login_at = now()
    where id = auth.uid();

  return v_previa is not null and v_previa is distinct from p_session_id;
end;
$$;

comment on function public.registrar_sesion is 'p_session_id sale del claim session_id del JWT recien emitido (supabase-js no lo expone directo: se decodifica del access_token en el cliente).';
    $mig_body$;
    insert into _mig_log values ('20260710090400', 'fn_registrar_sesion', 'aplicada ahora');
  else
    insert into _mig_log values ('20260710090400', 'fn_registrar_sesion', 'ya estaba');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260710090400', 'fn_registrar_sesion') on conflict (version) do nothing;

-- ======================================================================
-- 20260710090500 grants_authenticated
-- ======================================================================
do $mig$
begin
  if true then
    execute $mig_body$
grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
alter default privileges in schema public grant select, insert, update, delete on tables to authenticated;
    $mig_body$;
    insert into _mig_log values ('20260710090500', 'grants_authenticated', 'reaplicada (idempotente)');
  else
    insert into _mig_log values ('20260710090500', 'grants_authenticated', 'ya estaba');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260710090500', 'grants_authenticated') on conflict (version) do nothing;

-- ======================================================================
-- 20260710090600 organizations_is_active_solo_service_role
-- ======================================================================
do $mig$
begin
  if not (exists (select 1 from pg_trigger where tgname = 'trg_prevent_is_active_change' and not tgisinternal)) then
    execute $mig_body$
create or replace function public.prevent_is_active_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.role() = 'service_role' then
    return new;
  end if;

  if new.is_active is distinct from old.is_active then
    raise exception 'Solo el super-admin del sistema puede activar o desactivar una organizacion';
  end if;

  return new;
end;
$$;

create trigger trg_prevent_is_active_change
  before update on organizations
  for each row
  execute function public.prevent_is_active_change();
    $mig_body$;
    insert into _mig_log values ('20260710090600', 'organizations_is_active_solo_service_role', 'aplicada ahora');
  else
    insert into _mig_log values ('20260710090600', 'organizations_is_active_solo_service_role', 'ya estaba');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260710090600', 'organizations_is_active_solo_service_role') on conflict (version) do nothing;

-- ======================================================================
-- 20260711080000 productos_categorias_admin_only
-- ======================================================================
do $mig$
begin
  if not (exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'productos' and policyname = 'productos_insert' and coalesce(with_check, qual) like '%is_admin()%')) then
    execute $mig_body$
drop policy productos_insert on productos;
create policy productos_insert on productos
  for insert
  with check (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active());

drop policy productos_update on productos;
create policy productos_update on productos
  for update
  using (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active())
  with check (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active());

drop policy categorias_insert on categorias;
create policy categorias_insert on categorias
  for insert
  with check (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active());

drop policy categorias_update on categorias;
create policy categorias_update on categorias
  for update
  using (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active())
  with check (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active());
    $mig_body$;
    insert into _mig_log values ('20260711080000', 'productos_categorias_admin_only', 'aplicada ahora');
  else
    insert into _mig_log values ('20260711080000', 'productos_categorias_admin_only', 'ya estaba');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260711080000', 'productos_categorias_admin_only') on conflict (version) do nothing;

-- ======================================================================
-- 20260712080000 proveedores_admin_only
-- ======================================================================
do $mig$
begin
  if not (exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'proveedores' and policyname = 'proveedores_insert' and coalesce(with_check, qual) like '%is_admin()%')) then
    execute $mig_body$
drop policy proveedores_insert on proveedores;
create policy proveedores_insert on proveedores
  for insert
  with check (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active());

drop policy proveedores_update on proveedores;
create policy proveedores_update on proveedores
  for update
  using (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active())
  with check (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active());

drop policy producto_proveedor_insert on producto_proveedor;
create policy producto_proveedor_insert on producto_proveedor
  for insert
  with check (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active());

drop policy producto_proveedor_delete on producto_proveedor;
create policy producto_proveedor_delete on producto_proveedor
  for delete
  using (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active());
    $mig_body$;
    insert into _mig_log values ('20260712080000', 'proveedores_admin_only', 'aplicada ahora');
  else
    insert into _mig_log values ('20260712080000', 'proveedores_admin_only', 'ya estaba');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260712080000', 'proveedores_admin_only') on conflict (version) do nothing;

-- ======================================================================
-- 20260713080000 soft_delete_productos_proveedores
-- ======================================================================
do $mig$
begin
  if not (exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'productos' and column_name = 'deleted_at')) then
    execute $mig_body$
alter table productos add column deleted_at timestamptz;
alter table proveedores add column deleted_at timestamptz;

drop index if exists idx_productos_codigo_barras;
create unique index idx_productos_codigo_barras
  on productos(local_id, codigo_barras)
  where codigo_barras is not null and deleted_at is null;

drop policy productos_update on productos;
create policy productos_update on productos
  for update
  using (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active() and deleted_at is null)
  with check (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active());

drop policy proveedores_update on proveedores;
create policy proveedores_update on proveedores
  for update
  using (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active() and deleted_at is null)
  with check (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active());
    $mig_body$;
    insert into _mig_log values ('20260713080000', 'soft_delete_productos_proveedores', 'aplicada ahora');
  else
    insert into _mig_log values ('20260713080000', 'soft_delete_productos_proveedores', 'ya estaba');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260713080000', 'soft_delete_productos_proveedores') on conflict (version) do nothing;

-- ======================================================================
-- 20260714080000 fiado_anulado_enum
-- ======================================================================
alter type tipo_movimiento_cc_type add value if not exists 'fiado_anulado';
insert into _mig_log values ('20260714080000', 'fiado_anulado_enum', 'aplicada (idempotente)');
insert into supabase_migrations.schema_migrations (version, name) values ('20260714080000', 'fiado_anulado_enum') on conflict (version) do nothing;

-- ======================================================================
-- 20260714080100 anulacion_venta_reversa_fiado
-- ======================================================================
do $mig$
begin
  if not (exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace where ns.nspname = 'public' and p.proname = 'aplicar_anulacion_venta' and pg_get_functiondef(p.oid) like '%fiado_anulado%')) then
    execute $mig_body$
create or replace function public.aplicar_movimiento_cuenta_corriente()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  delta numeric;
begin
  delta := case new.tipo
    when 'fiado_nuevo' then new.monto
    when 'cobro_fiado' then -new.monto
    when 'saldo_favor_generado' then -new.monto
    when 'saldo_favor_usado' then new.monto
    when 'fiado_anulado' then -new.monto
  end;

  update clientes set saldo = saldo + delta where id = new.cliente_id;
  return new;
end;
$$;

create or replace function public.aplicar_anulacion_venta()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.estado = 'anulada' and old.estado is distinct from 'anulada' then
    update productos p
      set stock_actual = p.stock_actual + vi.total_cantidad,
          updated_at = now()
      from (
        select producto_id, sum(cantidad) as total_cantidad
        from venta_items
        where venta_id = new.id
        group by producto_id
      ) vi
      where vi.producto_id = p.id;

    if new.es_fiado and new.total > 0 then
      insert into cuenta_corriente_movimientos
        (cliente_id, local_id, organization_id, tipo, monto, venta_id, usuario_id, fecha)
      values (
        new.cliente_id, new.local_id, new.organization_id, 'fiado_anulado', new.total,
        new.id, coalesce(new.anulada_por, new.usuario_id), now()
      );
    end if;
  end if;
  return new;
end;
$$;
    $mig_body$;
    insert into _mig_log values ('20260714080100', 'anulacion_venta_reversa_fiado', 'aplicada ahora');
  else
    insert into _mig_log values ('20260714080100', 'anulacion_venta_reversa_fiado', 'ya estaba');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260714080100', 'anulacion_venta_reversa_fiado') on conflict (version) do nothing;

-- ======================================================================
-- 20260715080000 oferta_descuento_venta_items
-- ======================================================================
-- sin efecto neto (ver comentario en el generador): se registra y se sigue.
insert into _mig_log values ('20260715080000', 'oferta_descuento_venta_items', 'omitida (efecto neto cero)');
insert into supabase_migrations.schema_migrations (version, name) values ('20260715080000', 'oferta_descuento_venta_items') on conflict (version) do nothing;

-- ======================================================================
-- 20260715080100 fiado_habilitado_y_reclamos_admin
-- ======================================================================
do $mig$
begin
  if not (exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'locales' and column_name = 'fiado_habilitado')) then
    execute $mig_body$
alter table locales add column fiado_habilitado boolean not null default true;

drop policy reclamos_select on reclamos_proveedor;
create policy reclamos_select on reclamos_proveedor
  for select
  using (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active());

drop policy reclamos_insert on reclamos_proveedor;
create policy reclamos_insert on reclamos_proveedor
  for insert
  with check (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active());

drop policy reclamos_update on reclamos_proveedor;
create policy reclamos_update on reclamos_proveedor
  for update
  using (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active())
  with check (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active());
    $mig_body$;
    insert into _mig_log values ('20260715080100', 'fiado_habilitado_y_reclamos_admin', 'aplicada ahora');
  else
    insert into _mig_log values ('20260715080100', 'fiado_habilitado_y_reclamos_admin', 'ya estaba');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260715080100', 'fiado_habilitado_y_reclamos_admin') on conflict (version) do nothing;

-- ======================================================================
-- 20260716080000 revertir_oferta_descuento_venta_items
-- ======================================================================
do $mig$
begin
  if not (not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'venta_items' and column_name = 'precio_lista')) then
    execute $mig_body$
alter table venta_items drop constraint venta_items_motivo_si_hay_oferta;
alter table venta_items drop column precio_lista;
alter table venta_items drop column motivo_descuento;
    $mig_body$;
    insert into _mig_log values ('20260716080000', 'revertir_oferta_descuento_venta_items', 'aplicada ahora');
  else
    insert into _mig_log values ('20260716080000', 'revertir_oferta_descuento_venta_items', 'ya estaba');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260716080000', 'revertir_oferta_descuento_venta_items') on conflict (version) do nothing;

-- ======================================================================
-- 20260717080000 super_admins
-- ======================================================================
do $mig$
begin
  if not (to_regclass('public.super_admins') is not null) then
    execute $mig_body$
create table super_admins (
  id uuid primary key references auth.users(id) on delete cascade,
  nombre text not null,
  created_at timestamptz not null default now()
);

alter table super_admins enable row level security;

create policy super_admins_select_self on super_admins
  for select
  using (id = auth.uid());

create or replace function public.is_super_admin()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (select 1 from super_admins where id = auth.uid());
$$;

create policy organizations_select_superadmin on organizations
  for select
  using (is_super_admin());

create policy organizations_update_superadmin on organizations
  for update
  using (is_super_admin())
  with check (is_super_admin());
    $mig_body$;
    insert into _mig_log values ('20260717080000', 'super_admins', 'aplicada ahora');
  else
    insert into _mig_log values ('20260717080000', 'super_admins', 'ya estaba');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260717080000', 'super_admins') on conflict (version) do nothing;

-- ======================================================================
-- 20260717080100 solicitudes_cambio_plan
-- ======================================================================
do $mig$
begin
  if not (to_regclass('public.solicitudes_cambio_plan') is not null) then
    execute $mig_body$
create type estado_solicitud_type as enum ('pendiente', 'aprobada', 'rechazada');

create table solicitudes_cambio_plan (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  plan_actual plan_type not null,
  plan_solicitado plan_type not null,
  estado estado_solicitud_type not null default 'pendiente',
  solicitado_por uuid not null references usuarios(id),
  resuelta_por uuid references super_admins(id),
  resuelta_at timestamptz,
  created_at timestamptz not null default now(),
  check (plan_actual <> plan_solicitado)
);

create index idx_solicitudes_plan_organization on solicitudes_cambio_plan(organization_id);

create unique index idx_solicitudes_plan_pendiente_unica
  on solicitudes_cambio_plan(organization_id)
  where estado = 'pendiente';

alter table solicitudes_cambio_plan enable row level security;

create policy solicitudes_plan_select on solicitudes_cambio_plan
  for select
  using (
    is_super_admin()
    or (organization_id = current_org_id() and is_admin() and is_approved())
  );

create policy solicitudes_plan_insert on solicitudes_cambio_plan
  for insert
  with check (organization_id = current_org_id() and is_admin() and is_approved() and solicitado_por = auth.uid());

create or replace function public.aprobar_solicitud_plan(p_solicitud_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_plan plan_type;
  v_estado estado_solicitud_type;
begin
  if not is_super_admin() then
    raise exception 'No autorizado';
  end if;

  select organization_id, plan_solicitado, estado
    into v_org_id, v_plan, v_estado
    from solicitudes_cambio_plan
    where id = p_solicitud_id
    for update;

  if v_org_id is null then
    raise exception 'Solicitud no encontrada';
  end if;
  if v_estado <> 'pendiente' then
    raise exception 'Esta solicitud ya fue resuelta';
  end if;

  update organizations set plan = v_plan where id = v_org_id;

  update solicitudes_cambio_plan
    set estado = 'aprobada', resuelta_por = auth.uid(), resuelta_at = now()
    where id = p_solicitud_id;
end;
$$;

create or replace function public.rechazar_solicitud_plan(p_solicitud_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_estado estado_solicitud_type;
begin
  if not is_super_admin() then
    raise exception 'No autorizado';
  end if;

  select estado into v_estado from solicitudes_cambio_plan where id = p_solicitud_id for update;
  if v_estado is null then
    raise exception 'Solicitud no encontrada';
  end if;
  if v_estado <> 'pendiente' then
    raise exception 'Esta solicitud ya fue resuelta';
  end if;

  update solicitudes_cambio_plan
    set estado = 'rechazada', resuelta_por = auth.uid(), resuelta_at = now()
    where id = p_solicitud_id;
end;
$$;
    $mig_body$;
    insert into _mig_log values ('20260717080100', 'solicitudes_cambio_plan', 'aplicada ahora');
  else
    insert into _mig_log values ('20260717080100', 'solicitudes_cambio_plan', 'ya estaba');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260717080100', 'solicitudes_cambio_plan') on conflict (version) do nothing;

-- ======================================================================
-- 20260911150000 eliminar_plan_medio
-- ======================================================================
do $mig$
begin
  if not (to_regtype('public.plan_type') is not null and not exists (select 1 from pg_enum e join pg_type ty on ty.oid = e.enumtypid where ty.typname = 'plan_type' and e.enumlabel = 'medio') and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'solicitudes_cambio_plan' and column_name = 'plan_actual' and data_type = 'text')) then
    execute $mig_body$
update organizations set plan = 'basico' where plan = 'medio';

alter type plan_type rename to plan_type_old;
create type plan_type as enum ('basico', 'completo');

alter table organizations
  alter column plan drop default,
  alter column plan type plan_type using plan::text::plan_type,
  alter column plan set default 'basico';

alter table solicitudes_cambio_plan
  alter column plan_actual type text using plan_actual::text,
  alter column plan_solicitado type text using plan_solicitado::text;

create or replace function public.aprobar_solicitud_plan(p_solicitud_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_plan text;
  v_estado estado_solicitud_type;
begin
  if not is_super_admin() then
    raise exception 'No autorizado';
  end if;

  select organization_id, plan_solicitado, estado
    into v_org_id, v_plan, v_estado
    from solicitudes_cambio_plan
    where id = p_solicitud_id
    for update;

  if v_org_id is null then
    raise exception 'Solicitud no encontrada';
  end if;
  if v_estado <> 'pendiente' then
    raise exception 'Esta solicitud ya fue resuelta';
  end if;

  update organizations set plan = v_plan::plan_type where id = v_org_id;

  update solicitudes_cambio_plan
    set estado = 'aprobada', resuelta_por = auth.uid(), resuelta_at = now()
    where id = p_solicitud_id;
end;
$$;

drop type plan_type_old;
    $mig_body$;
    insert into _mig_log values ('20260911150000', 'eliminar_plan_medio', 'aplicada ahora');
  else
    insert into _mig_log values ('20260911150000', 'eliminar_plan_medio', 'ya estaba');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260911150000', 'eliminar_plan_medio') on conflict (version) do nothing;

-- ======================================================================
-- 20260911200000 bloqueo_locales_por_plan
-- ======================================================================
do $mig$
begin
  if not (exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'locales' and column_name = 'bloqueado_por_plan')) then
    execute $mig_body$
create or replace function public.prevent_plan_change_directo()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.plan is distinct from old.plan
     and coalesce(current_setting('app.bypass_plan_change_check', true), '') <> 'true'
  then
    raise exception 'El plan solo se puede cambiar via aprobar_solicitud_plan()';
  end if;

  return new;
end;
$$;

create trigger trg_prevent_plan_change_directo
  before update on organizations
  for each row
  execute function public.prevent_plan_change_directo();

create or replace function public.aprobar_solicitud_plan(p_solicitud_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_plan text;
  v_estado estado_solicitud_type;
begin
  if not is_super_admin() then
    raise exception 'No autorizado';
  end if;

  select organization_id, plan_solicitado, estado
    into v_org_id, v_plan, v_estado
    from solicitudes_cambio_plan
    where id = p_solicitud_id
    for update;

  if v_org_id is null then
    raise exception 'Solicitud no encontrada';
  end if;
  if v_estado <> 'pendiente' then
    raise exception 'Esta solicitud ya fue resuelta';
  end if;

  perform set_config('app.bypass_plan_change_check', 'true', true);
  update organizations set plan = v_plan::plan_type where id = v_org_id;

  update solicitudes_cambio_plan
    set estado = 'aprobada', resuelta_por = auth.uid(), resuelta_at = now()
    where id = p_solicitud_id;
end;
$$;

alter table locales add column bloqueado_por_plan boolean not null default false;
comment on column locales.bloqueado_por_plan is 'Seccion 15: true cuando el local quedo por encima de lo que permite el plan contratado (sin multi_local, solo el local mas antiguo de la organizacion queda operable). Lo mantienen sincronizado trg_recalcular_locales_bloqueados y trg_inicializar_bloqueo_local -- no tocar a mano. Distinto de locales.activo, que es una pausa administrativa manual sin UI todavia y no gatea nada de esto.';

create or replace function public.local_is_active(p_local_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select coalesce((select not l.bloqueado_por_plan from locales l where l.id = p_local_id), false);
$$;

comment on function public.local_is_active(uuid) is 'true si el local no esta bloqueado por plan (seccion 15). Solo refleja locales.bloqueado_por_plan -- no compone con locales.activo (concepto aparte, ver comentario de esa columna).';

create or replace function public.recalcular_locales_bloqueados()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_multi_local boolean;
  v_local_mas_viejo uuid;
begin
  if new.plan is not distinct from old.plan and new.plan_overrides is not distinct from old.plan_overrides then
    return new;
  end if;

  v_multi_local := coalesce((new.plan_overrides->>'multi_local')::boolean, new.plan = 'completo');

  if v_multi_local then
    update locales set bloqueado_por_plan = false
      where organization_id = new.id and bloqueado_por_plan;
    return new;
  end if;

  select id into v_local_mas_viejo
    from locales
    where organization_id = new.id
    order by created_at asc
    limit 1;

  if v_local_mas_viejo is not null then
    update locales set bloqueado_por_plan = true
      where organization_id = new.id and id <> v_local_mas_viejo and not bloqueado_por_plan;
    update locales set bloqueado_por_plan = false
      where organization_id = new.id and id = v_local_mas_viejo and bloqueado_por_plan;
  end if;

  return new;
end;
$$;

create trigger trg_recalcular_locales_bloqueados
  after update of plan, plan_overrides on organizations
  for each row
  execute function public.recalcular_locales_bloqueados();

create or replace function public.inicializar_bloqueo_local()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org organizations%rowtype;
  v_multi_local boolean;
begin
  select * into v_org from organizations where id = new.organization_id;
  v_multi_local := coalesce((v_org.plan_overrides->>'multi_local')::boolean, v_org.plan = 'completo');

  new.bloqueado_por_plan := (not v_multi_local) and exists (
    select 1 from locales where organization_id = new.organization_id
  );

  return new;
end;
$$;

create trigger trg_inicializar_bloqueo_local
  before insert on locales
  for each row
  execute function public.inicializar_bloqueo_local();

alter policy ajustes_insert on ajustes_stock
  with check (((organization_id = current_org_id()) AND is_approved() AND org_is_active() AND (is_admin() OR (local_id = current_local_id()))) AND local_is_active(local_id));

alter policy categorias_insert on categorias
  with check (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active()) AND local_is_active(local_id));
alter policy categorias_update on categorias
  using (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active()) AND local_is_active(local_id))
  with check (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active()) AND local_is_active(local_id));
alter policy categorias_delete on categorias
  using (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active()) AND local_is_active(local_id));

alter policy cierres_diarios_insert on cierres_diarios
  with check (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active()) AND local_is_active(local_id));
alter policy cierres_diarios_update on cierres_diarios
  using (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active()) AND local_is_active(local_id))
  with check (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active()) AND local_is_active(local_id));

alter policy cierres_mensuales_insert on cierres_mensuales
  with check (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active()) AND local_is_active(local_id));
alter policy cierres_mensuales_update on cierres_mensuales
  using (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active()) AND local_is_active(local_id))
  with check (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active()) AND local_is_active(local_id));

alter policy clientes_insert on clientes
  with check (((organization_id = current_org_id()) AND is_approved() AND org_is_active() AND (is_admin() OR (local_id = current_local_id()))) AND local_is_active(local_id));
alter policy clientes_update on clientes
  using (((organization_id = current_org_id()) AND is_approved() AND org_is_active() AND (is_admin() OR (local_id = current_local_id()))) AND local_is_active(local_id))
  with check (((organization_id = current_org_id()) AND is_approved() AND org_is_active() AND (is_admin() OR (local_id = current_local_id()))) AND local_is_active(local_id));

alter policy cc_movimientos_insert on cuenta_corriente_movimientos
  with check (((organization_id = current_org_id()) AND is_approved() AND org_is_active() AND (is_admin() OR (local_id = current_local_id()))) AND local_is_active(local_id));

alter policy devoluciones_insert on devoluciones_cambios
  with check (((organization_id = current_org_id()) AND is_approved() AND org_is_active() AND (is_admin() OR (local_id = current_local_id()))) AND local_is_active(local_id));

alter policy producto_proveedor_insert on producto_proveedor
  with check (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active()) AND local_is_active(local_id));
alter policy producto_proveedor_delete on producto_proveedor
  using (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active()) AND local_is_active(local_id));

alter policy productos_insert on productos
  with check (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active()) AND local_is_active(local_id));
alter policy productos_update on productos
  using (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active() AND (deleted_at IS NULL)) AND local_is_active(local_id))
  with check (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active()) AND local_is_active(local_id));

alter policy proveedores_insert on proveedores
  with check (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active()) AND local_is_active(local_id));
alter policy proveedores_update on proveedores
  using (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active() AND (deleted_at IS NULL)) AND local_is_active(local_id))
  with check (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active()) AND local_is_active(local_id));

alter policy reclamos_insert on reclamos_proveedor
  with check (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active()) AND local_is_active(local_id));
alter policy reclamos_update on reclamos_proveedor
  using (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active()) AND local_is_active(local_id))
  with check (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active()) AND local_is_active(local_id));

alter policy reposiciones_insert on reposiciones_stock
  with check (((organization_id = current_org_id()) AND is_approved() AND org_is_active() AND (is_admin() OR (local_id = current_local_id()))) AND local_is_active(local_id));

alter policy turnos_insert on turnos
  with check (((organization_id = current_org_id()) AND is_approved() AND org_is_active() AND (usuario_id = auth.uid()) AND (is_admin() OR (local_id = current_local_id()))) AND local_is_active(local_id));
alter policy turnos_update on turnos
  using (((organization_id = current_org_id()) AND is_approved() AND org_is_active() AND (is_admin() OR ((local_id = current_local_id()) AND (usuario_id = auth.uid())))) AND local_is_active(local_id))
  with check (((organization_id = current_org_id()) AND is_approved() AND org_is_active() AND (is_admin() OR ((local_id = current_local_id()) AND (usuario_id = auth.uid())))) AND local_is_active(local_id));

alter policy venta_items_insert on venta_items
  with check (((organization_id = current_org_id()) AND is_approved() AND org_is_active() AND (is_admin() OR (local_id = current_local_id()))) AND local_is_active(local_id));
alter policy venta_items_update on venta_items
  using (((organization_id = current_org_id()) AND is_approved() AND org_is_active() AND (is_admin() OR ((local_id = current_local_id()) AND (EXISTS ( SELECT 1 FROM ventas v WHERE ((v.id = venta_items.venta_id) AND (v.usuario_id = auth.uid()) AND (v.created_at > (now() - '00:15:00'::interval)))))))) AND local_is_active(local_id))
  with check (((organization_id = current_org_id()) AND is_approved() AND org_is_active() AND (is_admin() OR (local_id = current_local_id()))) AND local_is_active(local_id));
alter policy venta_items_delete on venta_items
  using (((organization_id = current_org_id()) AND is_approved() AND org_is_active() AND (is_admin() OR ((local_id = current_local_id()) AND (EXISTS ( SELECT 1 FROM ventas v WHERE ((v.id = venta_items.venta_id) AND (v.usuario_id = auth.uid()) AND (v.created_at > (now() - '00:15:00'::interval)))))))) AND local_is_active(local_id));

alter policy venta_pagos_insert on venta_pagos
  with check (((organization_id = current_org_id()) AND is_approved() AND org_is_active() AND (is_admin() OR (local_id = current_local_id()))) AND local_is_active(local_id));
alter policy venta_pagos_delete on venta_pagos
  using (((organization_id = current_org_id()) AND is_approved() AND org_is_active() AND (is_admin() OR ((local_id = current_local_id()) AND (EXISTS ( SELECT 1 FROM ventas v WHERE ((v.id = venta_pagos.venta_id) AND (v.usuario_id = auth.uid()) AND (v.created_at > (now() - '00:15:00'::interval)))))))) AND local_is_active(local_id));

alter policy ventas_insert on ventas
  with check (((organization_id = current_org_id()) AND is_approved() AND org_is_active() AND (usuario_id = auth.uid()) AND (is_admin() OR (local_id = current_local_id()))) AND local_is_active(local_id));
alter policy ventas_update on ventas
  using (((organization_id = current_org_id()) AND is_approved() AND org_is_active() AND (is_admin() OR ((local_id = current_local_id()) AND (usuario_id = auth.uid()) AND (created_at > (now() - '00:15:00'::interval))))) AND local_is_active(local_id))
  with check (((organization_id = current_org_id()) AND is_approved() AND org_is_active() AND (is_admin() OR (local_id = current_local_id()))) AND local_is_active(local_id));
    $mig_body$;
    insert into _mig_log values ('20260911200000', 'bloqueo_locales_por_plan', 'aplicada ahora');
  else
    insert into _mig_log values ('20260911200000', 'bloqueo_locales_por_plan', 'ya estaba');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260911200000', 'bloqueo_locales_por_plan') on conflict (version) do nothing;

-- ======================================================================
-- 20260911200100 backfill_locales_bloqueados
-- ======================================================================
do $mig$
begin
  if exists (select 1 from _mig_log where version = '20260911200000' and accion like 'aplicada%') then
    execute $mig_body$
do $$
declare
  v_org record;
  v_multi_local boolean;
  v_local_mas_viejo uuid;
begin
  for v_org in select id, plan, plan_overrides from organizations loop
    v_multi_local := coalesce((v_org.plan_overrides->>'multi_local')::boolean, v_org.plan = 'completo');

    if v_multi_local then
      update locales set bloqueado_por_plan = false
        where organization_id = v_org.id and bloqueado_por_plan;
      continue;
    end if;

    select id into v_local_mas_viejo
      from locales
      where organization_id = v_org.id
      order by created_at asc
      limit 1;

    if v_local_mas_viejo is not null then
      update locales set bloqueado_por_plan = true
        where organization_id = v_org.id and id <> v_local_mas_viejo and not bloqueado_por_plan;
      update locales set bloqueado_por_plan = false
        where organization_id = v_org.id and id = v_local_mas_viejo and bloqueado_por_plan;
    end if;
  end loop;
end;
$$;
    $mig_body$;
    insert into _mig_log values ('20260911200100', 'backfill_locales_bloqueados', 'aplicada ahora');
  else
    insert into _mig_log values ('20260911200100', 'backfill_locales_bloqueados', 'omitida (la migracion de la que depende ya estaba)');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260911200100', 'backfill_locales_bloqueados') on conflict (version) do nothing;

-- ======================================================================
-- 20260911210000 rpc_productos_mas_vendidos
-- ======================================================================
do $mig$
begin
  if not (exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace where ns.nspname = 'public' and p.proname = 'obtener_productos_mas_vendidos')) then
    execute $mig_body$
create or replace function public.obtener_productos_mas_vendidos(
  p_desde timestamptz,
  p_hasta timestamptz,
  p_hora_desde int default null,
  p_hora_hasta int default null
)
returns table (producto_id uuid, nombre text, cantidad numeric)
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_plan plan_type;
  v_plan_overrides jsonb;
begin
  if not (is_admin() and is_approved() and org_is_active()) then
    raise exception 'No autorizado';
  end if;

  select o.plan, o.plan_overrides into v_plan, v_plan_overrides
    from organizations o
    where o.id = current_org_id();

  if not coalesce((v_plan_overrides->>'estadisticas')::boolean, v_plan = 'completo') then
    raise exception 'Tu plan no incluye estadisticas';
  end if;

  return query
    select vi.producto_id, coalesce(p.nombre, 'Producto eliminado') as nombre, sum(vi.cantidad) as cantidad
      from venta_items vi
      join ventas v on v.id = vi.venta_id
      left join productos p on p.id = vi.producto_id
      where v.organization_id = current_org_id()
        and v.fecha >= p_desde
        and v.fecha < p_hasta
        and v.estado <> 'anulada'
        and (p_hora_desde is null or extract(hour from v.fecha at time zone 'America/Argentina/Buenos_Aires') >= p_hora_desde)
        and (p_hora_hasta is null or extract(hour from v.fecha at time zone 'America/Argentina/Buenos_Aires') < p_hora_hasta)
      group by vi.producto_id, p.nombre
      order by sum(vi.cantidad) desc;
end;
$$;
    $mig_body$;
    insert into _mig_log values ('20260911210000', 'rpc_productos_mas_vendidos', 'aplicada ahora');
  else
    insert into _mig_log values ('20260911210000', 'rpc_productos_mas_vendidos', 'ya estaba');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260911210000', 'rpc_productos_mas_vendidos') on conflict (version) do nothing;

-- ======================================================================
-- 20260912090000 permite_cantidad_decimal
-- ======================================================================
do $mig$
begin
  if not (exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'productos' and column_name = 'permite_cantidad_decimal')) then
    execute $mig_body$
alter table productos add column permite_cantidad_decimal boolean not null default true;
comment on column productos.permite_cantidad_decimal is 'false = se vende por unidad, no admite fracciones (seccion 4). Validado en venta_items/ajustes_stock/reposiciones_stock/devoluciones_cambios via trigger -- el frontend ya lo valida, esto es el respaldo server-side.';

create or replace function public.validar_cantidad_entera_producto()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_permite boolean;
begin
  select permite_cantidad_decimal into v_permite from productos where id = new.producto_id;
  if v_permite is false and new.cantidad <> trunc(new.cantidad) then
    raise exception 'Este producto se vende por unidad, no admite cantidades decimales';
  end if;
  return new;
end;
$$;

create trigger trg_validar_cantidad_entera_venta_items
  before insert or update of cantidad, producto_id on venta_items
  for each row
  execute function public.validar_cantidad_entera_producto();

create trigger trg_validar_cantidad_entera_ajustes_stock
  before insert on ajustes_stock
  for each row
  execute function public.validar_cantidad_entera_producto();

create trigger trg_validar_cantidad_entera_reposiciones_stock
  before insert on reposiciones_stock
  for each row
  execute function public.validar_cantidad_entera_producto();

create or replace function public.validar_cantidad_entera_devolucion()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_permite boolean;
begin
  select permite_cantidad_decimal into v_permite from productos where id = new.producto_original_id;
  if v_permite is false and new.cantidad <> trunc(new.cantidad) then
    raise exception 'Este producto se vende por unidad, no admite cantidades decimales';
  end if;

  if new.producto_nuevo_id is not null and new.cantidad_nueva is not null then
    select permite_cantidad_decimal into v_permite from productos where id = new.producto_nuevo_id;
    if v_permite is false and new.cantidad_nueva <> trunc(new.cantidad_nueva) then
      raise exception 'Este producto se vende por unidad, no admite cantidades decimales';
    end if;
  end if;

  return new;
end;
$$;

create trigger trg_validar_cantidad_entera_devoluciones
  before insert on devoluciones_cambios
  for each row
  execute function public.validar_cantidad_entera_devolucion();
    $mig_body$;
    insert into _mig_log values ('20260912090000', 'permite_cantidad_decimal', 'aplicada ahora');
  else
    insert into _mig_log values ('20260912090000', 'permite_cantidad_decimal', 'ya estaba');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260912090000', 'permite_cantidad_decimal') on conflict (version) do nothing;

-- ======================================================================
-- 20260912093000 rpc_registrar_venta
-- ======================================================================
do $mig$
begin
  if not (exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace where ns.nspname = 'public' and p.proname = 'registrar_venta')) then
    execute $mig_body$
create or replace function public.registrar_venta(
  p_turno_id uuid,
  p_local_id uuid,
  p_organization_id uuid,
  p_items jsonb,      -- [{ productoId, cantidad, precioUnitario }]
  p_es_fiado boolean,
  p_cliente_id uuid,
  p_pagos jsonb        -- [{ metodo, monto }], ignorado si p_es_fiado
)
returns ventas
language plpgsql
security definer
set search_path = public
as $$
declare
  v_usuario_id uuid := auth.uid();
  v_total numeric;
  v_venta ventas%rowtype;
  v_item jsonb;
  v_pago jsonb;
begin
  if not (
    is_approved() and org_is_active() and p_organization_id = current_org_id()
    and (is_admin() or p_local_id = current_local_id())
  ) then
    raise exception 'No autorizado';
  end if;

  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'La venta necesita al menos un item';
  end if;

  select coalesce(sum((it->>'cantidad')::numeric * (it->>'precioUnitario')::numeric), 0)
    into v_total
    from jsonb_array_elements(p_items) it;

  insert into ventas (local_id, organization_id, turno_id, usuario_id, cliente_id, es_fiado, total)
  values (
    p_local_id,
    p_organization_id,
    p_turno_id,
    v_usuario_id,
    case when p_es_fiado then p_cliente_id else null end,
    p_es_fiado,
    v_total
  )
  returning * into v_venta;

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    insert into venta_items (venta_id, producto_id, local_id, organization_id, cantidad, precio_unitario)
    values (
      v_venta.id,
      (v_item->>'productoId')::uuid,
      p_local_id,
      p_organization_id,
      (v_item->>'cantidad')::numeric,
      (v_item->>'precioUnitario')::numeric
    );
  end loop;

  if p_es_fiado then
    insert into cuenta_corriente_movimientos (cliente_id, local_id, organization_id, tipo, monto, venta_id, usuario_id)
    values (p_cliente_id, p_local_id, p_organization_id, 'fiado_nuevo', v_total, v_venta.id, v_usuario_id);
  else
    for v_pago in select * from jsonb_array_elements(p_pagos)
    loop
      insert into venta_pagos (venta_id, local_id, organization_id, metodo, monto)
      values (
        v_venta.id,
        p_local_id,
        p_organization_id,
        (v_pago->>'metodo')::metodo_pago_type,
        (v_pago->>'monto')::numeric
      );
    end loop;
  end if;

  return v_venta;
end;
$$;
    $mig_body$;
    insert into _mig_log values ('20260912093000', 'rpc_registrar_venta', 'aplicada ahora');
  else
    insert into _mig_log values ('20260912093000', 'rpc_registrar_venta', 'ya estaba');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260912093000', 'rpc_registrar_venta') on conflict (version) do nothing;

-- ======================================================================
-- 20260923090000 archivar_locales_y_limite_por_plan
-- ======================================================================
do $mig$
begin
  if not (exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'locales' and column_name = 'archivado')) then
    execute $mig_body$
alter table locales add column archivado boolean not null default false;
comment on column locales.archivado is 'Local oculto y no operable, con todos sus datos (ventas, stock, historial) intactos. Reversible. Solo cambia via archivar_local() / restaurar_local() (lo protege trg_prevent_archivado_directo) -- no tocar a mano. Distinto de bloqueado_por_plan (lo decide el plan, no el dueno) y de activo (pausa administrativa sin UI, no gatea nada).';

create or replace function public.local_is_active(p_local_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select coalesce((select not l.bloqueado_por_plan and not l.archivado from locales l where l.id = p_local_id), false);
$$;

comment on function public.local_is_active(uuid) is 'true si el local es operable: ni bloqueado por plan (seccion 15) ni archivado. No compone con locales.activo (concepto aparte, ver comentario de esa columna).';

create or replace function public.registrar_venta(
  p_turno_id uuid,
  p_local_id uuid,
  p_organization_id uuid,
  p_items jsonb,      -- [{ productoId, cantidad, precioUnitario }]
  p_es_fiado boolean,
  p_cliente_id uuid,
  p_pagos jsonb        -- [{ metodo, monto }], ignorado si p_es_fiado
)
returns ventas
language plpgsql
security definer
set search_path = public
as $$
declare
  v_usuario_id uuid := auth.uid();
  v_total numeric;
  v_venta ventas%rowtype;
  v_item jsonb;
  v_pago jsonb;
begin
  if not (
    is_approved() and org_is_active() and p_organization_id = current_org_id()
    and (is_admin() or p_local_id = current_local_id())
    and local_is_active(p_local_id)
  ) then
    raise exception 'No autorizado';
  end if;

  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'La venta necesita al menos un item';
  end if;

  select coalesce(sum((it->>'cantidad')::numeric * (it->>'precioUnitario')::numeric), 0)
    into v_total
    from jsonb_array_elements(p_items) it;

  insert into ventas (local_id, organization_id, turno_id, usuario_id, cliente_id, es_fiado, total)
  values (
    p_local_id,
    p_organization_id,
    p_turno_id,
    v_usuario_id,
    case when p_es_fiado then p_cliente_id else null end,
    p_es_fiado,
    v_total
  )
  returning * into v_venta;

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    insert into venta_items (venta_id, producto_id, local_id, organization_id, cantidad, precio_unitario)
    values (
      v_venta.id,
      (v_item->>'productoId')::uuid,
      p_local_id,
      p_organization_id,
      (v_item->>'cantidad')::numeric,
      (v_item->>'precioUnitario')::numeric
    );
  end loop;

  if p_es_fiado then
    insert into cuenta_corriente_movimientos (cliente_id, local_id, organization_id, tipo, monto, venta_id, usuario_id)
    values (p_cliente_id, p_local_id, p_organization_id, 'fiado_nuevo', v_total, v_venta.id, v_usuario_id);
  else
    for v_pago in select * from jsonb_array_elements(p_pagos)
    loop
      insert into venta_pagos (venta_id, local_id, organization_id, metodo, monto)
      values (
        v_venta.id,
        p_local_id,
        p_organization_id,
        (v_pago->>'metodo')::metodo_pago_type,
        (v_pago->>'monto')::numeric
      );
    end loop;
  end if;

  return v_venta;
end;
$$;

create or replace function public.recalcular_locales_bloqueados()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_multi_local boolean;
  v_local_mas_viejo uuid;
begin
  if new.plan is not distinct from old.plan and new.plan_overrides is not distinct from old.plan_overrides then
    return new;
  end if;

  v_multi_local := coalesce((new.plan_overrides->>'multi_local')::boolean, new.plan = 'completo');

  if v_multi_local then
    update locales set bloqueado_por_plan = false
      where organization_id = new.id and bloqueado_por_plan and not archivado;
    return new;
  end if;

  select id into v_local_mas_viejo
    from locales
    where organization_id = new.id and not archivado
    order by created_at asc
    limit 1;

  if v_local_mas_viejo is not null then
    update locales set bloqueado_por_plan = true
      where organization_id = new.id and id <> v_local_mas_viejo and not bloqueado_por_plan and not archivado;
    update locales set bloqueado_por_plan = false
      where organization_id = new.id and id = v_local_mas_viejo and bloqueado_por_plan;
  end if;

  return new;
end;
$$;

create or replace function public.inicializar_bloqueo_local()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org organizations%rowtype;
  v_multi_local boolean;
begin
  select * into v_org from organizations where id = new.organization_id;
  v_multi_local := coalesce((v_org.plan_overrides->>'multi_local')::boolean, v_org.plan = 'completo');

  new.bloqueado_por_plan := (not v_multi_local) and exists (
    select 1 from locales where organization_id = new.organization_id and not archivado
  );

  return new;
end;
$$;

create or replace function public.max_locales(p_org_id uuid)
returns integer
language sql
security definer
stable
set search_path = public
as $$
  select case when coalesce((o.plan_overrides->>'multi_local')::boolean, o.plan = 'completo') then 3 else 1 end
  from organizations o
  where o.id = p_org_id;
$$;

comment on function public.max_locales(uuid) is 'Cantidad maxima de locales NO archivados que puede tener la organizacion segun su plan: 3 con multi_local, 1 sin. null si la organizacion no existe.';

create or replace function public.puede_crear_local(p_org_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select (select count(*) from locales where organization_id = p_org_id and not archivado) < coalesce(public.max_locales(p_org_id), 0);
$$;

comment on function public.puede_crear_local(uuid) is 'true si a la organizacion todavia le queda cupo para un local mas (locales no archivados < max_locales). Usada por locales_insert y restaurar_local.';

alter policy locales_insert on locales
  with check (organization_id = current_org_id() and is_admin() and is_approved() and not archivado and puede_crear_local(organization_id));

create or replace function public.prevent_archivado_directo()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.archivado is distinct from old.archivado
     and coalesce(current_setting('app.bypass_archivado_check', true), '') <> 'true'
  then
    raise exception 'El estado de archivado solo se puede cambiar via archivar_local() / restaurar_local()';
  end if;

  return new;
end;
$$;

create trigger trg_prevent_archivado_directo
  before update of archivado on locales
  for each row
  execute function public.prevent_archivado_directo();

create or replace function public.archivar_local(p_local_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_local locales%rowtype;
begin
  if not (is_admin() and is_approved() and org_is_active()) then
    raise exception 'No autorizado';
  end if;

  select * into v_local from locales where id = p_local_id and organization_id = current_org_id();
  if not found then
    raise exception 'Local no encontrado';
  end if;
  if v_local.archivado then
    raise exception 'Este local ya está archivado';
  end if;

  perform 1 from organizations where id = v_local.organization_id for update;

  if not exists (
    select 1 from locales
    where organization_id = v_local.organization_id
      and id <> p_local_id
      and not archivado
      and not bloqueado_por_plan
  ) then
    raise exception 'No podés archivar el único local activo de tu organización. Creá o restaurá otro local antes de archivar este.';
  end if;

  if exists (select 1 from turnos where local_id = p_local_id and estado = 'abierto') then
    raise exception 'Este local tiene un turno abierto. Cerralo antes de archivar el local.';
  end if;

  perform set_config('app.bypass_archivado_check', 'true', true);
  update locales set archivado = true where id = p_local_id;
end;
$$;

create or replace function public.restaurar_local(p_local_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_local locales%rowtype;
  v_max integer;
begin
  if not (is_admin() and is_approved() and org_is_active()) then
    raise exception 'No autorizado';
  end if;

  select * into v_local from locales where id = p_local_id and organization_id = current_org_id();
  if not found then
    raise exception 'Local no encontrado';
  end if;
  if not v_local.archivado then
    raise exception 'Este local no está archivado';
  end if;

  perform 1 from organizations where id = v_local.organization_id for update;

  if not puede_crear_local(v_local.organization_id) then
    v_max := max_locales(v_local.organization_id);
    raise exception 'No podés restaurar este local: tu plan permite hasta % local(es) activos y ya llegaste al máximo. Archivá otro local primero.', v_max;
  end if;

  perform set_config('app.bypass_archivado_check', 'true', true);
  update locales set archivado = false, bloqueado_por_plan = false where id = p_local_id;
end;
$$;
    $mig_body$;
    insert into _mig_log values ('20260923090000', 'archivar_locales_y_limite_por_plan', 'aplicada ahora');
  else
    insert into _mig_log values ('20260923090000', 'archivar_locales_y_limite_por_plan', 'ya estaba');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260923090000', 'archivar_locales_y_limite_por_plan') on conflict (version) do nothing;

-- ======================================================================
-- 20260923100000 codigos_activacion
-- ======================================================================
do $mig$
begin
  if not (to_regclass('public.codigos_activacion') is not null) then
    execute $mig_body$
create table codigos_activacion (
  id uuid primary key default gen_random_uuid(),
  codigo text not null unique,
  nota text,
  max_usos integer not null default 1 check (max_usos >= 1),
  usos integer not null default 0 check (usos >= 0),
  expira_at timestamptz default (now() + interval '30 days'),
  revocado boolean not null default false,
  creado_por uuid references super_admins(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint codigos_activacion_usos_dentro_del_maximo check (usos <= max_usos)
);

comment on table codigos_activacion is 'Codigos de activacion para crear organizaciones nuevas. Los administra solo el super-admin (RLS); el resto del mundo solo los toca via validar_codigo_activacion() / crear_organizacion(), que son security definer.';
comment on column codigos_activacion.expira_at is 'null = no vence. Por defecto 30 dias desde que se genera.';
comment on column codigos_activacion.usos is 'Cuantas organizaciones ya se crearon con este codigo. Solo lo incrementa crear_organizacion().';

alter table organizations add column codigo_activacion_id uuid references codigos_activacion(id) on delete set null;
comment on column organizations.codigo_activacion_id is 'Codigo de activacion con el que se creo la organizacion (null para las anteriores a los codigos). Sirve para que el super-admin vea quien uso cada codigo.';

alter table codigos_activacion enable row level security;

create policy codigos_activacion_select_superadmin on codigos_activacion
  for select using (is_super_admin());
create policy codigos_activacion_insert_superadmin on codigos_activacion
  for insert with check (is_super_admin());
create policy codigos_activacion_update_superadmin on codigos_activacion
  for update using (is_super_admin()) with check (is_super_admin());

create or replace function public.normalizar_codigo_activacion(p_codigo text)
returns text
language sql
immutable
as $$
  select upper(regexp_replace(coalesce(p_codigo, ''), '[^A-Za-z0-9]', '', 'g'));
$$;

create or replace function public.motivo_codigo_activacion_invalido(p_codigo codigos_activacion)
returns text
language sql
stable
as $$
  select case
    when p_codigo.id is null then 'El código de activación no es válido.'
    when p_codigo.revocado then 'Este código de activación fue revocado.'
    when p_codigo.usos >= p_codigo.max_usos then 'Este código de activación ya fue usado.'
    when p_codigo.expira_at is not null and p_codigo.expira_at < now() then 'Este código de activación venció.'
    else null
  end;
$$;

create or replace function public.validar_codigo_activacion(p_codigo text)
returns boolean
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_codigo codigos_activacion%rowtype;
  v_motivo text;
begin
  select * into v_codigo from codigos_activacion where codigo = normalizar_codigo_activacion(p_codigo);
  v_motivo := motivo_codigo_activacion_invalido(v_codigo);
  if v_motivo is not null then
    raise exception '%', v_motivo;
  end if;
  return true;
end;
$$;

grant execute on function public.validar_codigo_activacion(text) to anon, authenticated;

drop function if exists public.crear_organizacion(text, text, text);

create or replace function public.crear_organizacion(
  p_nombre text,
  p_nombre_admin text,
  p_telefono text,
  p_codigo text
)
returns table (organization_id uuid, local_id uuid)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_local_id uuid;
  v_email text;
  v_codigo codigos_activacion%rowtype;
  v_motivo text;
begin
  if auth.uid() is null then
    raise exception 'Se requiere estar autenticado (auth.signUp) antes de crear la organizacion';
  end if;

  if exists (select 1 from usuarios where id = auth.uid()) then
    raise exception 'Este usuario ya tiene una organizacion asociada';
  end if;

  select * into v_codigo from codigos_activacion where codigo = normalizar_codigo_activacion(p_codigo) for update;
  v_motivo := motivo_codigo_activacion_invalido(v_codigo);
  if v_motivo is not null then
    raise exception '%', v_motivo;
  end if;

  select email into v_email from auth.users where id = auth.uid();

  insert into organizations (nombre, codigo_activacion_id) values (p_nombre, v_codigo.id) returning id into v_org_id;
  insert into locales (organization_id, nombre) values (v_org_id, p_nombre) returning id into v_local_id;

  insert into usuarios (id, organization_id, local_id, role, status, nombre, email, telefono)
  values (auth.uid(), v_org_id, null, 'admin', 'approved', p_nombre_admin, v_email, p_telefono);

  update codigos_activacion set usos = usos + 1 where id = v_codigo.id;

  return query select v_org_id, v_local_id;
end;
$$;

comment on function public.crear_organizacion is 'local_id del admin queda null a proposito: el admin ve todos los locales de su organizacion (usuarios.local_id, seccion 2), no esta atado a uno solo. Exige un codigo de activacion valido; lo valida y consume en la misma transaccion.';

drop policy if exists organizations_insert on organizations;

create or replace function public.prevent_bloqueo_por_plan_directo()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.bloqueado_por_plan is distinct from old.bloqueado_por_plan
     and coalesce(current_setting('app.bypass_locales_bloqueo_check', true), '') <> 'true'
  then
    raise exception 'bloqueado_por_plan lo mantiene el sistema segun el plan: no se puede cambiar a mano';
  end if;

  return new;
end;
$$;

create trigger trg_prevent_bloqueo_por_plan_directo
  before update of bloqueado_por_plan on locales
  for each row
  execute function public.prevent_bloqueo_por_plan_directo();

create or replace function public.recalcular_locales_bloqueados()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_multi_local boolean;
  v_local_mas_viejo uuid;
begin
  if new.plan is not distinct from old.plan and new.plan_overrides is not distinct from old.plan_overrides then
    return new;
  end if;

  v_multi_local := coalesce((new.plan_overrides->>'multi_local')::boolean, new.plan = 'completo');

  perform set_config('app.bypass_locales_bloqueo_check', 'true', true);

  if v_multi_local then
    update locales set bloqueado_por_plan = false
      where organization_id = new.id and bloqueado_por_plan and not archivado;
  else
    select id into v_local_mas_viejo
      from locales
      where organization_id = new.id and not archivado
      order by created_at asc
      limit 1;

    if v_local_mas_viejo is not null then
      update locales set bloqueado_por_plan = true
        where organization_id = new.id and id <> v_local_mas_viejo and not bloqueado_por_plan and not archivado;
      update locales set bloqueado_por_plan = false
        where organization_id = new.id and id = v_local_mas_viejo and bloqueado_por_plan;
    end if;
  end if;

  perform set_config('app.bypass_locales_bloqueo_check', '', true);
  return new;
end;
$$;

create or replace function public.restaurar_local(p_local_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_local locales%rowtype;
  v_max integer;
begin
  if not (is_admin() and is_approved() and org_is_active()) then
    raise exception 'No autorizado';
  end if;

  select * into v_local from locales where id = p_local_id and organization_id = current_org_id();
  if not found then
    raise exception 'Local no encontrado';
  end if;
  if not v_local.archivado then
    raise exception 'Este local no está archivado';
  end if;

  perform 1 from organizations where id = v_local.organization_id for update;

  if not puede_crear_local(v_local.organization_id) then
    v_max := max_locales(v_local.organization_id);
    raise exception 'No podés restaurar este local: tu plan permite hasta % local(es) activos y ya llegaste al máximo. Archivá otro local primero.', v_max;
  end if;

  perform set_config('app.bypass_archivado_check', 'true', true);
  perform set_config('app.bypass_locales_bloqueo_check', 'true', true);
  update locales set archivado = false, bloqueado_por_plan = false where id = p_local_id;
end;
$$;
    $mig_body$;
    insert into _mig_log values ('20260923100000', 'codigos_activacion', 'aplicada ahora');
  else
    insert into _mig_log values ('20260923100000', 'codigos_activacion', 'ya estaba');
  end if;
end
$mig$;
insert into supabase_migrations.schema_migrations (version, name) values ('20260923100000', 'codigos_activacion') on conflict (version) do nothing;

select version, nombre, accion from _mig_log order by version;
