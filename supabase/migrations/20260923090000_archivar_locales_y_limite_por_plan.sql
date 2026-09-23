-- Dos cambios relacionados sobre locales (seccion 1 y 15):
--   1. "Archivar" un local: oculto, no operable, datos intactos, reversible.
--   2. Limite de locales por plan, validado en el INSERT (locales_insert).
-- Van juntos porque el cupo del limite se cuenta sobre locales NO archivados:
-- archivar libera cupo, restaurar lo vuelve a consumir.

-- ============================================================================
-- PARTE 1: locales.archivado + local_is_active() lo contempla
-- ============================================================================

alter table locales add column archivado boolean not null default false;
comment on column locales.archivado is 'Local oculto y no operable, con todos sus datos (ventas, stock, historial) intactos. Reversible. Solo cambia via archivar_local() / restaurar_local() (lo protege trg_prevent_archivado_directo) -- no tocar a mano. Distinto de bloqueado_por_plan (lo decide el plan, no el dueno) y de activo (pausa administrativa sin UI, no gatea nada).';

-- local_is_active() ya esta en las policies de insert/update/delete de todas
-- las tablas que cuelgan de un local (migracion 20260911200000): con esto,
-- un local archivado queda no operable en todas ellas sin tocar ninguna.
create or replace function public.local_is_active(p_local_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select coalesce((select not l.bloqueado_por_plan and not l.archivado from locales l where l.id = p_local_id), false);
$$;

comment on function public.local_is_active(uuid) is 'true si el local es operable: ni bloqueado por plan (seccion 15) ni archivado. No compone con locales.activo (concepto aparte, ver comentario de esa columna).';

-- ============================================================================
-- PARTE 2: registrar_venta no validaba local_is_active()
-- Hallazgo: registrar_venta es security definer, o sea bypasea RLS, y
-- reimplementa a mano las condiciones de ventas_insert -- pero copio las
-- condiciones ANTERIORES a local_is_active(). Resultado: un local bloqueado
-- por plan (y ahora uno archivado) seguia pudiendo registrar ventas via la
-- RPC. Misma funcion que 20260912093000, con el chequeo agregado.
-- ============================================================================

create or replace function public.registrar_venta(
  p_turno_id uuid,
  p_local_id uuid,
  p_organization_id uuid,
  p_items jsonb,      -- [{ productoId, cantidad, precioUnitario }]
  p_es_fiado boolean,
  p_cliente_id uuid,
  p_pagos jsonb        -- [{ metodo, monto }], ignorado si p_es_fiado
)
returns ventas
language plpgsql
security definer
set search_path = public
as $$
declare
  v_usuario_id uuid := auth.uid();
  v_total numeric;
  v_venta ventas%rowtype;
  v_item jsonb;
  v_pago jsonb;
begin
  -- security definer bypasea RLS -- hay que reimplementar a mano las mismas
  -- condiciones que exigia la policy ventas_insert.
  if not (
    is_approved() and org_is_active() and p_organization_id = current_org_id()
    and (is_admin() or p_local_id = current_local_id())
    and local_is_active(p_local_id)
  ) then
    raise exception 'No autorizado';
  end if;

  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'La venta necesita al menos un item';
  end if;

  select coalesce(sum((it->>'cantidad')::numeric * (it->>'precioUnitario')::numeric), 0)
    into v_total
    from jsonb_array_elements(p_items) it;

  insert into ventas (local_id, organization_id, turno_id, usuario_id, cliente_id, es_fiado, total)
  values (
    p_local_id,
    p_organization_id,
    p_turno_id,
    v_usuario_id,
    case when p_es_fiado then p_cliente_id else null end,
    p_es_fiado,
    v_total
  )
  returning * into v_venta;

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    insert into venta_items (venta_id, producto_id, local_id, organization_id, cantidad, precio_unitario)
    values (
      v_venta.id,
      (v_item->>'productoId')::uuid,
      p_local_id,
      p_organization_id,
      (v_item->>'cantidad')::numeric,
      (v_item->>'precioUnitario')::numeric
    );
  end loop;

  if p_es_fiado then
    insert into cuenta_corriente_movimientos (cliente_id, local_id, organization_id, tipo, monto, venta_id, usuario_id)
    values (p_cliente_id, p_local_id, p_organization_id, 'fiado_nuevo', v_total, v_venta.id, v_usuario_id);
  else
    for v_pago in select * from jsonb_array_elements(p_pagos)
    loop
      insert into venta_pagos (venta_id, local_id, organization_id, metodo, monto)
      values (
        v_venta.id,
        p_local_id,
        p_organization_id,
        (v_pago->>'metodo')::metodo_pago_type,
        (v_pago->>'monto')::numeric
      );
    end loop;
  end if;

  return v_venta;
end;
$$;

-- ============================================================================
-- PARTE 3: los triggers de bloqueo por plan ignoran los locales archivados
-- Sin esto, el "local mas viejo" que queda operable al bajar de plan podria
-- ser uno archivado, y la organizacion se quedaria sin ningun local operable.
-- ============================================================================

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
      where organization_id = new.id and bloqueado_por_plan and not archivado;
    return new;
  end if;

  select id into v_local_mas_viejo
    from locales
    where organization_id = new.id and not archivado
    order by created_at asc
    limit 1;

  if v_local_mas_viejo is not null then
    update locales set bloqueado_por_plan = true
      where organization_id = new.id and id <> v_local_mas_viejo and not bloqueado_por_plan and not archivado;
    update locales set bloqueado_por_plan = false
      where organization_id = new.id and id = v_local_mas_viejo and bloqueado_por_plan;
  end if;

  return new;
end;
$$;

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
    select 1 from locales where organization_id = new.organization_id and not archivado
  );

  return new;
end;
$$;

-- ============================================================================
-- PARTE 4: limite de locales por plan, validado en locales_insert
-- Con multi_local (Plan Completo, o plan_overrides.multi_local = true): hasta
-- 3 locales (el principal + 2 adicionales). Sin multi_local: 1. Mismo criterio
-- de multi_local que recalcular_locales_bloqueados / tieneFeature() en
-- public/js/planes.js -- si se cambia el 3, cambiarlo tambien en maxLocales()
-- de ese archivo (solo para el mensaje/boton del frontend; la unica barrera
-- real es esta).
-- ============================================================================

create or replace function public.max_locales(p_org_id uuid)
returns integer
language sql
security definer
stable
set search_path = public
as $$
  select case when coalesce((o.plan_overrides->>'multi_local')::boolean, o.plan = 'completo') then 3 else 1 end
  from organizations o
  where o.id = p_org_id;
$$;

comment on function public.max_locales(uuid) is 'Cantidad maxima de locales NO archivados que puede tener la organizacion segun su plan: 3 con multi_local, 1 sin. null si la organizacion no existe.';

create or replace function public.puede_crear_local(p_org_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select (select count(*) from locales where organization_id = p_org_id and not archivado) < coalesce(public.max_locales(p_org_id), 0);
$$;

comment on function public.puede_crear_local(uuid) is 'true si a la organizacion todavia le queda cupo para un local mas (locales no archivados < max_locales). Usada por locales_insert y restaurar_local.';

-- "and not archivado": sin esto se podia insertar un local ya archivado y
-- saltear el limite (los archivados no cuentan para el cupo).
alter policy locales_insert on locales
  with check (organization_id = current_org_id() and is_admin() and is_approved() and not archivado and puede_crear_local(organization_id));

-- ============================================================================
-- PARTE 5: archivar_local() / restaurar_local()
-- locales_update deja al admin escribir cualquier columna de sus locales, asi
-- que sin guarda podria saltearse la regla del ultimo local activo con un
-- update directo -- mismo patron que prevent_plan_change_directo.
-- ============================================================================

create or replace function public.prevent_archivado_directo()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.archivado is distinct from old.archivado
     and coalesce(current_setting('app.bypass_archivado_check', true), '') <> 'true'
  then
    raise exception 'El estado de archivado solo se puede cambiar via archivar_local() / restaurar_local()';
  end if;

  return new;
end;
$$;

create trigger trg_prevent_archivado_directo
  before update of archivado on locales
  for each row
  execute function public.prevent_archivado_directo();

create or replace function public.archivar_local(p_local_id uuid)
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

  select * into v_local from locales where id = p_local_id and organization_id = current_org_id();
  if not found then
    raise exception 'Local no encontrado';
  end if;
  if v_local.archivado then
    raise exception 'Este local ya está archivado';
  end if;

  -- Serializa archivados concurrentes de la misma organizacion: sin esto, dos
  -- pedidos simultaneos para dos locales distintos podrian ver cada uno "el
  -- otro sigue activo" y dejar la organizacion sin ningun local operable.
  perform 1 from organizations where id = v_local.organization_id for update;

  if not exists (
    select 1 from locales
    where organization_id = v_local.organization_id
      and id <> p_local_id
      and not archivado
      and not bloqueado_por_plan
  ) then
    raise exception 'No podés archivar el único local activo de tu organización. Creá o restaurá otro local antes de archivar este.';
  end if;

  -- Un turno abierto en un local archivado quedaria trabado: turnos_update
  -- exige local_is_active(), asi que ya nadie lo podria cerrar.
  if exists (select 1 from turnos where local_id = p_local_id and estado = 'abierto') then
    raise exception 'Este local tiene un turno abierto. Cerralo antes de archivar el local.';
  end if;

  perform set_config('app.bypass_archivado_check', 'true', true);
  update locales set archivado = true where id = p_local_id;
end;
$$;

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

  select * into v_local from locales where id = p_local_id and organization_id = current_org_id();
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
  -- Con el cupo verificado, el local vuelve operable: puede haber quedado con
  -- bloqueado_por_plan = true de antes de archivarse (los triggers de bloqueo
  -- ignoran a los archivados) y ya no corresponde.
  update locales set archivado = false, bloqueado_por_plan = false where id = p_local_id;
end;
$$;
