-- Cierra el punto abierto de la Fase 1: anular una venta fiada tiene que
-- revertir la deuda que se genero en cuenta_corriente_movimientos, ademas de
-- reponer el stock (lo del stock ya estaba resuelto desde la Fase 1).
create or replace function public.aplicar_movimiento_cuenta_corriente()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  delta numeric;
begin
  delta := case new.tipo
    when 'fiado_nuevo' then new.monto
    when 'cobro_fiado' then -new.monto
    when 'saldo_favor_generado' then -new.monto
    when 'saldo_favor_usado' then new.monto
    when 'fiado_anulado' then -new.monto
  end;

  update clientes set saldo = saldo + delta where id = new.cliente_id;
  return new;
end;
$$;

create or replace function public.aplicar_anulacion_venta()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.estado = 'anulada' and old.estado is distinct from 'anulada' then
    update productos p
      set stock_actual = p.stock_actual + vi.total_cantidad,
          updated_at = now()
      from (
        select producto_id, sum(cantidad) as total_cantidad
        from venta_items
        where venta_id = new.id
        group by producto_id
      ) vi
      where vi.producto_id = p.id;

    -- Revierte la deuda generada por esta venta al marcarla fiada. Cubre el
    -- caso general (todavia no existe UI de "cobro" -- eso es Fase 6 -- asi
    -- que a esta altura no puede haber pagos parciales sobre este fiado en
    -- particular). new.total siempre es el monto que se habia acreditado
    -- como fiado_nuevo al crear la venta.
    if new.es_fiado and new.total > 0 then
      insert into cuenta_corriente_movimientos
        (cliente_id, local_id, organization_id, tipo, monto, venta_id, usuario_id, fecha)
      values (
        new.cliente_id, new.local_id, new.organization_id, 'fiado_anulado', new.total,
        new.id, coalesce(new.anulada_por, new.usuario_id), now()
      );
    end if;
  end if;
  return new;
end;
$$;
