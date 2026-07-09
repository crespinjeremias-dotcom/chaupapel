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

-- Relacion muchos a muchos producto <-> proveedor (seccion 5). Se gestiona
-- desde la pantalla de Proveedores. No hay proveedor "principal" por producto.
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
