-- Movimientos de la cuenta corriente de un cliente (seccion 9). monto siempre
-- positivo; el signo del efecto sobre clientes.saldo lo determina el tipo.
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

-- Sin update/delete: son movimientos contables, se corrigen con un
-- contra-movimiento, no reescribiendo el historico.

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
