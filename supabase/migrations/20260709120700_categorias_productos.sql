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
-- codigo de barras unico dentro de un local, pero solo cuando esta cargado
create unique index idx_productos_codigo_barras on productos(local_id, codigo_barras) where codigo_barras is not null;
-- busqueda por nombre con autocompletado (seccion 4)
create index idx_productos_nombre_trgm on productos using gin (nombre gin_trgm_ops);

comment on column productos.ultimo_precio_costo is 'Se completa solo con el precio_costo de la ultima reposicion de stock (trigger en reposiciones_stock). Dato de referencia rapida, no reemplaza el historial de compras.';
comment on column productos.stock_actual is 'Mantenido por triggers de reposiciones_stock, ajustes_stock y venta_items. No se escribe a mano desde el front salvo a traves de esas tablas.';

alter table categorias enable row level security;
alter table productos enable row level security;

-- Patron generico de aislamiento tenant reutilizado en el resto de las
-- tablas "de local": visible si es de tu organizacion, tu usuario esta
-- aprobado, la organizacion esta activa, y ademas sos admin (ve todos los
-- locales) o el registro es de tu propio local.
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

-- No hay delete de productos: se desactivan (activo = false) para no romper
-- las referencias historicas de ventas, reposiciones, etc.
