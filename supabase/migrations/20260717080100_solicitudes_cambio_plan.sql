-- Cambio de plan con aprobacion (seccion 15 y 16): el admin ya no cambia su
-- propio plan de forma instantanea (eso permitia auto-upgrade gratis, sin
-- pasar por el cobro manual). Ahora queda "pendiente" hasta que el
-- super-admin la aprueba o rechaza -- mismo espiritu que invitaciones
-- (alta de empleado: pendiente -> aprobacion), aunque con su propio enum de
-- 3 estados porque "rechazada" tiene que quedar distinguible de "pendiente".
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

-- Evita que se acumule mas de una solicitud pendiente por organizacion.
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

-- Sin policy de update para el cliente a proposito: aprobar/rechazar solo
-- via las funciones de abajo, para que el cambio real de organizations.plan
-- y el estado de la solicitud queden atomicos (mismo patron que
-- redimir_invitacion, que tampoco tiene policy de insert para usuarios).

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
