-- Codigo de activacion para crear una organizacion nueva (seccion 3). Sin un
-- codigo valido no se crea la organizacion. Lo genera el super-admin desde su
-- panel; por defecto es de un solo uso y vence a los 30 dias.
-- No fija el plan inicial: toda organizacion nueva arranca en el plan por
-- defecto, igual que antes.

-- ============================================================================
-- PARTE 1: tabla de codigos
-- ============================================================================

create table codigos_activacion (
  id uuid primary key default gen_random_uuid(),
  -- Guardado normalizado: mayusculas, sin guiones ni espacios (el front lo
  -- muestra como XXXXX-XXXXX). Ver normalizar_codigo_activacion().
  codigo text not null unique,
  nota text,
  max_usos integer not null default 1 check (max_usos >= 1),
  usos integer not null default 0 check (usos >= 0),
  expira_at timestamptz default (now() + interval '30 days'),
  revocado boolean not null default false,
  creado_por uuid references super_admins(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint codigos_activacion_usos_dentro_del_maximo check (usos <= max_usos)
);

comment on table codigos_activacion is 'Codigos de activacion para crear organizaciones nuevas. Los administra solo el super-admin (RLS); el resto del mundo solo los toca via validar_codigo_activacion() / crear_organizacion(), que son security definer.';
comment on column codigos_activacion.expira_at is 'null = no vence. Por defecto 30 dias desde que se genera.';
comment on column codigos_activacion.usos is 'Cuantas organizaciones ya se crearon con este codigo. Solo lo incrementa crear_organizacion().';

alter table organizations add column codigo_activacion_id uuid references codigos_activacion(id) on delete set null;
comment on column organizations.codigo_activacion_id is 'Codigo de activacion con el que se creo la organizacion (null para las anteriores a los codigos). Sirve para que el super-admin vea quien uso cada codigo.';

alter table codigos_activacion enable row level security;

create policy codigos_activacion_select_superadmin on codigos_activacion
  for select using (is_super_admin());
create policy codigos_activacion_insert_superadmin on codigos_activacion
  for insert with check (is_super_admin());
create policy codigos_activacion_update_superadmin on codigos_activacion
  for update using (is_super_admin()) with check (is_super_admin());
-- Sin policy de delete a proposito: un codigo usado o revocado queda como
-- historial. Revocar es un update de revocado.

-- ============================================================================
-- PARTE 2: validacion
-- ============================================================================

create or replace function public.normalizar_codigo_activacion(p_codigo text)
returns text
language sql
immutable
as $$
  select upper(regexp_replace(coalesce(p_codigo, ''), '[^A-Za-z0-9]', '', 'g'));
$$;

-- Mensaje de error de un codigo (o null si se puede usar). Un solo lugar para
-- los textos, asi la validacion previa al signUp y la de crear_organizacion
-- nunca dicen cosas distintas.
create or replace function public.motivo_codigo_activacion_invalido(p_codigo codigos_activacion)
returns text
language sql
stable
as $$
  select case
    when p_codigo.id is null then 'El código de activación no es válido.'
    when p_codigo.revocado then 'Este código de activación fue revocado.'
    when p_codigo.usos >= p_codigo.max_usos then 'Este código de activación ya fue usado.'
    when p_codigo.expira_at is not null and p_codigo.expira_at < now() then 'Este código de activación venció.'
    else null
  end;
$$;

-- Validacion previa al auth.signUp(): la llama el front SIN sesion (anon), para
-- no crear una cuenta de auth huerfana cuando el codigo esta mal. No consume
-- nada -- la barrera real (y el consumo) es crear_organizacion().
create or replace function public.validar_codigo_activacion(p_codigo text)
returns boolean
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_codigo codigos_activacion%rowtype;
  v_motivo text;
begin
  select * into v_codigo from codigos_activacion where codigo = normalizar_codigo_activacion(p_codigo);
  v_motivo := motivo_codigo_activacion_invalido(v_codigo);
  if v_motivo is not null then
    raise exception '%', v_motivo;
  end if;
  return true;
end;
$$;

grant execute on function public.validar_codigo_activacion(text) to anon, authenticated;

-- ============================================================================
-- PARTE 3: crear_organizacion exige el codigo
-- Se elimina la firma vieja de 3 parametros: el cliente llama las RPC directo,
-- asi que si quedara, cualquiera podria saltearse el formulario y crear una
-- organizacion sin codigo.
-- ============================================================================

drop function if exists public.crear_organizacion(text, text, text);

create or replace function public.crear_organizacion(
  p_nombre text,
  p_nombre_admin text,
  p_telefono text,
  p_codigo text
)
returns table (organization_id uuid, local_id uuid)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_local_id uuid;
  v_email text;
  v_codigo codigos_activacion%rowtype;
  v_motivo text;
begin
  if auth.uid() is null then
    raise exception 'Se requiere estar autenticado (auth.signUp) antes de crear la organizacion';
  end if;

  if exists (select 1 from usuarios where id = auth.uid()) then
    raise exception 'Este usuario ya tiene una organizacion asociada';
  end if;

  -- for update: dos altas simultaneas con el mismo codigo se serializan aca, y
  -- la segunda ve usos ya incrementado.
  select * into v_codigo from codigos_activacion where codigo = normalizar_codigo_activacion(p_codigo) for update;
  v_motivo := motivo_codigo_activacion_invalido(v_codigo);
  if v_motivo is not null then
    raise exception '%', v_motivo;
  end if;

  select email into v_email from auth.users where id = auth.uid();

  insert into organizations (nombre, codigo_activacion_id) values (p_nombre, v_codigo.id) returning id into v_org_id;
  insert into locales (organization_id, nombre) values (v_org_id, p_nombre) returning id into v_local_id;

  insert into usuarios (id, organization_id, local_id, role, status, nombre, email, telefono)
  values (auth.uid(), v_org_id, null, 'admin', 'approved', p_nombre_admin, v_email, p_telefono);

  update codigos_activacion set usos = usos + 1 where id = v_codigo.id;

  return query select v_org_id, v_local_id;
end;
$$;

comment on function public.crear_organizacion is 'local_id del admin queda null a proposito: el admin ve todos los locales de su organizacion (usuarios.local_id, seccion 2), no esta atado a uno solo. Exige un codigo de activacion valido; lo valida y consume en la misma transaccion.';

-- La policy organizations_insert (Fase 1) dejaba a cualquier usuario
-- autenticado insertar una organizacion directo, sin pasar por
-- crear_organizacion. Sin fila en usuarios no llegaba a nada util, pero
-- permitia generar organizaciones huerfanas sin codigo. crear_organizacion es
-- security definer y no la necesita, y el front nunca inserta en organizations.
drop policy if exists organizations_insert on organizations;

-- ============================================================================
-- PARTE 4: locales.bloqueado_por_plan no se puede tocar a mano
-- Hallazgo de la migracion 20260923090000: locales_update deja al admin
-- escribir cualquier columna de sus locales, asi que podia poner
-- bloqueado_por_plan = false en un local que el plan bloqueo. Mismo patron que
-- prevent_archivado_directo. Los caminos legitimos (recalcular_locales_bloqueados
-- y restaurar_local) prenden la bandera de sesion, local a la transaccion.
-- Para corregir a mano desde el SQL editor:
--   select set_config('app.bypass_locales_bloqueo_check', 'true', true);
--   update locales set bloqueado_por_plan = ... ;   -- misma transaccion
-- ============================================================================

create or replace function public.prevent_bloqueo_por_plan_directo()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.bloqueado_por_plan is distinct from old.bloqueado_por_plan
     and coalesce(current_setting('app.bypass_locales_bloqueo_check', true), '') <> 'true'
  then
    raise exception 'bloqueado_por_plan lo mantiene el sistema segun el plan: no se puede cambiar a mano';
  end if;

  return new;
end;
$$;

create trigger trg_prevent_bloqueo_por_plan_directo
  before update of bloqueado_por_plan on locales
  for each row
  execute function public.prevent_bloqueo_por_plan_directo();

-- Mismas funciones de 20260923090000, con la bandera prendida alrededor de los
-- updates de bloqueado_por_plan.
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

  perform set_config('app.bypass_locales_bloqueo_check', 'true', true);

  if v_multi_local then
    update locales set bloqueado_por_plan = false
      where organization_id = new.id and bloqueado_por_plan and not archivado;
  else
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
  end if;

  perform set_config('app.bypass_locales_bloqueo_check', '', true);
  return new;
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
  perform set_config('app.bypass_locales_bloqueo_check', 'true', true);
  -- Con el cupo verificado, el local vuelve operable: puede haber quedado con
  -- bloqueado_por_plan = true de antes de archivarse (los triggers de bloqueo
  -- ignoran a los archivados) y ya no corresponde.
  update locales set archivado = false, bloqueado_por_plan = false where id = p_local_id;
end;
$$;
