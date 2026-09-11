-- Seccion 15: bajar de plan no revocaba nada -- confirmado que los locales
-- extra de una organizacion multi-local seguian totalmente operables
-- despues de bajar de Completo a Basico, porque el unico chequeo de
-- "necesitas multi_local" vivia en el frontend (ocultar el boton "agregar
-- local"), nunca en RLS. Este archivo agrega el campo de estado +
-- trigger + policies para que quede resuelto a nivel de base, y de paso
-- cierra un hallazgo relacionado encontrado en el camino (ver PARTE 1).

-- ============================================================================
-- PARTE 1: un admin (o super-admin) podia escribir organizations.plan
-- directo, salteando por completo la aprobacion de solicitudes_cambio_plan.
-- La policy organizations_update deja editar cualquier columna de la propia
-- organizacion, plan incluido -- nunca deberia poder tocarse asi. Mismo
-- espiritu que prevent_is_active_change (Fase 1), pero el camino legitimo
-- aca es una llamada RPC autenticada (aprobar_solicitud_plan), no la
-- service role key -- por eso el chequeo usa una bandera de sesion local a
-- la transaccion en vez de auth.role() = 'service_role'.
-- ============================================================================

create or replace function public.prevent_plan_change_directo()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.plan is distinct from old.plan
     and coalesce(current_setting('app.bypass_plan_change_check', true), '') <> 'true'
  then
    raise exception 'El plan solo se puede cambiar via aprobar_solicitud_plan()';
  end if;

  return new;
end;
$$;

create trigger trg_prevent_plan_change_directo
  before update on organizations
  for each row
  execute function public.prevent_plan_change_directo();

-- aprobar_solicitud_plan es el unico camino habilitado: prende la bandera
-- (local a la transaccion, se resetea sola) justo antes del unico UPDATE
-- que le toca a plan.
create or replace function public.aprobar_solicitud_plan(p_solicitud_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_plan text;
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

  perform set_config('app.bypass_plan_change_check', 'true', true);
  update organizations set plan = v_plan::plan_type where id = v_org_id;

  update solicitudes_cambio_plan
    set estado = 'aprobada', resuelta_por = auth.uid(), resuelta_at = now()
    where id = p_solicitud_id;
end;
$$;

-- ============================================================================
-- PARTE 2: locales.bloqueado_por_plan -- campo de estado + los dos triggers
-- que lo mantienen sincronizado, + local_is_active() como policy helper
-- (mismo patron que org_is_active(), Fase 1).
-- ============================================================================

alter table locales add column bloqueado_por_plan boolean not null default false;
comment on column locales.bloqueado_por_plan is 'Seccion 15: true cuando el local quedo por encima de lo que permite el plan contratado (sin multi_local, solo el local mas antiguo de la organizacion queda operable). Lo mantienen sincronizado trg_recalcular_locales_bloqueados y trg_inicializar_bloqueo_local -- no tocar a mano. Distinto de locales.activo, que es una pausa administrativa manual sin UI todavia y no gatea nada de esto.';

create or replace function public.local_is_active(p_local_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select coalesce((select not l.bloqueado_por_plan from locales l where l.id = p_local_id), false);
$$;

comment on function public.local_is_active(uuid) is 'true si el local no esta bloqueado por plan (seccion 15). Solo refleja locales.bloqueado_por_plan -- no compone con locales.activo (concepto aparte, ver comentario de esa columna).';

-- Recalcula el bloqueo de todos los locales de una organizacion cuando
-- cambia su plan (o un plan_overrides que afecte multi_local) -- mismo
-- criterio que tieneFeature('multi_local') en public/js/planes.js: un
-- override explicito manda, si no hay, alcanza con plan = 'completo'.
-- El local mas antiguo (por created_at) es el que sigue operable; el resto
-- se bloquea. Si vuelve a haber multi_local, se desbloquean todos -- como
-- los datos nunca se tocan, "reaparecen tal cual estaban".
--
-- security definer: esta funcion corre disparada por un UPDATE en
-- organizations que puede venir de un super-admin (aprobar_solicitud_plan),
-- que no tiene fila en usuarios y por lo tanto no pasaria locales_update por
-- RLS -- sin esto, el UPDATE interno de locales no afectaria ninguna fila.
create or replace function public.recalcular_locales_bloqueados()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_multi_local boolean;
  v_local_mas_viejo uuid;
begin
  if new.plan is not distinct from old.plan and new.plan_overrides is not distinct from old.plan_overrides then
    return new;
  end if;

  v_multi_local := coalesce((new.plan_overrides->>'multi_local')::boolean, new.plan = 'completo');

  if v_multi_local then
    update locales set bloqueado_por_plan = false
      where organization_id = new.id and bloqueado_por_plan;
    return new;
  end if;

  select id into v_local_mas_viejo
    from locales
    where organization_id = new.id
    order by created_at asc
    limit 1;

  if v_local_mas_viejo is not null then
    update locales set bloqueado_por_plan = true
      where organization_id = new.id and id <> v_local_mas_viejo and not bloqueado_por_plan;
    update locales set bloqueado_por_plan = false
      where organization_id = new.id and id = v_local_mas_viejo and bloqueado_por_plan;
  end if;

  return new;
end;
$$;

create trigger trg_recalcular_locales_bloqueados
  after update of plan, plan_overrides on organizations
  for each row
  execute function public.recalcular_locales_bloqueados();

-- Red de seguridad: locales_insert (Fase 1) nunca valido multi_local a nivel
-- RLS, solo el frontend oculta el boton "agregar local" -- mismo tipo de
-- gap que la Parte 1, pero de este quedo pendiente cerrar el lado de RLS
-- (fuera del alcance aprobado para este cambio). Mientras tanto, este
-- trigger evita que un local creado de mas nazca operable: si ya existe al
-- menos un local en la organizacion y el plan actual no llega a
-- multi_local, el nuevo nace bloqueado. El primer local de una organizacion
-- nueva nunca nace bloqueado (es el mas viejo por definicion).
create or replace function public.inicializar_bloqueo_local()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org organizations%rowtype;
  v_multi_local boolean;
begin
  select * into v_org from organizations where id = new.organization_id;
  v_multi_local := coalesce((v_org.plan_overrides->>'multi_local')::boolean, v_org.plan = 'completo');

  new.bloqueado_por_plan := (not v_multi_local) and exists (
    select 1 from locales where organization_id = new.organization_id
  );

  return new;
end;
$$;

create trigger trg_inicializar_bloqueo_local
  before insert on locales
  for each row
  execute function public.inicializar_bloqueo_local();

-- ============================================================================
-- PARTE 3: local_is_active(local_id) sumado a insert/update/delete de todas
-- las tablas que cuelgan de un local (turnos, ventas y afines, catalogo,
-- stock, cuenta corriente, cierres). Las policies de select NO se tocan a
-- proposito -- el admin conserva lectura del historico de un local
-- bloqueado (decision explicita: "conservan todos los datos"), y un
-- empleado cuyo local propio quedo bloqueado se corta antes de llegar a
-- pedir nada, del lado de la app (ver panel.html / pantallaDeEntrada en
-- auth.js), no de RLS.
--
-- Expresiones tomadas tal cual estan hoy en produccion (pg_policies), no
-- reconstruidas a mano desde el historial de migraciones -- varias de estas
-- policies fueron parchadas despues de su creacion original (admin-only en
-- productos/proveedores/reclamos, soft delete, etc.).
-- ============================================================================

alter policy ajustes_insert on ajustes_stock
  with check (((organization_id = current_org_id()) AND is_approved() AND org_is_active() AND (is_admin() OR (local_id = current_local_id()))) AND local_is_active(local_id));

alter policy categorias_insert on categorias
  with check (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active()) AND local_is_active(local_id));
alter policy categorias_update on categorias
  using (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active()) AND local_is_active(local_id))
  with check (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active()) AND local_is_active(local_id));
alter policy categorias_delete on categorias
  using (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active()) AND local_is_active(local_id));

alter policy cierres_diarios_insert on cierres_diarios
  with check (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active()) AND local_is_active(local_id));
alter policy cierres_diarios_update on cierres_diarios
  using (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active()) AND local_is_active(local_id))
  with check (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active()) AND local_is_active(local_id));

alter policy cierres_mensuales_insert on cierres_mensuales
  with check (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active()) AND local_is_active(local_id));
alter policy cierres_mensuales_update on cierres_mensuales
  using (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active()) AND local_is_active(local_id))
  with check (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active()) AND local_is_active(local_id));

alter policy clientes_insert on clientes
  with check (((organization_id = current_org_id()) AND is_approved() AND org_is_active() AND (is_admin() OR (local_id = current_local_id()))) AND local_is_active(local_id));
alter policy clientes_update on clientes
  using (((organization_id = current_org_id()) AND is_approved() AND org_is_active() AND (is_admin() OR (local_id = current_local_id()))) AND local_is_active(local_id))
  with check (((organization_id = current_org_id()) AND is_approved() AND org_is_active() AND (is_admin() OR (local_id = current_local_id()))) AND local_is_active(local_id));

alter policy cc_movimientos_insert on cuenta_corriente_movimientos
  with check (((organization_id = current_org_id()) AND is_approved() AND org_is_active() AND (is_admin() OR (local_id = current_local_id()))) AND local_is_active(local_id));

alter policy devoluciones_insert on devoluciones_cambios
  with check (((organization_id = current_org_id()) AND is_approved() AND org_is_active() AND (is_admin() OR (local_id = current_local_id()))) AND local_is_active(local_id));

alter policy producto_proveedor_insert on producto_proveedor
  with check (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active()) AND local_is_active(local_id));
alter policy producto_proveedor_delete on producto_proveedor
  using (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active()) AND local_is_active(local_id));

alter policy productos_insert on productos
  with check (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active()) AND local_is_active(local_id));
alter policy productos_update on productos
  using (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active() AND (deleted_at IS NULL)) AND local_is_active(local_id))
  with check (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active()) AND local_is_active(local_id));

alter policy proveedores_insert on proveedores
  with check (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active()) AND local_is_active(local_id));
alter policy proveedores_update on proveedores
  using (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active() AND (deleted_at IS NULL)) AND local_is_active(local_id))
  with check (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active()) AND local_is_active(local_id));

alter policy reclamos_insert on reclamos_proveedor
  with check (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active()) AND local_is_active(local_id));
alter policy reclamos_update on reclamos_proveedor
  using (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active()) AND local_is_active(local_id))
  with check (((organization_id = current_org_id()) AND is_admin() AND is_approved() AND org_is_active()) AND local_is_active(local_id));

alter policy reposiciones_insert on reposiciones_stock
  with check (((organization_id = current_org_id()) AND is_approved() AND org_is_active() AND (is_admin() OR (local_id = current_local_id()))) AND local_is_active(local_id));

alter policy turnos_insert on turnos
  with check (((organization_id = current_org_id()) AND is_approved() AND org_is_active() AND (usuario_id = auth.uid()) AND (is_admin() OR (local_id = current_local_id()))) AND local_is_active(local_id));
alter policy turnos_update on turnos
  using (((organization_id = current_org_id()) AND is_approved() AND org_is_active() AND (is_admin() OR ((local_id = current_local_id()) AND (usuario_id = auth.uid())))) AND local_is_active(local_id))
  with check (((organization_id = current_org_id()) AND is_approved() AND org_is_active() AND (is_admin() OR ((local_id = current_local_id()) AND (usuario_id = auth.uid())))) AND local_is_active(local_id));

alter policy venta_items_insert on venta_items
  with check (((organization_id = current_org_id()) AND is_approved() AND org_is_active() AND (is_admin() OR (local_id = current_local_id()))) AND local_is_active(local_id));
alter policy venta_items_update on venta_items
  using (((organization_id = current_org_id()) AND is_approved() AND org_is_active() AND (is_admin() OR ((local_id = current_local_id()) AND (EXISTS ( SELECT 1 FROM ventas v WHERE ((v.id = venta_items.venta_id) AND (v.usuario_id = auth.uid()) AND (v.created_at > (now() - '00:15:00'::interval)))))))) AND local_is_active(local_id))
  with check (((organization_id = current_org_id()) AND is_approved() AND org_is_active() AND (is_admin() OR (local_id = current_local_id()))) AND local_is_active(local_id));
alter policy venta_items_delete on venta_items
  using (((organization_id = current_org_id()) AND is_approved() AND org_is_active() AND (is_admin() OR ((local_id = current_local_id()) AND (EXISTS ( SELECT 1 FROM ventas v WHERE ((v.id = venta_items.venta_id) AND (v.usuario_id = auth.uid()) AND (v.created_at > (now() - '00:15:00'::interval)))))))) AND local_is_active(local_id));

alter policy venta_pagos_insert on venta_pagos
  with check (((organization_id = current_org_id()) AND is_approved() AND org_is_active() AND (is_admin() OR (local_id = current_local_id()))) AND local_is_active(local_id));
alter policy venta_pagos_delete on venta_pagos
  using (((organization_id = current_org_id()) AND is_approved() AND org_is_active() AND (is_admin() OR ((local_id = current_local_id()) AND (EXISTS ( SELECT 1 FROM ventas v WHERE ((v.id = venta_pagos.venta_id) AND (v.usuario_id = auth.uid()) AND (v.created_at > (now() - '00:15:00'::interval)))))))) AND local_is_active(local_id));

alter policy ventas_insert on ventas
  with check (((organization_id = current_org_id()) AND is_approved() AND org_is_active() AND (usuario_id = auth.uid()) AND (is_admin() OR (local_id = current_local_id()))) AND local_is_active(local_id));
alter policy ventas_update on ventas
  using (((organization_id = current_org_id()) AND is_approved() AND org_is_active() AND (is_admin() OR ((local_id = current_local_id()) AND (usuario_id = auth.uid()) AND (created_at > (now() - '00:15:00'::interval))))) AND local_is_active(local_id))
  with check (((organization_id = current_org_id()) AND is_approved() AND org_is_active() AND (is_admin() OR (local_id = current_local_id()))) AND local_is_active(local_id));
