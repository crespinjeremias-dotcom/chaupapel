-- Alta de organizacion nueva (seccion 3, autoservicio). Se llama despues de
-- que el front ya hizo supabase.auth.signUp() para el admin fundador: acA
-- solo falta crear organizations + un primer local + la fila de usuarios
-- (role=admin, status=approved). Es el UNICO camino sancionado para que
-- exista un admin (usuarios no tiene policy de insert directo, ver
-- docs/rls-design.md).
create or replace function public.crear_organizacion(
  p_nombre text,
  p_nombre_admin text,
  p_telefono text default null
)
returns table (organization_id uuid, local_id uuid)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_local_id uuid;
  v_email text;
begin
  if auth.uid() is null then
    raise exception 'Se requiere estar autenticado (auth.signUp) antes de crear la organizacion';
  end if;

  if exists (select 1 from usuarios where id = auth.uid()) then
    raise exception 'Este usuario ya tiene una organizacion asociada';
  end if;

  select email into v_email from auth.users where id = auth.uid();

  insert into organizations (nombre) values (p_nombre) returning id into v_org_id;
  insert into locales (organization_id, nombre) values (v_org_id, p_nombre) returning id into v_local_id;

  insert into usuarios (id, organization_id, local_id, role, status, nombre, email, telefono)
  values (auth.uid(), v_org_id, null, 'admin', 'approved', p_nombre_admin, v_email, p_telefono);

  return query select v_org_id, v_local_id;
end;
$$;

comment on function public.crear_organizacion is 'local_id del admin queda null a proposito: el admin ve todos los locales de su organizacion (usuarios.local_id, seccion 2), no esta atado a uno solo.';
