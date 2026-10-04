-- Borrado inmediato de locales de prueba, solo para el super-admin (panel de
-- super-admin, seccion Limpieza).
-- El flujo del admin de cada organizacion NO cambia: archivar -> programar
-- eliminacion a 30 dias -> purgar_locales_vencidos() (cron). Esta funcion es
-- el atajo del super-admin para locales de organizaciones de prueba: hace lo
-- mismo que la purga (pasa los empleados del local a "pendientes", deja el
-- registro de auditoria en locales_eliminados y borra el local en cascada)
-- pero sin esperar ni exigir que el local este archivado.
-- Protecciones: solo is_super_admin(); no se puede usar sobre organizaciones con
-- cobro_habilitado o con cobros registrados (son clientes reales); y, igual que
-- la purga, no deja a la organizacion sin ningun local operable (para eso
-- esta eliminar_organizacion_de_prueba()).

-- El super-admin no tiene policy de select sobre locales (RLS solo deja ver los
-- de la propia organizacion), asi que el listado del panel va por esta funcion
-- en vez de abrir una policy nueva sobre una tabla que usa todo el sistema.
create or replace function public.listar_locales_para_limpieza()
returns table (
  local_id uuid,
  local_nombre text,
  organization_id uuid,
  organizacion_nombre text,
  archivado boolean,
  eliminar_en timestamptz,
  cobro_habilitado boolean,
  tiene_cobros boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  if not is_super_admin() then
    raise exception 'No autorizado';
  end if;

  return query
    select l.id, l.nombre, l.organization_id, o.nombre, l.archivado, l.eliminar_en, o.cobro_habilitado,
           exists(select 1 from cobros c where c.organization_id = l.organization_id)
    from locales l
    join organizations o on o.id = l.organization_id
    order by o.nombre, l.nombre, l.created_at;
end;
$$;

create or replace function public.eliminar_local_ahora(p_local_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_local locales%rowtype;
  v_cobro_habilitado boolean;
  v_empleados integer;
  v_resumen jsonb;
begin
  if not is_super_admin() then
    raise exception 'No autorizado';
  end if;

  select * into v_local from locales where id = p_local_id for update;
  if not found then
    raise exception 'Local no encontrado';
  end if;

  perform 1 from organizations where id = v_local.organization_id for update;

  select cobro_habilitado into v_cobro_habilitado from organizations where id = v_local.organization_id;
  if v_cobro_habilitado or exists(select 1 from cobros where organization_id = v_local.organization_id) then
    raise exception 'La organizacion de este local tiene el cobro habilitado o ya tiene cobros registrados: no se puede borrar con esta funcion';
  end if;

  if not exists (
    select 1 from locales
    where organization_id = v_local.organization_id
      and id <> p_local_id
      and not archivado
      and not bloqueado_por_plan
  ) then
    raise exception 'Es el unico local operable de su organizacion. Para borrarlo, borra la organizacion entera desde Limpieza de organizaciones';
  end if;

  select count(*) into v_empleados from usuarios where local_id = p_local_id and role = 'empleado' and status = 'approved';

  perform set_config('app.bypass_privilegios_check', 'true', true);
  update usuarios
    set local_id = null,
        status = case when role = 'empleado' and status = 'approved' then 'pending'::user_status_type else status end
    where local_id = p_local_id;
  perform set_config('app.bypass_privilegios_check', '', true);

  select jsonb_build_object(
    'ventas', (select count(*) from ventas where local_id = p_local_id),
    'productos', (select count(*) from productos where local_id = p_local_id),
    'clientes', (select count(*) from clientes where local_id = p_local_id),
    'origen', 'super_admin'
  ) into v_resumen;

  -- solicitado_por queda null: el super-admin no tiene fila en usuarios.
  insert into locales_eliminados (local_id, organization_id, nombre, solicitado_por, eliminar_en, empleados_reasignados, resumen)
  values (p_local_id, v_local.organization_id, v_local.nombre, null, now(), v_empleados, v_resumen);

  perform set_config('app.bypass_ventas_check', 'true', true);
  delete from locales where id = p_local_id;
  perform set_config('app.bypass_ventas_check', '', true);

  return jsonb_build_object('nombre', v_local.nombre, 'empleados_reasignados', v_empleados, 'resumen', v_resumen);
end;
$$;

revoke execute on function public.listar_locales_para_limpieza() from public, anon;
grant execute on function public.listar_locales_para_limpieza() to authenticated;
revoke execute on function public.eliminar_local_ahora(uuid) from public, anon;
grant execute on function public.eliminar_local_ahora(uuid) to authenticated;
