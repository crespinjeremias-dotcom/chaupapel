-- Seccion 1/13: hasta ahora no habia forma de eliminar un local. Decision:
-- no es un borrado real -- se archiva (queda oculto y no operable, los datos
-- se conservan intactos), admin-decidido y reversible, a diferencia de
-- bloqueado_por_plan que es automatico y se recalcula solo con el plan.
--
-- No hace falta una columna nueva: locales.activo ya existe desde la Fase 1
-- (20260709120200_locales.sql) con exactamente esta semantica -- el propio
-- comentario de bloqueado_por_plan ya lo describia como "una pausa
-- administrativa manual", solo le faltaba UI y no gateaba nada todavia. Esta
-- migracion le da a esa columna el uso real para el que fue pensada.
comment on column locales.activo is 'Archivado manual por el admin (seccion 1/13), reversible: false = local archivado -- oculto de listarLocalesOperables() y no operable (ver local_is_active(), que ahora compone este campo con bloqueado_por_plan), pero sus datos se conservan intactos. Distinto de bloqueado_por_plan, que es automatico y se recalcula solo cuando cambia el plan -- ver validar_archivado_local() para la restriccion de no poder archivar el ultimo local operable de la organizacion.';

comment on column locales.bloqueado_por_plan is 'Seccion 15: true cuando el local quedo por encima de lo que permite el plan contratado (sin multi_local, solo el local mas antiguo de la organizacion queda operable). Lo mantienen sincronizado trg_recalcular_locales_bloqueados y trg_inicializar_bloqueo_local -- no tocar a mano. Distinto de locales.activo (pausa administrativa manual y reversible, seccion 1/13) -- local_is_active() compone los dos.';

-- local_is_active() (Parte 2 de 20260911200000_bloqueo_locales_por_plan.sql)
-- pasa a exigir tambien activo -- con esto, un local archivado queda no
-- operable con el mismo rigor que uno bloqueado por plan en TODAS las
-- policies que ya dependen de local_is_active() (Parte 3 de esa misma
-- migracion: ajustes_stock, categorias, cierres_diarios/mensuales, clientes,
-- cc_movimientos, devoluciones, producto_proveedor, productos, proveedores,
-- reclamos, reposiciones, turnos, venta_items, venta_pagos, ventas), sin
-- tocar ninguna de esas policies. locales_update en si NO usa
-- local_is_active() (nunca lo uso) -- tiene que seguir siendo editable para
-- poder desarchivar/desbloquear.
create or replace function public.local_is_active(p_local_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select coalesce((select not l.bloqueado_por_plan and l.activo from locales l where l.id = p_local_id), false);
$$;

comment on function public.local_is_active(uuid) is 'true si el local no esta bloqueado por plan (automatico, seccion 15) Y no fue archivado (manual y reversible, seccion 1/13 -- locales.activo).';

-- No se puede archivar el unico local operable ("de verdad": activo Y no
-- bloqueado_por_plan) que le queda a la organizacion -- siempre tiene que
-- quedar al menos uno usable. Trigger con RAISE EXCEPTION (no una policy de
-- RLS) para poder dar un mensaje claro, mismo patron que
-- validar_limite_locales() (20260913080000_limite_locales_plan_completo.sql).
-- Solo corre en la transicion true -> false (desarchivar siempre es seguro,
-- no rompe ningun invariante).
create or replace function public.validar_archivado_local()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_otros_operables integer;
begin
  if new.activo = false and old.activo = true then
    select count(*) into v_otros_operables
      from locales
      where organization_id = new.organization_id
        and id <> new.id
        and activo
        and not bloqueado_por_plan;

    if v_otros_operables = 0 then
      raise exception 'No se puede archivar: es el único local operable que le queda a la organización.';
    end if;
  end if;

  return new;
end;
$$;

create trigger trg_validar_archivado_local
  before update of activo on locales
  for each row
  execute function public.validar_archivado_local();
