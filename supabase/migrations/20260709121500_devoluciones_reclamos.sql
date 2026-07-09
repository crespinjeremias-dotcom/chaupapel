-- Devolucion o cambio de producto por parte de un cliente (seccion 8). Solo
-- por motivo real de producto (no hay devolucion por arrepentimiento).
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

-- Local devuelve mercaderia a un proveedor (seccion 5 y 8). producto_id
-- nullable porque puede tratarse de "el lote completo" sin discriminar item.
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

-- El estado (pendiente -> repuesto) lo cambia cualquiera del local, admin o no.
create policy reclamos_update on reclamos_proveedor
  for update
  using (organization_id = current_org_id() and is_approved() and org_is_active()
         and (is_admin() or local_id = current_local_id()))
  with check (organization_id = current_org_id() and is_approved() and org_is_active()
              and (is_admin() or local_id = current_local_id()));

-- Triggers -------------------------------------------------------------
-- Producto devuelto por el cliente: NO se repone (queda descartado, seccion 8),
-- ya estaba descontado desde la venta original. Solo el producto nuevo de un
-- cambio resta stock, porque es mercaderia adicional que sale del local.
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

-- Reclamo a proveedor: el stock devuelto sale del local (no se vende mas).
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
