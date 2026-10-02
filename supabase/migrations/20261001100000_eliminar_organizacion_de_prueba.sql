-- Limpieza de organizaciones de prueba (panel de super-admin, seccion 16).
-- Hallazgo al mapear el grafo de FKs completo: CADA tabla de este esquema ya
-- tiene su propio organization_id con "on delete cascade" directo a
-- organizations (sin excepciones), asi que un solo
-- "delete from organizations where id = ..." ya alcanza para borrar todo lo
-- que cuelga de la organizacion. No hace falta agregar ni un solo
-- "on delete cascade" nuevo. Los obstaculos reales no son de FKs sino de dos
-- triggers:
--   1. proteger_detalle_venta_anulada (venta_items/venta_pagos,
--      20260925120000_hardening_seguridad.sql): si la organizacion tiene
--      alguna venta anulada, el cascade de sus items/pagos dispara esta
--      funcion y aborta todo el delete, salvo con
--      app.bypass_ventas_check = 'true'.
--   2. usuarios.local_id -> locales(id) on delete set null: al cascadear
--      locales, Postgres hace un UPDATE implicito sobre usuarios que dispara
--      prevent_privilege_escalation y puede romper el check
--      usuarios_empleado_approved_requiere_local para un empleado approved.
--      Mismo problema (y misma solucion) que purgar_locales_vencidos(): se
--      vacia local_id (y se baja status a pending si corresponde) a mano,
--      con app.bypass_privilegios_check = 'true', ANTES del delete -- asi la
--      accion automatica del FK no tiene nada que tocar y nunca dispara el
--      trigger ni el check.
-- auth.users no se toca aca (no se puede con una query SQL comun, hace falta
-- la Admin API con la service role key) -- esta funcion devuelve los ids de
-- usuarios borrados para que netlify/functions/eliminar-organizacion.js los
-- borre de auth.users en un segundo paso.
create or replace function public.eliminar_organizacion_de_prueba(p_organization_id uuid)
returns uuid[]
language plpgsql
security definer
set search_path = public
as $$
declare
  v_usuario_ids uuid[];
  v_cobro_habilitado boolean;
  v_tiene_cobros boolean;
begin
  if not is_super_admin() then
    raise exception 'No autorizado';
  end if;

  perform 1 from organizations where id = p_organization_id for update;
  if not found then
    raise exception 'Organizacion no encontrada';
  end if;

  select cobro_habilitado into v_cobro_habilitado from organizations where id = p_organization_id;
  select exists(select 1 from cobros where organization_id = p_organization_id) into v_tiene_cobros;
  if v_cobro_habilitado or v_tiene_cobros then
    raise exception 'Esta organizacion tiene el cobro habilitado o ya tiene cobros registrados: no se puede borrar con esta funcion';
  end if;

  select array_agg(id) into v_usuario_ids from usuarios where organization_id = p_organization_id;

  perform set_config('app.bypass_privilegios_check', 'true', true);
  update usuarios
    set local_id = null,
        status = case when role = 'empleado' and status = 'approved' then 'pending'::user_status_type else status end
    where organization_id = p_organization_id and local_id is not null;
  perform set_config('app.bypass_privilegios_check', '', true);

  perform set_config('app.bypass_ventas_check', 'true', true);
  delete from organizations where id = p_organization_id;
  perform set_config('app.bypass_ventas_check', '', true);

  return coalesce(v_usuario_ids, array[]::uuid[]);
end;
$$;

revoke execute on function public.eliminar_organizacion_de_prueba(uuid) from public, anon;
grant execute on function public.eliminar_organizacion_de_prueba(uuid) to authenticated;
