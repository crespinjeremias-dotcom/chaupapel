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

-- Item de venta: precio_unitario queda CONGELADO al momento de la venta,
-- independiente de que despues cambie productos.precio_venta_actual.
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

-- Metodo(s) de pago de una venta no fiada: hasta 2 filas (ej: parte efectivo,
-- parte transferencia). Una venta fiada no tiene filas aca (seccion 7).
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

-- Ventana de edicion de 10-15 min (seccion 7): un empleado solo puede tocar
-- su venta reciente; pasado ese margen, o para cualquier venta ajena, solo
-- el admin. Se usa 15 min (limite superior del rango) como tope en la base;
-- el front puede ser mas estricto y avisar a los 10.
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

-- update/delete de items reutiliza la misma ventana que su venta: se valida
-- por join dado que venta_items no tiene created_at de la venta original.
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

-- Triggers de stock ---------------------------------------------------
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

-- Anulacion de venta: repone el stock de todos sus items. La reversion del
-- eventual movimiento de cuenta corriente (si era fiada) queda a definir en
-- el diseño del modulo de Fiado (Fase 6): puede haber pagos parciales ya
-- registrados sobre ese fiado, y no es un caso puramente mecanico.
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
