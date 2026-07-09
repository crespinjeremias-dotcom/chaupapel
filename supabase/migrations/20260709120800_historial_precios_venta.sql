-- El precio de venta nunca se pisa (regla transversal, seccion 1 y 4): cada
-- tramo de vigencia queda registrado aca. vigente_hasta null = tramo actual.
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

-- No hay insert/update/delete directo desde el cliente: la tabla se llena
-- solo via el trigger de productos de abajo.

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
