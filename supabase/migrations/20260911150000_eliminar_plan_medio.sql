-- Elimina el plan Medio (seccion 15): sus features (codigo de barras,
-- vencimiento, Excel, email de stock bajo) pasan a Basico -- el codigo de
-- barras en particular es demasiado usado como para dejarlo en un escalon
-- intermedio. Verificado a mano antes de esta migracion: 0 organizaciones
-- en plan 'medio' al momento de escribirla, asi que el UPDATE de abajo es
-- solo defensivo/idempotente, no corrige datos reales.
update organizations set plan = 'basico' where plan = 'medio';

-- Postgres no soporta ALTER TYPE ... DROP VALUE, asi que se recrea el tipo
-- sin 'medio' y se migra la unica columna "en vivo" que lo usa
-- (organizations.plan).
alter type plan_type rename to plan_type_old;
create type plan_type as enum ('basico', 'completo');

alter table organizations
  alter column plan drop default,
  alter column plan type plan_type using plan::text::plan_type,
  alter column plan set default 'basico';

-- solicitudes_cambio_plan es un historial de auditoria, no estado en vivo:
-- ya tenia filas viejas (de pruebas, previas al lanzamiento) referenciando
-- 'medio' en plan_actual/plan_solicitado. En vez de reescribir esos valores
-- historicos a 'basico' (lo que falsearia el registro de lo que realmente
-- se pidio/aprobo en su momento), se pasan estas dos columnas a texto
-- libre -- deja de haber una restriccion de enum ahi, pero el unico camino
-- de insert (solicitarCambioPlan en public/js/planes.js) ya solo ofrece los
-- planes de PLANES, que no incluye 'medio' desde este cambio.
alter table solicitudes_cambio_plan
  alter column plan_actual type text using plan_actual::text,
  alter column plan_solicitado type text using plan_solicitado::text;

-- aprobar_solicitud_plan lee plan_solicitado (ahora text) y lo escribe en
-- organizations.plan (enum) -- hace falta el cast explicito porque ya no
-- hay una columna enum de origen que castee sola.
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

  update organizations set plan = v_plan::plan_type where id = v_org_id;

  update solicitudes_cambio_plan
    set estado = 'aprobada', resuelta_por = auth.uid(), resuelta_at = now()
    where id = p_solicitud_id;
end;
$$;

drop type plan_type_old;
