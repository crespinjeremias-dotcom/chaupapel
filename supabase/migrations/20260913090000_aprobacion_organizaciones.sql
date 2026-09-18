-- Seccion 16: gate de aprobacion para organizaciones nuevas. Hasta ahora
-- registrarse creaba la organizacion y le daba acceso inmediato -- se agrega
-- el mismo rigor que ya existe para empleados (alta -> pending -> aprobacion
-- del admin) y para cambios de plan (solicitud -> aprobacion del
-- super-admin). Mismo patron que estado_solicitud_type +
-- aprobar_solicitud_plan/rechazar_solicitud_plan
-- (20260717080100_solicitudes_cambio_plan.sql): RPC security definer, nunca
-- un UPDATE directo.

create type estado_aprobacion_type as enum ('pendiente', 'aprobada', 'rechazada');

-- Default 'aprobada' primero: asi las organizaciones que ya existian al
-- correr esta migracion (ya venian operando) quedan aprobadas automaticamente
-- sin necesitar una migracion de backfill aparte -- ALTER TABLE ADD COLUMN
-- con un default constante llena las filas existentes con ese valor. Recien
-- despues se cambia el default de la columna a 'pendiente' para que toda
-- organizacion nueva (crear_organizacion) nazca sin aprobar sin tocar esa
-- funcion.
alter table organizations add column estado_aprobacion estado_aprobacion_type not null default 'aprobada';
alter table organizations alter column estado_aprobacion set default 'pendiente';

comment on column organizations.estado_aprobacion is 'Aprobacion de organizaciones nuevas (seccion 16): toda organizacion nace pendiente y no puede operar (org_is_active() la incluye) hasta que el super-admin la aprueba o rechaza via aprobar_organizacion()/rechazar_organizacion() -- nunca un UPDATE directo, ver prevent_estado_aprobacion_change_directo. Rechazar es definitivo: no se borra nada (ni la organizacion ni el usuario admin que se registro), pero queda bloqueada para siempre -- no hay reintento automatico ni UI para que la propia organizacion vuelva a pedir aprobacion.';

-- org_is_active() (auth_helpers.sql) pasa a exigir tambien estado_aprobacion
-- = aprobada -- con esto, una organizacion pendiente o rechazada queda
-- bloqueada con exactamente el mismo rigor que una suspendida (is_active =
-- false), sin tocar ninguna de las ~20 policies que ya dependen de
-- org_is_active(). La UNICA diferencia entre los dos casos es el mensaje que
-- le muestra el frontend (panel.html distingue is_active === false de
-- estado_aprobacion !== 'aprobada' para no decir "cuenta suspendida" cuando
-- en realidad nunca fue aprobada).
create or replace function public.org_is_active()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select coalesce(
    (select o.is_active and o.estado_aprobacion = 'aprobada'
       from organizations o
       where o.id = (select organization_id from usuarios where id = auth.uid())),
    false
  );
$$;

-- Mismo mecanismo que prevent_plan_change_directo (Parte 1 de
-- 20260911200000_bloqueo_locales_por_plan.sql): una bandera de sesion local a
-- la transaccion, prendida solo por aprobar_organizacion()/
-- rechazar_organizacion(). Bloquea inclusive al super-admin editando por
-- organizations_update_superadmin con un UPDATE directo -- tiene que pasar
-- por la RPC para que quede auditado quien y cuando la resolvio.
create or replace function public.prevent_estado_aprobacion_change_directo()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.estado_aprobacion is distinct from old.estado_aprobacion
     and coalesce(current_setting('app.bypass_estado_aprobacion_check', true), '') <> 'true'
  then
    raise exception 'El estado de aprobación de una organización solo se puede cambiar via aprobar_organizacion() / rechazar_organizacion()';
  end if;

  return new;
end;
$$;

create trigger trg_prevent_estado_aprobacion_change_directo
  before update on organizations
  for each row
  execute function public.prevent_estado_aprobacion_change_directo();

create or replace function public.aprobar_organizacion(p_organization_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_estado estado_aprobacion_type;
begin
  if not is_super_admin() then
    raise exception 'No autorizado';
  end if;

  select estado_aprobacion into v_estado from organizations where id = p_organization_id for update;
  if v_estado is null then
    raise exception 'Organización no encontrada';
  end if;
  if v_estado <> 'pendiente' then
    raise exception 'Esta organización ya fue resuelta';
  end if;

  perform set_config('app.bypass_estado_aprobacion_check', 'true', true);
  update organizations set estado_aprobacion = 'aprobada' where id = p_organization_id;
end;
$$;

create or replace function public.rechazar_organizacion(p_organization_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_estado estado_aprobacion_type;
begin
  if not is_super_admin() then
    raise exception 'No autorizado';
  end if;

  select estado_aprobacion into v_estado from organizations where id = p_organization_id for update;
  if v_estado is null then
    raise exception 'Organización no encontrada';
  end if;
  if v_estado <> 'pendiente' then
    raise exception 'Esta organización ya fue resuelta';
  end if;

  perform set_config('app.bypass_estado_aprobacion_check', 'true', true);
  update organizations set estado_aprobacion = 'rechazada' where id = p_organization_id;
end;
$$;

-- El super-admin todavia no podia leer usuarios (solo organizations y
-- solicitudes_cambio_plan) -- hace falta para poder mostrar quien es el
-- admin fundador (nombre/email) de cada organizacion pendiente en su panel.
-- Politica aditiva, no reemplaza ninguna de las existentes (mismo criterio
-- que organizations_select_superadmin, 20260717080000_super_admins.sql).
create policy usuarios_select_superadmin on usuarios
  for select
  using (is_super_admin());
