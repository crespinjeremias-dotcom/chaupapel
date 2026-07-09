-- Funciones helper para las policies de RLS. security definer + search_path fijo
-- para que puedan leer "usuarios" sin disparar de nuevo las policies de esa
-- misma tabla (evita recursion) y para que el plan del optimizador las trate
-- como una simple subconsulta cacheable por statement (marked stable).

create or replace function public.current_org_id()
returns uuid
language sql
security definer
stable
set search_path = public
as $$
  select organization_id from usuarios where id = auth.uid();
$$;

create or replace function public.current_local_id()
returns uuid
language sql
security definer
stable
set search_path = public
as $$
  select local_id from usuarios where id = auth.uid();
$$;

create or replace function public.current_role()
returns user_role_type
language sql
security definer
stable
set search_path = public
as $$
  select role from usuarios where id = auth.uid();
$$;

create or replace function public.is_admin()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select coalesce((select role = 'admin' from usuarios where id = auth.uid()), false);
$$;

create or replace function public.is_approved()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select coalesce((select status = 'approved' from usuarios where id = auth.uid()), false);
$$;

-- Organizacion activa = al dia con el pago / no cortada por el super-admin (seccion 16).
create or replace function public.org_is_active()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select coalesce(
    (select o.is_active from organizations o where o.id = (select organization_id from usuarios where id = auth.uid())),
    false
  );
$$;

comment on function public.current_org_id() is 'Organizacion del usuario autenticado actual, segun su fila en usuarios.';
comment on function public.is_approved() is 'true solo si el usuario ya paso la aprobacion del admin (no aplica a la fila propia en usuarios, que siempre debe ser visible para poder consultar el estado pending).';
