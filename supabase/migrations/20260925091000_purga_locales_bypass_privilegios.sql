-- Fix de 20260925090000, detectado al probar el cascade con datos reales:
-- purgar_locales_vencidos() corre desde pg_cron, sin sesion de usuario, y
-- prevent_privilege_escalation (trigger before update en usuarios, Fase 1)
-- rechaza cualquier cambio de status/local_id cuando is_admin() es false -- o
-- sea, abortaba el pase de empleados a pending.
--
-- Mismo patron que app.bypass_archivado_check y compania: una bandera de sesion
-- local a la transaccion que solo prende la funcion de purga, justo alrededor
-- de ese update. Desde el cliente no se puede setear (no hay ninguna funcion
-- expuesta que lo permita).

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

  if coalesce(current_setting('app.bypass_privilegios_check', true), '') = 'true' then
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

create or replace function public.purgar_locales_vencidos()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_local locales%rowtype;
  v_borrados integer := 0;
  v_empleados integer;
  v_resumen jsonb;
begin
  for v_id in
    select id from locales
    where archivado and eliminar_en is not null and eliminar_en <= now()
    order by eliminar_en
  loop
    begin
      -- Revalida con el local bloqueado: entre el listado y ahora el dueno pudo
      -- cancelar o restaurar.
      select * into v_local from locales where id = v_id for update;
      if not found
         or not v_local.archivado
         or v_local.eliminar_en is null
         or v_local.eliminar_en > now()
      then
        continue;
      end if;

      perform 1 from organizations where id = v_local.organization_id for update;

      if not exists (
        select 1 from locales
        where organization_id = v_local.organization_id
          and id <> v_id
          and not archivado
          and not bloqueado_por_plan
      ) then
        raise warning 'purgar_locales_vencidos: no se elimina el local % (%): es lo unico operable que le queda a su organizacion', v_id, v_local.nombre;
        continue;
      end if;

      -- usuarios.local_id es "on delete set null", pero un empleado approved
      -- sin local viola usuarios_empleado_approved_requiere_local: los
      -- approved vuelven a pending para que el admin los reasigne.
      select count(*) into v_empleados from usuarios where local_id = v_id and role = 'empleado' and status = 'approved';

      perform set_config('app.bypass_privilegios_check', 'true', true);
      update usuarios
        set local_id = null,
            status = case when role = 'empleado' and status = 'approved' then 'pending'::user_status_type else status end
        where local_id = v_id;
      perform set_config('app.bypass_privilegios_check', '', true);

      select jsonb_build_object(
        'ventas', (select count(*) from ventas where local_id = v_id),
        'productos', (select count(*) from productos where local_id = v_id),
        'clientes', (select count(*) from clientes where local_id = v_id)
      ) into v_resumen;

      insert into locales_eliminados (local_id, organization_id, nombre, solicitado_por, eliminar_en, empleados_reasignados, resumen)
      values (v_id, v_local.organization_id, v_local.nombre, v_local.eliminacion_solicitada_por, v_local.eliminar_en, v_empleados, v_resumen);

      delete from locales where id = v_id;
      v_borrados := v_borrados + 1;
    exception when others then
      raise warning 'purgar_locales_vencidos: fallo al eliminar el local %: % (%)', v_id, sqlerrm, sqlstate;
    end;
  end loop;

  return v_borrados;
end;
$$;

comment on function public.purgar_locales_vencidos() is 'Borra definitivamente los locales archivados con eliminar_en vencido. La ejecuta pg_cron (migracion 20260925100000); no es invocable desde el cliente.';

-- create or replace conserva los grants, pero por las dudas:
revoke execute on function public.purgar_locales_vencidos() from public, anon, authenticated;
