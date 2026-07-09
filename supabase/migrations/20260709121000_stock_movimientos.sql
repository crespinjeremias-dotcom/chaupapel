-- Reposicion de stock (seccion 6): mercaderia nueva que entra. Sube stock,
-- actualiza el precio de costo de referencia del producto y queda como
-- historial de compras (base del gasto en mercaderia del cierre mensual).
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

-- Ajuste manual de stock / merma (seccion 4): cantidad con signo (+ o -).
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

-- Sin update/delete: son movimientos contables, se corrigen con un ajuste
-- nuevo en sentido contrario, no reescribiendo el historico.

-- Triggers que mantienen productos.stock_actual consistente sin depender de
-- que cada pantalla del front repita la aritmetica.
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
