-- Bloquea cantidades decimales para productos que se venden por unidad (no
-- existen "1,34 prepizzas") sin afectar a los que se venden por peso/volumen
-- (fiambre, queso, harina a granel), que si necesitan decimales. No habia
-- ninguna distincion en el schema entre esos dos casos -- default true para
-- no romper nada existente (todo sigue aceptando decimales hasta que el
-- admin marque puntualmente los productos por unidad).
alter table productos add column permite_cantidad_decimal boolean not null default true;
comment on column productos.permite_cantidad_decimal is 'false = se vende por unidad, no admite fracciones (seccion 4). Validado en venta_items/ajustes_stock/reposiciones_stock/devoluciones_cambios via trigger -- el frontend ya lo valida, esto es el respaldo server-side.';

-- venta_items, ajustes_stock y reposiciones_stock comparten la misma forma
-- (una columna "cantidad", una "producto_id"), asi que comparten esta misma
-- funcion de validacion.
create or replace function public.validar_cantidad_entera_producto()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_permite boolean;
begin
  select permite_cantidad_decimal into v_permite from productos where id = new.producto_id;
  if v_permite is false and new.cantidad <> trunc(new.cantidad) then
    raise exception 'Este producto se vende por unidad, no admite cantidades decimales';
  end if;
  return new;
end;
$$;

create trigger trg_validar_cantidad_entera_venta_items
  before insert or update of cantidad, producto_id on venta_items
  for each row
  execute function public.validar_cantidad_entera_producto();

create trigger trg_validar_cantidad_entera_ajustes_stock
  before insert on ajustes_stock
  for each row
  execute function public.validar_cantidad_entera_producto();

create trigger trg_validar_cantidad_entera_reposiciones_stock
  before insert on reposiciones_stock
  for each row
  execute function public.validar_cantidad_entera_producto();

-- devoluciones_cambios tiene dos pares producto/cantidad (el producto
-- original que se devuelve y, si es un cambio, el nuevo que se lleva el
-- cliente) -- no comparte la forma de fila de las tablas de arriba, necesita
-- su propia funcion.
create or replace function public.validar_cantidad_entera_devolucion()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_permite boolean;
begin
  select permite_cantidad_decimal into v_permite from productos where id = new.producto_original_id;
  if v_permite is false and new.cantidad <> trunc(new.cantidad) then
    raise exception 'Este producto se vende por unidad, no admite cantidades decimales';
  end if;

  if new.producto_nuevo_id is not null and new.cantidad_nueva is not null then
    select permite_cantidad_decimal into v_permite from productos where id = new.producto_nuevo_id;
    if v_permite is false and new.cantidad_nueva <> trunc(new.cantidad_nueva) then
      raise exception 'Este producto se vende por unidad, no admite cantidades decimales';
    end if;
  end if;

  return new;
end;
$$;

create trigger trg_validar_cantidad_entera_devoluciones
  before insert on devoluciones_cambios
  for each row
  execute function public.validar_cantidad_entera_devolucion();
