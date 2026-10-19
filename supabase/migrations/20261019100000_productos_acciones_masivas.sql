-- Acciones masivas sobre productos (pantalla de Productos): eliminar,
-- desactivar/reactivar y deshacer, para varios productos a la vez.
--
-- Por que funciones y no un UPDATE ... IN (...) desde el cliente:
--   * Atomicas y sin limite de largo de URL: con 500 ids un filtro IN (...)
--     pasaria de los ~16 KB que aceptan los proxies. Aca los ids viajan en el
--     cuerpo del pedido y la operacion es UN solo UPDATE: o cambian todos o no
--     cambia ninguno.
--   * Deshacer una eliminacion no se puede con una policy: productos_update
--     exige deleted_at IS NULL, o sea que un producto ya eliminado no se puede
--     volver a tocar desde el cliente. Esa regla se mantiene (la eliminacion
--     sigue siendo terminal para cualquier otro camino); restaurar_productos()
--     es la unica excepcion y esta acotada a los ultimos 15 minutos.
--
-- Las tres validan lo mismo que las policies de productos (is_admin +
-- is_approved + org_is_active + local activo) y NUNCA tocan productos de otra
-- organizacion ni de otro local que el indicado. Solo admin: un empleado recibe
-- 'No autorizado' aunque llame a la funcion a mano.

create or replace function public.eliminar_productos(p_local_id uuid, p_ids uuid[])
returns uuid[]
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ids uuid[];
begin
  if not (is_admin() and is_approved() and org_is_active()) then
    raise exception 'No autorizado';
  end if;
  if p_ids is null or coalesce(array_length(p_ids, 1), 0) = 0 then
    raise exception 'No se indicaron productos';
  end if;
  if not exists (select 1 from locales where id = p_local_id and organization_id = current_org_id()) then
    raise exception 'Local no encontrado';
  end if;
  if not local_is_active(p_local_id) then
    raise exception 'El local no esta activo';
  end if;

  -- borrado logico: la misma marca que usa la eliminacion de a uno
  with borrados as (
    update productos
       set deleted_at = now()
     where id = any(p_ids)
       and local_id = p_local_id
       and organization_id = current_org_id()
       and deleted_at is null
    returning id
  )
  select coalesce(array_agg(id), '{}') into v_ids from borrados;

  return v_ids;
end;
$$;

create or replace function public.restaurar_productos(p_local_id uuid, p_ids uuid[])
returns uuid[]
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ids uuid[];
begin
  if not (is_admin() and is_approved() and org_is_active()) then
    raise exception 'No autorizado';
  end if;
  if p_ids is null or coalesce(array_length(p_ids, 1), 0) = 0 then
    raise exception 'No se indicaron productos';
  end if;
  if not exists (select 1 from locales where id = p_local_id and organization_id = current_org_id()) then
    raise exception 'Local no encontrado';
  end if;
  if not local_is_active(p_local_id) then
    raise exception 'El local no esta activo';
  end if;

  -- Solo lo eliminado hace menos de 15 minutos (es un "deshacer", no una
  -- papelera). Un producto cuyo codigo de barras ya lo uso otro producto vivo
  -- del local se saltea (el indice unico no deja tener dos), y se informa
  -- porque no vuelve en el resultado.
  with restaurados as (
    update productos p
       set deleted_at = null
     where p.id = any(p_ids)
       and p.local_id = p_local_id
       and p.organization_id = current_org_id()
       and p.deleted_at is not null
       and p.deleted_at > now() - interval '15 minutes'
       and not exists (
         select 1 from productos o
          where o.local_id = p.local_id
            and o.codigo_barras = p.codigo_barras
            and o.deleted_at is null
            and o.id <> p.id
       )
    returning p.id
  )
  select coalesce(array_agg(id), '{}') into v_ids from restaurados;

  return v_ids;
end;
$$;

create or replace function public.establecer_activo_productos(p_local_id uuid, p_ids uuid[], p_activo boolean)
returns uuid[]
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ids uuid[];
begin
  if not (is_admin() and is_approved() and org_is_active()) then
    raise exception 'No autorizado';
  end if;
  if p_ids is null or coalesce(array_length(p_ids, 1), 0) = 0 then
    raise exception 'No se indicaron productos';
  end if;
  if p_activo is null then
    raise exception 'Falta indicar si se activan o se desactivan';
  end if;
  if not exists (select 1 from locales where id = p_local_id and organization_id = current_org_id()) then
    raise exception 'Local no encontrado';
  end if;
  if not local_is_active(p_local_id) then
    raise exception 'El local no esta activo';
  end if;

  with cambiados as (
    update productos
       set activo = p_activo
     where id = any(p_ids)
       and local_id = p_local_id
       and organization_id = current_org_id()
       and deleted_at is null
    returning id
  )
  select coalesce(array_agg(id), '{}') into v_ids from cambiados;

  return v_ids;
end;
$$;

revoke execute on function public.eliminar_productos(uuid, uuid[]) from public, anon;
grant execute on function public.eliminar_productos(uuid, uuid[]) to authenticated;
revoke execute on function public.restaurar_productos(uuid, uuid[]) from public, anon;
grant execute on function public.restaurar_productos(uuid, uuid[]) to authenticated;
revoke execute on function public.establecer_activo_productos(uuid, uuid[], boolean) from public, anon;
grant execute on function public.establecer_activo_productos(uuid, uuid[], boolean) to authenticated;
