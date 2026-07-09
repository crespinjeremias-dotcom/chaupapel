-- Turno = caja individual de un empleado (o de la cuenta compartida, seccion 2).
-- En modo compartida no hace falta distinguir usuario_id porque todos loguean
-- con la misma cuenta; el aislamiento por usuario_id de mas abajo alcanza igual.
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

-- A diferencia del patron generico: un empleado solo ve/opera SUS PROPIOS
-- turnos (el conteo de caja y las diferencias de un turno son informacion
-- sensible sobre el desempeño de esa persona). El admin ve todos los del local.
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
