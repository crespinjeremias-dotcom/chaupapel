-- La policy organizations_update (Fase 1) deja que el propio admin edite
-- cualquier columna de su organizacion, incluida is_active -- pero esa
-- columna es el corte de acceso manual del super-admin (seccion 16), nunca
-- deberia poder reactivarla/desactivarla el propio cliente. auth.role()
-- devuelve 'service_role' solo cuando la request se hace con la service
-- role key (panel de super-admin, Fase 15, desde una Netlify Function) --
-- ese es el unico camino habilitado para tocar esta columna.
create or replace function public.prevent_is_active_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.role() = 'service_role' then
    return new;
  end if;

  if new.is_active is distinct from old.is_active then
    raise exception 'Solo el super-admin del sistema puede activar o desactivar una organizacion';
  end if;

  return new;
end;
$$;

create trigger trg_prevent_is_active_change
  before update on organizations
  for each row
  execute function public.prevent_is_active_change();
