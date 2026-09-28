-- Cobros y suscripciones (seccion 16): cobro manual (transferencia +
-- comprobante), no una pasarela automatica. El super-admin genera los cobros
-- mensuales (cron + boton de respaldo), el dueno de la organizacion sube el
-- comprobante, y el super-admin lo marca pagado desde su panel.

-- ============================================================================
-- PARTE 1: organizations.cobro_habilitado
-- Organizaciones de prueba (Almacen de prueba, Laclande, carina): no se les
-- genera ningun cobro. Mismo patron de columna protegida que plan_overrides /
-- trial_ends_at -- se agrega al trigger existente en vez de crear uno nuevo.
-- ============================================================================

alter table organizations add column cobro_habilitado boolean not null default true;
comment on column organizations.cobro_habilitado is 'false para organizaciones de prueba: generar_cobros_mensuales() las salta por completo. Protegida por prevent_org_columnas_sensibles, solo la cambia el super-admin.';

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
     or new.cobro_habilitado is distinct from old.cobro_habilitado
  then
    raise exception 'Solo el administrador del sistema puede cambiar los overrides de plan, la prueba, el codigo de activacion o el cobro de una organizacion';
  end if;

  return new;
end;
$$;

select set_config('app.bypass_org_sensibles_check', 'true', true);
update organizations set cobro_habilitado = false where nombre in ('Almacen de prueba', 'Laclande', 'carina');
select set_config('app.bypass_org_sensibles_check', '', true);

-- ============================================================================
-- PARTE 2: precios de los planes
-- Tabla en vez de hardcodear: el super-admin cambia un precio desde su panel
-- sin pedir una migracion nueva.
-- ============================================================================

create table planes_precios (
  plan plan_type primary key,
  precio_mensual numeric not null check (precio_mensual >= 0),
  updated_at timestamptz not null default now()
);

insert into planes_precios (plan, precio_mensual) values ('basico', 30000), ('completo', 50000);

create trigger trg_planes_precios_updated_at
  before update on planes_precios
  for each row
  execute function public.set_updated_at();

alter table planes_precios enable row level security;

-- Cualquier usuario aprobado necesita ver el precio de su propio plan; no es
-- informacion sensible (son los dos precios publicos del servicio).
create policy planes_precios_select on planes_precios
  for select
  using (is_approved() or is_super_admin());

create policy planes_precios_update_superadmin on planes_precios
  for update
  using (is_super_admin())
  with check (is_super_admin());

-- ============================================================================
-- PARTE 3: meses_bonificados por codigo de activacion
-- El mes de alta siempre es gratis (no depende del codigo); meses_bonificados
-- suma exencion extra. Se aplica una sola vez, al crear la organizacion, como
-- organizations.trial_ends_at (columna que ya existia sin uso real).
-- ============================================================================

alter table codigos_activacion add column meses_bonificados integer not null default 0 check (meses_bonificados >= 0);
comment on column codigos_activacion.meses_bonificados is 'Meses de facturacion exenta ademas del mes de alta (que siempre es gratis). Lo consume crear_organizacion() para fijar organizations.trial_ends_at.';

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
  v_trial_ends_at timestamptz;
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

  v_trial_ends_at := date_trunc('month', now()) + (1 + v_codigo.meses_bonificados) * interval '1 month';

  insert into organizations (nombre, codigo_activacion_id, trial_ends_at)
  values (p_nombre, v_codigo.id, v_trial_ends_at)
  returning id into v_org_id;

  insert into locales (organization_id, nombre) values (v_org_id, p_nombre) returning id into v_local_id;

  insert into usuarios (id, organization_id, local_id, role, status, nombre, email, telefono)
  values (auth.uid(), v_org_id, null, 'admin', 'approved', p_nombre_admin, v_email, p_telefono);

  update codigos_activacion set usos = usos + 1 where id = v_codigo.id;

  return query select v_org_id, v_local_id;
end;
$$;

comment on function public.crear_organizacion is 'local_id del admin queda null a proposito: el admin ve todos los locales de su organizacion (usuarios.local_id, seccion 2), no esta atado a uno solo. Exige un codigo de activacion valido; lo valida y consume en la misma transaccion. Fija trial_ends_at segun meses_bonificados del codigo (mes de alta + N meses extra, siempre exentos de cobro).';

-- ============================================================================
-- PARTE 4: tabla de cobros
-- Una fila por organizacion por mes. Sin policy de insert/update/delete para
-- el cliente a proposito -- solo se escribe via generar_cobros_mensuales()
-- (cron/security definer) y las dos funciones de la PARTE 6, mismo patron que
-- solicitudes_cambio_plan.
-- ============================================================================

create type estado_cobro_type as enum ('pendiente', 'pagado', 'vencido', 'exento');

create table cobros (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  periodo date not null,
  plan plan_type not null,
  monto numeric not null check (monto >= 0),
  estado estado_cobro_type not null default 'pendiente',
  comprobante_path text,
  pagado_at timestamptz,
  marcado_por uuid references super_admins(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (organization_id, periodo)
);

comment on table cobros is 'Un cobro mensual por organizacion. Lo genera generar_cobros_mensuales() (cron dia 1); el comprobante lo sube el admin de la organizacion (subir_comprobante_cobro); el estado final lo marca el super-admin (actualizar_estado_cobro).';
comment on column cobros.periodo is 'Primer dia del mes que factura (ej. 2026-10-01). unique junto a organization_id: nunca se duplica un cobro del mismo mes.';
comment on column cobros.plan is 'Plan vigente al momento de generar el cobro -- si la organizacion cambia de plan despues, los cobros ya generados no cambian retroactivamente.';

create index idx_cobros_organization on cobros(organization_id);
create index idx_cobros_periodo on cobros(periodo);

alter table cobros enable row level security;

create policy cobros_select_org on cobros
  for select
  using (organization_id = current_org_id() and is_admin() and is_approved());

create policy cobros_select_superadmin on cobros
  for select
  using (is_super_admin());

-- ============================================================================
-- PARTE 5: Storage -- comprobantes de pago
-- Bucket privado. Convencion de ruta: {organization_id}/{archivo}. La primera
-- carpeta del path es lo que separa a cada organizacion (storage.foldername).
-- ============================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'comprobantes-pago',
  'comprobantes-pago',
  false,
  5242880, -- 5 MiB
  array['image/jpeg', 'image/png', 'image/webp', 'application/pdf']
)
on conflict (id) do nothing;

create policy comprobantes_pago_insert_org on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'comprobantes-pago'
    and (storage.foldername(name))[1] = current_org_id()::text
    and is_admin() and is_approved() and org_is_active()
  );

create policy comprobantes_pago_select on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'comprobantes-pago'
    and (
      is_super_admin()
      or ((storage.foldername(name))[1] = current_org_id()::text and is_admin() and is_approved())
    )
  );

-- ============================================================================
-- PARTE 6: funciones de escritura sobre cobros
-- ============================================================================

-- El admin de la organizacion linkea el comprobante que ya subio a Storage
-- (el insert a storage.objects lo autoriza la policy de la PARTE 5; esto solo
-- guarda la ruta en la fila del cobro, validando que sea suyo y siga sin pagar).
create or replace function public.subir_comprobante_cobro(p_cobro_id uuid, p_path text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid;
  v_estado estado_cobro_type;
begin
  select organization_id, estado into v_org, v_estado from cobros where id = p_cobro_id for update;
  if v_org is null then
    raise exception 'Cobro no encontrado';
  end if;
  if not (is_admin() and is_approved() and org_is_active() and v_org = current_org_id()) then
    raise exception 'No autorizado';
  end if;
  if v_estado = 'pagado' then
    raise exception 'Este cobro ya está marcado como pagado';
  end if;

  update cobros set comprobante_path = p_path where id = p_cobro_id;
end;
$$;

-- El super-admin marca el estado final. 'exento' no es una opcion manual: lo
-- asigna el sistema al generar el cobro.
create or replace function public.actualizar_estado_cobro(p_cobro_id uuid, p_estado estado_cobro_type)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_super_admin() then
    raise exception 'No autorizado';
  end if;
  if p_estado = 'exento' then
    raise exception 'exento lo asigna el sistema al generar el cobro, no se puede marcar a mano';
  end if;

  update cobros
    set estado = p_estado,
        pagado_at = case when p_estado = 'pagado' then now() else null end,
        marcado_por = case when p_estado = 'pagado' then auth.uid() else null end
    where id = p_cobro_id;

  if not found then
    raise exception 'Cobro no encontrado';
  end if;
end;
$$;

-- ============================================================================
-- PARTE 7: generacion mensual (cron dia 1) + boton de respaldo
-- Salta las organizaciones con cobro_habilitado = false y las que todavia
-- estan dentro de su ventana de exencion (trial_ends_at). Antes de generar el
-- mes nuevo, los pendientes de meses anteriores pasan a vencido.
-- generar_cobros_mensuales() queda sin GRANT a nadie (solo la corre pg_cron,
-- como postgres) -- el boton de respaldo pasa por el wrapper de abajo, que si
-- valida is_super_admin().
-- ============================================================================

create or replace function public.generar_cobros_mensuales()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_periodo date := date_trunc('month', current_date)::date;
begin
  update cobros set estado = 'vencido' where estado = 'pendiente' and periodo < v_periodo;

  insert into cobros (organization_id, periodo, plan, monto, estado)
  select
    o.id,
    v_periodo,
    o.plan,
    pp.precio_mensual,
    case
      when o.trial_ends_at is not null and v_periodo < o.trial_ends_at::date then 'exento'::estado_cobro_type
      else 'pendiente'::estado_cobro_type
    end
  from organizations o
  join planes_precios pp on pp.plan = o.plan
  where o.cobro_habilitado
  on conflict (organization_id, periodo) do nothing;
end;
$$;

create or replace function public.generar_cobros_mensuales_manual()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_super_admin() then
    raise exception 'No autorizado';
  end if;
  perform public.generar_cobros_mensuales();
end;
$$;

create extension if not exists pg_cron with schema pg_catalog;
select cron.schedule('generar-cobros-mensuales', '0 5 1 * *', 'select public.generar_cobros_mensuales()');

-- ============================================================================
-- PARTE 8: GRANTs
-- Toda RPC nueva la crea Postgres ejecutable por PUBLIC -- hay que cerrarla a
-- mano (docs/rls-design.md). generar_cobros_mensuales() queda sin GRANT para
-- nadie: solo la corre pg_cron, como el dueno de la funcion (postgres).
-- ============================================================================

revoke execute on function public.subir_comprobante_cobro(uuid, text) from public, anon;
grant execute on function public.subir_comprobante_cobro(uuid, text) to authenticated;

revoke execute on function public.actualizar_estado_cobro(uuid, estado_cobro_type) from public, anon;
grant execute on function public.actualizar_estado_cobro(uuid, estado_cobro_type) to authenticated;

revoke execute on function public.generar_cobros_mensuales_manual() from public, anon;
grant execute on function public.generar_cobros_mensuales_manual() to authenticated;

revoke execute on function public.generar_cobros_mensuales() from public, anon, authenticated, service_role;

revoke execute on function public.crear_organizacion(text, text, text, text) from public, anon;
grant execute on function public.crear_organizacion(text, text, text, text) to authenticated;
