-- Rol Super-Admin (seccion 16, Fase 15): por fuera del modelo multi-tenant.
-- No es una fila de `usuarios` -- esa tabla exige organization_id not null, y
-- el super-admin por definicion no pertenece a ninguna organizacion. Es una
-- identidad separada, cargada a mano (no hay alta publica).
--
-- Revision de una decision anterior: docs/rls-design.md decia que el
-- super-admin no seria un rol reconocido por RLS, solo service_role via
-- Netlify Function. Para el caso de uso concreto de aprobar cambios de plan
-- alcanza con politicas RLS aditivas (no se toca ninguna politica existente),
-- sin depender de infraestructura serverless que todavia no existe. La unica
-- operacion que sigue exclusivamente atada a service_role es organizations.is_active
-- (ver prevent_is_active_change) -- eso no cambia con esta migracion.
create table super_admins (
  id uuid primary key references auth.users(id) on delete cascade,
  nombre text not null,
  created_at timestamptz not null default now()
);

alter table super_admins enable row level security;

-- Cada super-admin puede leer su propia fila (para mostrar su nombre en el
-- panel). No hace falta mas: is_super_admin() usa security definer y no
-- depende de que el cliente pueda leer la tabla.
create policy super_admins_select_self on super_admins
  for select
  using (id = auth.uid());

create or replace function public.is_super_admin()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (select 1 from super_admins where id = auth.uid());
$$;

-- Politicas ADITIVAS sobre organizations (no se modifica ni se borra ninguna
-- de las 3 politicas existentes de organizations_select/insert/update -- el
-- aislamiento entre organizaciones normales no cambia en absoluto).
create policy organizations_select_superadmin on organizations
  for select
  using (is_super_admin());

-- No incluye is_active: el trigger prevent_is_active_change sigue exigiendo
-- service_role para esa columna puntual, sin importar que policy dejo pasar
-- el update.
create policy organizations_update_superadmin on organizations
  for update
  using (is_super_admin())
  with check (is_super_admin());
