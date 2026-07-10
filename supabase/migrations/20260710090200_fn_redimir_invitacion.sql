-- Alta de empleado via codigo de invitacion (seccion 3). Se llama despues de
-- que el front ya hizo supabase.auth.signUp() para el empleado: valida el
-- codigo contra la tabla invitaciones (a la que el empleado no tiene acceso
-- via RLS normal, porque todavia no tiene fila en usuarios) y crea la fila
-- de usuarios en estado pending, con organization_id/local_id que salen de
-- la invitacion, nunca de lo que mande el cliente.
create or replace function public.redimir_invitacion(
  p_codigo text,
  p_nombre text,
  p_telefono text default null
)
returns table (organization_nombre text, local_nombre text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_invitacion invitaciones%rowtype;
  v_email text;
  v_local_id uuid;
  v_locales_count int;
begin
  if auth.uid() is null then
    raise exception 'Se requiere estar autenticado (auth.signUp) antes de redimir la invitacion';
  end if;

  if exists (select 1 from usuarios where id = auth.uid()) then
    raise exception 'Este usuario ya tiene una organizacion asociada';
  end if;

  select * into v_invitacion
    from invitaciones
    where codigo = upper(trim(p_codigo))
      and usado_por is null
      and (expira_at is null or expira_at > now())
    for update;

  if not found then
    raise exception 'Codigo de invitacion invalido, vencido o ya utilizado';
  end if;

  select email into v_email from auth.users where id = auth.uid();

  -- La invitacion puede o no traer un local especifico (seccion 3 solo
  -- habla de asociar a la organizacion). Si no trae uno y la organizacion
  -- tiene un unico local, se lo asignamos directo. Si tiene varios, queda
  -- sin local hasta que el admin lo elija al aprobar (constraint
  -- usuarios_empleado_approved_requiere_local impide aprobarlo sin eso).
  v_local_id := v_invitacion.local_id;
  if v_local_id is null then
    select count(*) into v_locales_count from locales where organization_id = v_invitacion.organization_id;
    if v_locales_count = 1 then
      select id into v_local_id from locales where organization_id = v_invitacion.organization_id;
    end if;
  end if;

  insert into usuarios (id, organization_id, local_id, role, status, nombre, email, telefono)
  values (auth.uid(), v_invitacion.organization_id, v_local_id, 'empleado', 'pending', p_nombre, v_email, p_telefono);

  update invitaciones set usado_por = auth.uid(), usado_at = now() where id = v_invitacion.id;

  return query
    select o.nombre, l.nombre
    from organizations o
    left join locales l on l.id = v_local_id
    where o.id = v_invitacion.organization_id;
end;
$$;
