-- RLS de las 3 tablas fundacionales: organizations, locales, usuarios.

alter table organizations enable row level security;
alter table locales enable row level security;
alter table usuarios enable row level security;

-- ORGANIZATIONS ---------------------------------------------------------
-- Sin condicion de org_is_active/is_approved: el propio frontend necesita
-- poder leer is_active para mostrar la pantalla de "cuenta suspendida".
create policy organizations_select on organizations
  for select
  using (id = current_org_id());

-- Alta de organizacion nueva (auto-registro, seccion 3): cualquier usuario
-- autenticado puede crear la fila de organizacion; el alta del usuario admin
-- asociado se hace en el mismo paso (ver policy de insert en usuarios).
create policy organizations_insert on organizations
  for insert
  with check (auth.uid() is not null);

create policy organizations_update on organizations
  for update
  using (id = current_org_id() and is_admin())
  with check (id = current_org_id() and is_admin());

-- LOCALES -----------------------------------------------------------------
create policy locales_select on locales
  for select
  using (organization_id = current_org_id() and is_approved());

create policy locales_insert on locales
  for insert
  with check (organization_id = current_org_id() and is_admin() and is_approved());

create policy locales_update on locales
  for update
  using (organization_id = current_org_id() and is_admin() and is_approved())
  with check (organization_id = current_org_id() and is_admin() and is_approved());

-- USUARIOS ------------------------------------------------------------------
-- Cada usuario siempre puede ver su propia fila (para poder consultar su
-- status=pending antes de estar aprobado); el admin ve todas las de su org.
create policy usuarios_select on usuarios
  for select
  using (id = auth.uid() or (organization_id = current_org_id() and is_admin()));

-- No hay policy de insert para usuarios: no se permite insert directo desde
-- el cliente. Una policy que solo chequee "role=empleado, status=pending"
-- no alcanza a validar que el organization_id/local_id declarados
-- correspondan a una invitacion real (esa info vive en la tabla
-- invitaciones, atada al codigo, no en la fila que se esta insertando) —
-- dejar pasar cualquier organization_id permitiria generar altas pending
-- "fantasma" en organizaciones ajenas. Tanto el alta del admin fundador de
-- una organizacion nueva como el alta de un empleado via codigo de
-- invitacion se hacen con funciones security definer (crear_organizacion /
-- redimir_invitacion, Fase 2) que validan lo que corresponda y bypasean RLS.

-- El propio usuario puede tocar datos no sensibles de su fila; el admin
-- puede tocar cualquier fila de su organizacion (aprobar, reasignar local,
-- etc). El trigger prevent_privilege_escalation bloquea que un no-admin
-- cambie role/status/organization_id en su propia fila.
create policy usuarios_update_self on usuarios
  for update
  using (id = auth.uid())
  with check (id = auth.uid());

create policy usuarios_update_admin on usuarios
  for update
  using (organization_id = current_org_id() and is_admin())
  with check (organization_id = current_org_id() and is_admin());

-- Trigger anti-escalada de privilegios ---------------------------------
-- Refuerza en la base lo que ya deberia impedir el front: un usuario sin
-- rol admin no puede cambiarse a si mismo role/status/organization_id/local_id.
create or replace function public.prevent_privilege_escalation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if is_admin() then
    return new;
  end if;

  if new.role is distinct from old.role
     or new.status is distinct from old.status
     or new.organization_id is distinct from old.organization_id
     or new.local_id is distinct from old.local_id then
    raise exception 'No autorizado para modificar role, status, organization_id o local_id';
  end if;

  return new;
end;
$$;

create trigger trg_prevent_privilege_escalation
  before update on usuarios
  for each row
  execute function public.prevent_privilege_escalation();
