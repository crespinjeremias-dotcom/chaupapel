-- Cliente de cuenta corriente (fiado / saldo a favor, seccion 9). Se crea la
-- primera vez que se lo nombra en una venta fiada o en un cambio con saldo.
create table clientes (
  id uuid primary key default gen_random_uuid(),
  local_id uuid not null references locales(id) on delete cascade,
  organization_id uuid not null references organizations(id) on delete cascade,
  nombre text not null,
  telefono text,
  -- positivo = el cliente debe (fiado pendiente); negativo = el local le debe (saldo a favor).
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
