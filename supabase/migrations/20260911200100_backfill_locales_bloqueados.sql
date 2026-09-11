-- El trigger trg_recalcular_locales_bloqueados (migracion anterior) solo
-- dispara con cambios FUTUROS de organizations.plan/plan_overrides -- no
-- corrige el estado de organizaciones que ya tenian mas locales de los que
-- su plan actual permite desde antes de este cambio. Mismo criterio que la
-- funcion del trigger, corrido una sola vez para el estado actual.
do $$
declare
  v_org record;
  v_multi_local boolean;
  v_local_mas_viejo uuid;
begin
  for v_org in select id, plan, plan_overrides from organizations loop
    v_multi_local := coalesce((v_org.plan_overrides->>'multi_local')::boolean, v_org.plan = 'completo');

    if v_multi_local then
      update locales set bloqueado_por_plan = false
        where organization_id = v_org.id and bloqueado_por_plan;
      continue;
    end if;

    select id into v_local_mas_viejo
      from locales
      where organization_id = v_org.id
      order by created_at asc
      limit 1;

    if v_local_mas_viejo is not null then
      update locales set bloqueado_por_plan = true
        where organization_id = v_org.id and id <> v_local_mas_viejo and not bloqueado_por_plan;
      update locales set bloqueado_por_plan = false
        where organization_id = v_org.id and id = v_local_mas_viejo and bloqueado_por_plan;
    end if;
  end loop;
end;
$$;
