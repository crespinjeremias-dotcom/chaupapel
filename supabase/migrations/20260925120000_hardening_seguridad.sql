-- Auditoria de seguridad (2026-09-25). Cada bloque cierra un hueco que se
-- reprodujo contra la base real simulando al atacante (sesion authenticated
-- con el JWT de un usuario real, dentro de una transaccion con rollback).
--
--   1. organizations: un admin podia escribirse plan_overrides y regalarse
--      features de pago (multi_local, estadisticas, email de cierre).
--   2. usuarios: un admin podia cambiarse su propio organization_id a otra
--      organizacion y quedar como admin de esa (prevent_privilege_escalation
--      salteaba todo para admins).
--   3. ventas: un empleado podia correr created_at (mantener abierta la
--      ventana de edicion de 15 min para siempre), cambiarle el usuario a la
--      venta y anular/reactivar en loop para inflar el stock.
--   4. venta_items / venta_pagos de una venta anulada se podian seguir
--      editando o borrando, y cada cambio movia stock de nuevo.
--   5. turnos: un empleado podia reabrir un turno cerrado y borrar la
--      diferencia de caja.
--   6. registrar_venta / ventas_insert aceptaban cargar una venta en un turno
--      ya cerrado.
--   7. Los triggers security definer que mueven stock y saldos (aplicar_*)
--      actuan sobre el id que les llegue: un usuario de OTRA organizacion
--      podia tocar el stock de un producto ajeno con solo conocer su UUID.
--      Ninguna policy verificaba que producto/cliente/venta/turno referenciados
--      pertenezcan al mismo local.
--   8. solicitudes_cambio_plan: se podia insertar ya "aprobada". invitaciones:
--      se podia apuntar a un local de otra organizacion, y cualquier empleado
--      podia leer los codigos de invitacion vigentes.
--   9. Higiene: codigos de invitacion con mas entropia y CSPRNG, search_path
--      fijo en 4 funciones, TRUNCATE/REFERENCES/TRIGGER que anon y
--      authenticated no necesitan, EXECUTE de funciones de trigger.

-- ============================================================================
-- 1. organizations: columnas que solo cambia el sistema
-- Para corregir a mano desde el SQL editor:
--   select set_config('app.bypass_org_sensibles_check', 'true', true);
--   update organizations set ... ;   -- misma transaccion
-- ============================================================================

create or replace function public.prevent_org_columnas_sensibles()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(current_setting('app.bypass_org_sensibles_check', true), '') = 'true'
     or auth.role() = 'service_role'
     or is_super_admin()
  then
    return new;
  end if;

  if new.id is distinct from old.id
     or new.plan_overrides is distinct from old.plan_overrides
     or new.trial_ends_at is distinct from old.trial_ends_at
     or new.codigo_activacion_id is distinct from old.codigo_activacion_id
     or new.created_at is distinct from old.created_at
  then
    raise exception 'Solo el administrador del sistema puede cambiar los overrides de plan, la prueba o el codigo de activacion de una organizacion';
  end if;

  return new;
end;
$$;

create trigger trg_prevent_org_columnas_sensibles
  before update on organizations
  for each row
  execute function public.prevent_org_columnas_sensibles();

-- ============================================================================
-- 2. usuarios: la organizacion no se cambia (ni siquiera un admin), y el local
--    tiene que ser de la misma organizacion.
-- Misma funcion que 20260925091000, con el chequeo de organization_id antes
-- del atajo para admins.
-- ============================================================================

create or replace function public.prevent_privilege_escalation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.organization_id is distinct from old.organization_id
     and coalesce(current_setting('app.bypass_privilegios_check', true), '') <> 'true'
     and auth.role() is distinct from 'service_role'
  then
    raise exception 'La organizacion de un usuario no se puede cambiar';
  end if;

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

create or replace function public.validar_local_de_usuario()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.local_id is not null
     and not exists (select 1 from locales where id = new.local_id and organization_id = new.organization_id)
  then
    raise exception 'El local no pertenece a la organizacion del usuario';
  end if;
  return new;
end;
$$;

create trigger trg_validar_local_de_usuario
  before insert or update of local_id, organization_id on usuarios
  for each row
  execute function public.validar_local_de_usuario();

-- ============================================================================
-- 3. ventas: inmutables salvo lo que la app realmente edita (total, estado,
--    anulada_por, anulada_at) y una venta anulada no se reactiva.
-- Para corregir a mano: select set_config('app.bypass_ventas_check','true',true);
-- ============================================================================

create or replace function public.proteger_ventas()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(current_setting('app.bypass_ventas_check', true), '') = 'true' then
    return new;
  end if;

  if new.organization_id is distinct from old.organization_id
     or new.local_id is distinct from old.local_id
     or new.turno_id is distinct from old.turno_id
     or new.usuario_id is distinct from old.usuario_id
     or new.cliente_id is distinct from old.cliente_id
     or new.es_fiado is distinct from old.es_fiado
     or new.fecha is distinct from old.fecha
     or new.created_at is distinct from old.created_at
  then
    raise exception 'Ese dato de una venta no se puede modificar';
  end if;

  -- aplicar_anulacion_venta() repone stock y revierte el fiado solo al pasar a
  -- 'anulada': reactivarla dejaba el stock repuesto y la venta activa.
  if old.estado = 'anulada' and new.estado is distinct from 'anulada' then
    raise exception 'Una venta anulada no se puede reactivar';
  end if;

  return new;
end;
$$;

create trigger trg_proteger_ventas
  before update on ventas
  for each row
  execute function public.proteger_ventas();

-- Items y pagos de una venta anulada: cada cambio volvia a mover stock
-- (aplicar_stock_venta_item) sobre una venta que ya lo habia repuesto.
create or replace function public.proteger_detalle_venta_anulada()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venta_id uuid := case when tg_op = 'DELETE' then old.venta_id else new.venta_id end;
begin
  if coalesce(current_setting('app.bypass_ventas_check', true), '') = 'true' then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  if exists (select 1 from ventas where id = v_venta_id and estado = 'anulada') then
    raise exception 'La venta esta anulada: no se puede modificar su detalle';
  end if;

  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

create trigger trg_proteger_items_venta_anulada
  before insert or update or delete on venta_items
  for each row
  execute function public.proteger_detalle_venta_anulada();

create trigger trg_proteger_pagos_venta_anulada
  before insert or update or delete on venta_pagos
  for each row
  execute function public.proteger_detalle_venta_anulada();

-- Una venta solo se carga en un turno abierto.
create or replace function public.validar_turno_abierto_venta()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from turnos where id = new.turno_id and estado = 'abierto') then
    raise exception 'El turno no esta abierto: no se pueden cargar ventas en el';
  end if;
  return new;
end;
$$;

create trigger trg_validar_turno_abierto_venta
  before insert on ventas
  for each row
  execute function public.validar_turno_abierto_venta();

-- ============================================================================
-- 4. turnos: un turno cerrado solo lo modifica un admin; la identidad del turno
--    no cambia nunca.
-- ============================================================================

create or replace function public.proteger_turnos()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(current_setting('app.bypass_turnos_check', true), '') = 'true' then
    return new;
  end if;

  if new.organization_id is distinct from old.organization_id
     or new.local_id is distinct from old.local_id
     or new.usuario_id is distinct from old.usuario_id
     or new.fecha_apertura is distinct from old.fecha_apertura
  then
    raise exception 'Ese dato de un turno no se puede modificar';
  end if;

  if old.estado = 'cerrado' and not is_admin() then
    raise exception 'Un turno cerrado no se puede modificar';
  end if;

  return new;
end;
$$;

create trigger trg_proteger_turnos
  before update on turnos
  for each row
  execute function public.proteger_turnos();

-- ============================================================================
-- 5. Referencias entre tablas: el producto / cliente / venta / turno al que
--    apunta una fila tiene que ser del mismo local y organizacion.
-- Los aplicar_* son security definer y actuan sobre el id que reciben.
-- TG_ARGV: pares 'columna:tabla_referenciada'.
-- ============================================================================

create or replace function public.validar_referencias_mismo_local()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  a text;
  col text;
  tabla text;
  v_id uuid;
  v_local uuid;
  v_org uuid;
begin
  foreach a in array tg_argv loop
    col := split_part(a, ':', 1);
    tabla := split_part(a, ':', 2);
    v_id := (to_jsonb(new) ->> col)::uuid;
    continue when v_id is null;

    execute format('select local_id, organization_id from public.%I where id = $1', tabla)
      into v_local, v_org using v_id;

    if v_org is distinct from new.organization_id or v_local is distinct from new.local_id then
      raise exception 'Referencia invalida: % no pertenece a este local', col using errcode = '23514';
    end if;
  end loop;

  return new;
end;
$$;

create trigger trg_refs_venta_items before insert or update of producto_id, venta_id on venta_items
  for each row execute function public.validar_referencias_mismo_local('producto_id:productos', 'venta_id:ventas');
create trigger trg_refs_venta_pagos before insert or update of venta_id on venta_pagos
  for each row execute function public.validar_referencias_mismo_local('venta_id:ventas');
create trigger trg_refs_ventas before insert or update of turno_id, cliente_id on ventas
  for each row execute function public.validar_referencias_mismo_local('turno_id:turnos', 'cliente_id:clientes');
create trigger trg_refs_cc_movimientos before insert or update of cliente_id, venta_id, turno_id on cuenta_corriente_movimientos
  for each row execute function public.validar_referencias_mismo_local('cliente_id:clientes', 'venta_id:ventas', 'turno_id:turnos');
create trigger trg_refs_ajustes_stock before insert or update of producto_id on ajustes_stock
  for each row execute function public.validar_referencias_mismo_local('producto_id:productos');
create trigger trg_refs_reposiciones before insert or update of producto_id, proveedor_id on reposiciones_stock
  for each row execute function public.validar_referencias_mismo_local('producto_id:productos', 'proveedor_id:proveedores');
create trigger trg_refs_devoluciones before insert or update of venta_id, producto_original_id, producto_nuevo_id, cliente_id on devoluciones_cambios
  for each row execute function public.validar_referencias_mismo_local('venta_id:ventas', 'producto_original_id:productos', 'producto_nuevo_id:productos', 'cliente_id:clientes');
create trigger trg_refs_reclamos before insert or update of proveedor_id, producto_id on reclamos_proveedor
  for each row execute function public.validar_referencias_mismo_local('proveedor_id:proveedores', 'producto_id:productos');
create trigger trg_refs_producto_proveedor before insert or update of producto_id, proveedor_id on producto_proveedor
  for each row execute function public.validar_referencias_mismo_local('producto_id:productos', 'proveedor_id:proveedores');
create trigger trg_refs_productos before insert or update of categoria_id on productos
  for each row execute function public.validar_referencias_mismo_local('categoria_id:categorias');

-- La purga de un local borra en cascada items/pagos de ventas que pueden estar
-- anuladas: pasa por encima de proteger_detalle_venta_anulada. Misma funcion de
-- 20260925091000 con esa bandera.
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

      perform set_config('app.bypass_ventas_check', 'true', true);
      delete from locales where id = v_id;
      perform set_config('app.bypass_ventas_check', '', true);
      v_borrados := v_borrados + 1;
    exception when others then
      raise warning 'purgar_locales_vencidos: fallo al eliminar el local %: % (%)', v_id, sqlerrm, sqlstate;
    end;
  end loop;

  return v_borrados;
end;
$$;

-- ============================================================================
-- 6. Policies: solicitudes de plan e invitaciones
-- ============================================================================

alter policy solicitudes_plan_insert on solicitudes_cambio_plan
  with check (
    organization_id = current_org_id() and is_admin() and is_approved()
    and solicitado_por = auth.uid()
    and estado = 'pendiente' and resuelta_por is null and resuelta_at is null
  );

alter policy invitaciones_insert on invitaciones
  with check (
    organization_id = current_org_id() and is_admin() and is_approved()
    and (local_id is null or exists (select 1 from locales l where l.id = local_id and l.organization_id = current_org_id()))
  );

alter policy invitaciones_update on invitaciones
  with check (
    organization_id = current_org_id() and is_admin() and is_approved()
    and (local_id is null or exists (select 1 from locales l where l.id = local_id and l.organization_id = current_org_id()))
  );

-- Un empleado no tiene motivo para ver los codigos de invitacion vigentes.
alter policy invitaciones_select on invitaciones
  using (organization_id = current_org_id() and is_admin() and is_approved());

-- ============================================================================
-- 7. Higiene
-- ============================================================================

-- 8 hex de md5(random()) = 32 bits y random() no es criptografico. 12 hex de
-- gen_random_uuid() (CSPRNG) = 48 bits. Los codigos ya emitidos siguen sirviendo.
create or replace function public.generar_codigo_invitacion()
returns text
language sql
set search_path = public
as $$
  select upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));
$$;

alter function public.set_updated_at() set search_path = public;
alter function public.normalizar_codigo_activacion(text) set search_path = public;
alter function public.motivo_codigo_activacion_invalido(codigos_activacion) set search_path = public;

-- anon no usa ninguna tabla; nadie usa TRUNCATE / REFERENCES / TRIGGER por la
-- API (y TRUNCATE ignora RLS).
revoke all on all tables in schema public from anon;
revoke truncate, references, trigger on all tables in schema public from authenticated, service_role;
alter default privileges in schema public revoke all on tables from anon;
alter default privileges for role postgres in schema public revoke all on tables from anon;
alter default privileges in schema public revoke truncate, references, trigger on tables from authenticated, service_role;
alter default privileges for role postgres in schema public revoke truncate, references, trigger on tables from authenticated, service_role;

-- Las funciones de trigger no se invocan por API ni necesitan EXECUTE de quien
-- dispara la fila (se chequea al crear el trigger).
do $$
declare
  f regprocedure;
begin
  for f in
    select p.oid::regprocedure
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.prokind = 'f'
      and p.prorettype = 'trigger'::regtype
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
  end loop;
end;
$$;
