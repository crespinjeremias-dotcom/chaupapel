-- Codigo de invitacion que el admin genera para que un empleado se autoregistre
-- y quede automaticamente asociado a la organizacion/local correctos (seccion 3).
create table invitaciones (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  local_id uuid references locales(id) on delete cascade,
  codigo text not null unique,
  creado_por uuid not null references usuarios(id),
  usado_por uuid references usuarios(id),
  usado_at timestamptz,
  expira_at timestamptz,
  created_at timestamptz not null default now()
);

create index idx_invitaciones_organization on invitaciones(organization_id);

alter table invitaciones enable row level security;

create policy invitaciones_select on invitaciones
  for select
  using (organization_id = current_org_id() and is_approved());

create policy invitaciones_insert on invitaciones
  for insert
  with check (organization_id = current_org_id() and is_admin() and is_approved());

create policy invitaciones_update on invitaciones
  for update
  using (organization_id = current_org_id() and is_admin() and is_approved())
  with check (organization_id = current_org_id() and is_admin() and is_approved());

create policy invitaciones_delete on invitaciones
  for delete
  using (organization_id = current_org_id() and is_admin() and is_approved());

comment on table invitaciones is 'La validacion del codigo por parte de un empleado sin sesion "de organizacion" todavia se hace via una funcion security definer (redimir_invitacion, a implementar en Fase 2), no via estas policies.';
