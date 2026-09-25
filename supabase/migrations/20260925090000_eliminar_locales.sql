-- Eliminar un local (seccion 1): paso posterior a "archivar". Un local
-- archivado se puede programar para eliminar; se conserva 30 dias (el dueno
-- puede cancelar o restaurar) y despues purgar_locales_vencidos() lo borra de
-- verdad, con todos sus datos. El cron que la ejecuta va en la migracion
-- siguiente (20260925100000), despues de probar el cascade con datos reales.
--
--   activo --archivar--> archivado --programar--> archivado + eliminar_en
--   (restaurar / cancelar_eliminacion vuelven un paso atras)

-- ============================================================================
-- PARTE 1: columnas + guarda
-- ============================================================================

alter table locales add column eliminar_en timestamptz;
alter table locales add column eliminacion_solicitada_por uuid references usuarios(id) on delete set null;

comment on column locales.eliminar_en is 'Fecha a partir de la cual purgar_locales_vencidos() borra el local de verdad (ventas, stock, historial, todo). null = sin eliminacion programada. Solo un local archivado puede tenerla. Solo cambia via programar_eliminacion_local() / cancelar_eliminacion_local() / restaurar_local() (lo protege trg_prevent_eliminar_en_directo) -- no tocar a mano.';
comment on column locales.eliminacion_solicitada_por is 'Quien programo la eliminacion (auditoria). Se copia a locales_eliminados al borrar.';

-- Un local operable nunca puede tener una eliminacion programada.
alter table locales
  add constraint locales_eliminar_en_requiere_archivado check (eliminar_en is null or archivado);

-- locales_update deja al admin escribir cualquier columna de sus locales: sin
-- guarda podria adelantar la fecha con un update directo (mismo patron que
-- prevent_archivado_directo). Para corregir a mano desde el SQL editor:
--   select set_config('app.bypass_eliminar_en_check', 'true', true);
--   update locales set eliminar_en = ... ;   -- misma transaccion
create or replace function public.prevent_eliminar_en_directo()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (new.eliminar_en is distinct from old.eliminar_en
      or new.eliminacion_solicitada_por is distinct from old.eliminacion_solicitada_por)
     and coalesce(current_setting('app.bypass_eliminar_en_check', true), '') <> 'true'
  then
    raise exception 'La eliminacion de un local solo se puede cambiar via programar_eliminacion_local() / cancelar_eliminacion_local()';
  end if;

  return new;
end;
$$;

create trigger trg_prevent_eliminar_en_directo
  before update of eliminar_en, eliminacion_solicitada_por on locales
  for each row
  execute function public.prevent_eliminar_en_directo();

-- ============================================================================
-- PARTE 2: registro de locales eliminados (auditoria)
-- Sin FK a locales (la fila ya no existe). Solo las escribe purgar_locales_vencidos().
-- ============================================================================

create table locales_eliminados (
  id uuid primary key default gen_random_uuid(),
  local_id uuid not null,
  organization_id uuid not null references organizations(id) on delete cascade,
  nombre text not null,
  solicitado_por uuid references usuarios(id) on delete set null,
  eliminar_en timestamptz not null,
  eliminado_en timestamptz not null default now(),
  empleados_reasignados integer not null default 0,
  resumen jsonb not null default '{}'::jsonb
);

create index idx_locales_eliminados_organization on locales_eliminados(organization_id);

comment on table locales_eliminados is 'Registro de auditoria: un local que purgar_locales_vencidos() borro definitivamente. resumen = cantidad de ventas/productos/clientes que tenia. Solo lectura para el admin de la organizacion; las escribe unicamente la funcion de purga.';

alter table locales_eliminados enable row level security;

create policy locales_eliminados_select on locales_eliminados
  for select
  using (organization_id = current_org_id() and is_admin() and is_approved());

-- Sin policies de insert/update/delete: el cliente no puede escribir aca.

-- ============================================================================
-- PARTE 3: programar / cancelar la eliminacion
-- ============================================================================

create or replace function public.programar_eliminacion_local(p_local_id uuid, p_nombre_confirmacion text)
returns timestamptz
language plpgsql
security definer
set search_path = public
as $$
declare
  v_local locales%rowtype;
  v_eliminar_en timestamptz;
begin
  if not (is_admin() and is_approved() and org_is_active()) then
    raise exception 'No autorizado';
  end if;

  select * into v_local from locales where id = p_local_id and organization_id = current_org_id();
  if not found then
    raise exception 'Local no encontrado';
  end if;
  if not v_local.archivado then
    raise exception 'Solo se puede eliminar un local archivado. Archivalo primero.';
  end if;
  if v_local.eliminar_en is not null then
    raise exception 'Este local ya tiene una eliminación programada para el %.', to_char(v_local.eliminar_en at time zone 'America/Argentina/Buenos_Aires', 'DD/MM/YYYY');
  end if;

  -- La confirmacion fuerte (escribir el nombre) se valida aca tambien, no solo
  -- en el frontend.
  if btrim(coalesce(p_nombre_confirmacion, '')) <> btrim(v_local.nombre) then
    raise exception 'El nombre ingresado no coincide con el del local.';
  end if;

  perform 1 from organizations where id = v_local.organization_id for update;

  -- Mismo criterio que archivar_local(): la organizacion tiene que conservar al
  -- menos un local operable. Un archivado ya no cuenta, asi que hoy esto se
  -- cumple siempre; se re-chequea por si cambia como se llega a "archivado".
  if not exists (
    select 1 from locales
    where organization_id = v_local.organization_id
      and id <> p_local_id
      and not archivado
      and not bloqueado_por_plan
  ) then
    raise exception 'No podés eliminar el local si es lo único que le queda a tu organización. Creá o restaurá otro local antes.';
  end if;

  v_eliminar_en := now() + interval '30 days';

  perform set_config('app.bypass_eliminar_en_check', 'true', true);
  update locales
    set eliminar_en = v_eliminar_en, eliminacion_solicitada_por = auth.uid()
    where id = p_local_id;

  return v_eliminar_en;
end;
$$;

create or replace function public.cancelar_eliminacion_local(p_local_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_local locales%rowtype;
begin
  if not (is_admin() and is_approved() and org_is_active()) then
    raise exception 'No autorizado';
  end if;

  -- for update: si justo esta corriendo la purga sobre este local, espera y
  -- despues ve que ya no existe (o que la cancelacion llego primero y la purga
  -- lo salta al revalidar).
  select * into v_local from locales where id = p_local_id and organization_id = current_org_id() for update;
  if not found then
    raise exception 'Local no encontrado';
  end if;
  if v_local.eliminar_en is null then
    raise exception 'Este local no tiene una eliminación programada.';
  end if;

  perform set_config('app.bypass_eliminar_en_check', 'true', true);
  update locales set eliminar_en = null, eliminacion_solicitada_por = null where id = p_local_id;
end;
$$;

-- Restaurar un local con eliminacion programada tambien la cancela. Misma
-- funcion de 20260923100000, con eliminar_en limpio en el mismo update (el
-- check locales_eliminar_en_requiere_archivado lo exige).
create or replace function public.restaurar_local(p_local_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_local locales%rowtype;
  v_max integer;
begin
  if not (is_admin() and is_approved() and org_is_active()) then
    raise exception 'No autorizado';
  end if;

  select * into v_local from locales where id = p_local_id and organization_id = current_org_id() for update;
  if not found then
    raise exception 'Local no encontrado';
  end if;
  if not v_local.archivado then
    raise exception 'Este local no está archivado';
  end if;

  perform 1 from organizations where id = v_local.organization_id for update;

  -- Restaurar vuelve a consumir cupo del plan.
  if not puede_crear_local(v_local.organization_id) then
    v_max := max_locales(v_local.organization_id);
    raise exception 'No podés restaurar este local: tu plan permite hasta % local(es) activos y ya llegaste al máximo. Archivá otro local primero.', v_max;
  end if;

  perform set_config('app.bypass_archivado_check', 'true', true);
  perform set_config('app.bypass_locales_bloqueo_check', 'true', true);
  perform set_config('app.bypass_eliminar_en_check', 'true', true);
  -- Con el cupo verificado, el local vuelve operable: puede haber quedado con
  -- bloqueado_por_plan = true de antes de archivarse (los triggers de bloqueo
  -- ignoran a los archivados) y ya no corresponde.
  update locales
    set archivado = false, bloqueado_por_plan = false, eliminar_en = null, eliminacion_solicitada_por = null
    where id = p_local_id;
end;
$$;

-- ============================================================================
-- PARTE 4: purga
-- Borra los locales archivados cuya fecha vencio. Un local a la vez, cada uno
-- en su propio bloque: si uno falla, se descarta solo ese (incluido el
-- registro de auditoria y el pase de empleados a pending) y sigue con el
-- resto. Devuelve cuantos borro.
-- ============================================================================

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

      update usuarios
        set local_id = null,
            status = case when role = 'empleado' and status = 'approved' then 'pending'::user_status_type else status end
        where local_id = v_id;

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

-- Las funciones se crean con EXECUTE para PUBLIC (y Supabase agrega anon /
-- authenticated): la purga solo la corre el cron (postgres) o service_role.
revoke execute on function public.purgar_locales_vencidos() from public, anon, authenticated;
