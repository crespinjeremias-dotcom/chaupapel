create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger trg_productos_updated_at
  before update on productos
  for each row
  execute function public.set_updated_at();

create trigger trg_ventas_updated_at
  before update on ventas
  for each row
  execute function public.set_updated_at();
