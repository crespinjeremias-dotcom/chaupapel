-- Seccion 15/13: el Plan Completo no tenia limite de locales. Se fija en 3
-- (el principal + dos adicionales). De paso cierra el gap que quedo anotado
-- en 20260911200000_bloqueo_locales_por_plan.sql: locales_insert nunca
-- valido multi_local a nivel RLS, solo el frontend ocultaba el boton
-- "agregar local" -- un insert directo (o un plan sin multi_local) dejaba
-- crear el local igual y lo neutralizaba recien despues via
-- inicializar_bloqueo_local (nace bloqueado_por_plan = true), en vez de
-- impedir la creacion.
--
-- Se resuelve con un trigger BEFORE INSERT (no la policy locales_insert):
-- mismo patron que prevent_plan_change_directo / prevent_is_active_change /
-- prevent_privilege_escalation -- una policy de RLS que falla solo devuelve
-- el mensaje generico de Postgres ("new row violates row-level security
-- policy"), y aca hace falta un mensaje claro que el frontend pueda mostrar
-- tal cual (panel.html ya muestra err.message sin traducirlo).
create or replace function public.validar_limite_locales()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org organizations%rowtype;
  v_multi_local boolean;
  v_max integer;
  v_actuales integer;
begin
  select * into v_org from organizations where id = new.organization_id;
  v_multi_local := coalesce((v_org.plan_overrides->>'multi_local')::boolean, v_org.plan = 'completo');
  v_max := case when v_multi_local then 3 else 1 end;

  select count(*) into v_actuales from locales where organization_id = new.organization_id;

  if v_actuales >= v_max then
    if v_multi_local then
      raise exception 'Alcanzaste el máximo de % locales del Plan Completo.', v_max;
    else
      raise exception 'Tu plan actual no permite más de un local. Para agregar más, primero necesitás pasar a Plan Completo.';
    end if;
  end if;

  return new;
end;
$$;

comment on function public.validar_limite_locales() is 'Bloquea directamente el INSERT si la organizacion ya llego al maximo de locales de su plan (1 sin multi_local, 3 con multi_local -- plan completo u override). Por orden alfabetico de trigger corre despues de inicializar_bloqueo_local, pero no importa: ese solo inicializa bloqueado_por_plan en la fila nueva, no rechaza nada.';

create trigger trg_validar_limite_locales
  before insert on locales
  for each row
  execute function public.validar_limite_locales();
